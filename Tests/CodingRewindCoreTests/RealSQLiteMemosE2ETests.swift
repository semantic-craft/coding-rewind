// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Darwin
import Foundation
import Testing

private struct HarnessReadyPayload: Decodable {
    let url: String
    let pid: Int32
    let db: String
}

private struct WireContractFixture: Decodable {
    let apiPath: String
    let forbiddenLegacyApiPath: String
    let contextMarker: String
    let noteMarker: String
}

private enum SQLiteHarnessError: Error, CustomStringConvertible {
    case repoRootNotFound(String)
    case serverStartupTimeout(String)
    case serverExitedEarly(Int32, String)
    case invalidReadyURL(String)

    var description: String {
        switch self {
        case .repoRootNotFound(let startPath):
            return "Could not locate Package.swift walking up from \(startPath)"
        case .serverStartupTimeout(let stderr):
            return "Timed out waiting for sqlite_memos_server.py ready file. stderr=\(stderr)"
        case .serverExitedEarly(let status, let stderr):
            return "sqlite_memos_server.py exited early with status \(status). stderr=\(stderr)"
        case .invalidReadyURL(let raw):
            return "sqlite_memos_server.py reported invalid URL: \(raw)"
        }
    }
}

private struct RealE2EStubCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        CapturedSelection(text: "stub", bundleIdentifier: "com.apple.Notes", appName: "Notes")
    }
}

private final class SQLiteMemosHarness {
    let repoRoot: URL
    let workDir: URL
    let dbURL: URL
    let token: String
    private(set) var baseURL: URL
    private(set) var serverPID: Int32
    private var process: Process?
    private let readyFileURL: URL
    private let stderrLogURL: URL
    private var stderrFileHandle: FileHandle?

    init(token: String = "e2e-sqlite-token-\(UUID().uuidString.lowercased())") async throws {
        self.repoRoot = try Self.locateRepoRoot()
        let dir = self.repoRoot
            .appendingPathComponent(".build/real-sqlite-memos-e2e-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir
        self.dbURL = dir.appendingPathComponent("memos.sqlite3", isDirectory: false)
        self.readyFileURL = dir.appendingPathComponent("ready.json", isDirectory: false)
        self.stderrLogURL = dir.appendingPathComponent("server.stderr.log", isDirectory: false)
        self.token = token
        self.baseURL = URL(string: "http://127.0.0.1:1")!
        self.serverPID = 0

        do {
            try await startProcess()
        } catch {
            stop()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    static func locateRepoRoot(from filePath: String = #filePath) throws -> URL {
        var current = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let manifest = current.appendingPathComponent("Package.swift", isDirectory: false)
            if fm.fileExists(atPath: manifest.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        throw SQLiteHarnessError.repoRootNotFound(filePath)
    }

    func wireContract() throws -> WireContractFixture {
        let contractURL = repoRoot.appendingPathComponent("contracts/wire-contract.json", isDirectory: false)
        let data = try Data(contentsOf: contractURL)
        return try JSONDecoder().decode(WireContractFixture.self, from: data)
    }

    func restart() async throws {
        stop()
        try await startProcess()
    }

    func stop() {
        if let proc = process {
            terminateGracefully(proc)
            process = nil
        }
        if let handle = stderrFileHandle {
            try? handle.close()
            stderrFileHandle = nil
        }
        try? FileManager.default.removeItem(at: readyFileURL)
    }

    func cleanup() {
        stop()
        try? FileManager.default.removeItem(at: workDir)
    }

    private func startProcess() async throws {
        try? FileManager.default.removeItem(at: readyFileURL)
        FileManager.default.createFile(atPath: stderrLogURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrLogURL)
        self.stderrFileHandle = stderrHandle

        let scriptURL = repoRoot.appendingPathComponent("verification/e2e/sqlite_memos_server.py", isDirectory: false)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "python3",
            "-B",
            scriptURL.path,
            "--db", dbURL.path,
            "--port", "0",
            "--token", token,
            "--ready-file", readyFileURL.path
        ]
        proc.currentDirectoryURL = repoRoot
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrHandle

        try proc.run()
        self.process = proc

        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if let data = try? Data(contentsOf: readyFileURL),
               !data.isEmpty,
               let payload = try? JSONDecoder().decode(HarnessReadyPayload.self, from: data) {
                guard let parsedURL = URL(string: payload.url) else {
                    throw SQLiteHarnessError.invalidReadyURL(payload.url)
                }
                self.baseURL = parsedURL
                self.serverPID = payload.pid
                return
            }
            if !proc.isRunning {
                let stderrText = (try? String(contentsOf: stderrLogURL, encoding: .utf8)) ?? ""
                throw SQLiteHarnessError.serverExitedEarly(proc.terminationStatus, stderrText)
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let stderrText = (try? String(contentsOf: stderrLogURL, encoding: .utf8)) ?? ""
        throw SQLiteHarnessError.serverStartupTimeout(stderrText)
    }

    private func terminateGracefully(_ proc: Process) {
        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(3.0)
            while proc.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        proc.waitUntilExit()
    }
}

@Suite("Real SQLite Memos E2E", .serialized)
struct RealSQLiteMemosE2ETests {
    private func makeIsolatedDataDir(under repoRoot: URL) throws -> URL {
        let dir = repoRoot
            .appendingPathComponent(".build/real-sqlite-e2e-data-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePaths(in dir: URL) throws -> StoragePaths {
        try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
    }

    private func makeQAEnvironment(baseURL: URL, token: String) -> [String: String] {
        [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.memosURLEnvironmentKey: baseURL.absoluteString,
            StoragePaths.memosTokenEnvironmentKey: token
        ]
    }

    @Test("Full clip lifecycle over real SQLite Memos preserves verbatim body and isolates context and note comments")
    func realSQLiteFullClipLifecyclePreservesVerbatimAndIsolatesComments() async throws {
        let harness = try await SQLiteMemosHarness()
        defer { harness.cleanup() }
        let dataDir = try makeIsolatedDataDir(under: harness.repoRoot)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let contract = try harness.wireContract()
        let paths = try makePaths(in: dataDir)
        let env = makeQAEnvironment(baseURL: harness.baseURL, token: harness.token)
        let client = MemosClient()
        let repository = SnippetRepository(paths: paths, environment: env, client: client)

        let now = Date()
        let clipID = MemosWireFormat.makeClientClipID(now: now)
        let verbatimBody = """
        ```markdown
        #rewind/pending #source/fake
        > **Title:** Literal heading inside fenced block
        ```
        let mask: NSWindow.StyleMask = [.nonactivatingPanel]
        """
        let context = CaptureContext(
            sessionTitle: "coding-rewind-e2e",
            prompt: "Verify verbatim preservation across SQLite Memos mutations",
            recentTurns: [
                ConversationTurn(role: "User", text: "Keep fenced #rewind/pending untouched"),
                ConversationTurn(role: "Assistant", text: "Comments stay isolated in /comments.")
            ]
        )
        let rawMemo = try MemosWireFormat.formatRawMemoContent(
            verbatimText: verbatimBody,
            sourcePlatform: "antigravity",
            sourceTitle: "coding-rewind-e2e",
            sourceURL: "conversation://conv-sqlite-e2e",
            capturedAt: now,
            hasContext: true
        )
        let contextMarkdown = context.formattedCommentMarkdown()
        #expect(contextMarkdown.contains(contract.contextMarker))

        let created = try await client.createClip(
            clientClipId: clipID,
            content: rawMemo,
            contextComment: contextMarkdown,
            baseURL: harness.baseURL,
            token: harness.token,
            fallbackCreatedAt: now
        )
        #expect(created.id == clipID)
        #expect(created.status == .pending)
        #expect(created.verbatimText == verbatimBody)

        let fetchedInitial = try await repository.getSnippet(id: created.id, includeContext: true, now: now)
        #expect(fetchedInitial.id == created.id)
        #expect(fetchedInitial.status == .pending)
        #expect(fetchedInitial.verbatimText == verbatimBody)
        #expect(fetchedInitial.conversationContext?.sessionTitle == "coding-rewind-e2e")
        #expect(fetchedInitial.conversationContext?.recentTurns.count == 2)
        #expect(fetchedInitial.notes.isEmpty)

        let listedInitial = try await repository.listSnippets(
            SnippetQuery(windowHours: 72, status: .active),
            now: now
        )
        #expect(listedInitial.snippets.count == 1)
        #expect(listedInitial.snippets.first?.id == created.id)
        #expect(listedInitial.snippets.first?.verbatimText == verbatimBody)

        let withNote = try await repository.appendSnippetNote(
            id: created.id,
            content: "Follow-up note stored on SQLite Memos",
            author: "e2e-swift",
            now: now
        )
        #expect(withNote.notes.count == 1)
        #expect(withNote.notes.first?.content == "Follow-up note stored on SQLite Memos")
        #expect(withNote.notes.first?.author == "e2e-swift")
        #expect(withNote.conversationContext?.sessionTitle == "coding-rewind-e2e")
        #expect(withNote.verbatimText == verbatimBody)

        let rawComments = try await client.listMemoComments(
            id: created.id,
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(rawComments.count == 2)
        #expect(rawComments.filter { $0.content.contains(contract.contextMarker) }.count == 1)
        #expect(rawComments.filter { $0.content.contains(contract.noteMarker) }.count == 1)

        let updatedMeta = try await repository.updateSnippetMetadata(
            id: created.id,
            patch: SnippetMetadataPatch(
                title: "SQLite Lifecycle Clip",
                sessionTopic: "PR5 E2E",
                contextSummary: "Verified real TCP + SQLite roundtrip",
                keywords: ["sqlite", "e2e", "verbatim"],
                addTags: ["project/e2e-swift"]
            ),
            now: now
        )
        #expect(updatedMeta.status == .ready)
        #expect(updatedMeta.title == "SQLite Lifecycle Clip")
        #expect(updatedMeta.places.map(\.tag) == ["project/e2e-swift"])
        #expect(updatedMeta.verbatimText == verbatimBody)

        let archived = try await repository.updateSnippetMetadata(
            id: created.id,
            patch: SnippetMetadataPatch(archived: true),
            now: now
        )
        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText == verbatimBody)

        let unarchived = try await repository.updateSnippetMetadata(
            id: created.id,
            patch: SnippetMetadataPatch(archived: false),
            now: now
        )
        #expect(unarchived.status == .ready)
        #expect(unarchived.verbatimText == verbatimBody)

        let reloaded = try await repository.getSnippet(id: created.id, includeContext: true, now: now)
        #expect(reloaded.verbatimText == verbatimBody)
        #expect(reloaded.status == .ready)
        #expect(reloaded.places.map(\.tag) == ["project/e2e-swift"])
        #expect(reloaded.conversationContext?.sessionTitle == "coding-rewind-e2e")
        #expect(reloaded.notes.count == 1)
        #expect(reloaded.notes.first?.content == "Follow-up note stored on SQLite Memos")

        let deleted = try await repository.deleteSnippet(id: created.id)
        #expect(deleted.deleted == true)
        #expect(deleted.disposition == .remoteAndLocal)

        do {
            _ = try await repository.getSnippet(id: created.id, includeContext: true, now: now)
            Issue.record("Expected deleted snippet to be absent from SQLite Memos")
        } catch let error as RewindError {
            if case .httpError(let statusCode, _) = error {
                #expect(statusCode == 404)
            } else {
                Issue.record("Expected HTTP 404 RewindError after deletion, got \(error)")
            }
        }

        let listedAfterDelete = try await repository.listSnippets(
            SnippetQuery(windowHours: nil, status: .all),
            now: now
        )
        #expect(listedAfterDelete.snippets.isEmpty)
    }

    @Test("OfflineOutbox flushes idempotently on 409 replay and clip persists across SQLite server restart")
    @MainActor
    func realSQLiteOfflineOutboxIdempotent409AndRestartPersistence() async throws {
        let repoRoot = try SQLiteMemosHarness.locateRepoRoot()
        let dataDir = try makeIsolatedDataDir(under: repoRoot)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let paths = try makePaths(in: dataDir)
        let outbox = OfflineOutbox(fileURL: paths.outboxFileURL)

        let now = Date()
        let clipID = MemosWireFormat.makeClientClipID(now: now)
        let verbatimText = "Offline resilient highlight $E = mc^2$"
        let rawMemo = try MemosWireFormat.formatRawMemoContent(
            verbatimText: verbatimText,
            sourcePlatform: "claude",
            sourceTitle: "Claude Architecture Chat",
            sourceURL: "https://claude.ai/chat/resilient-e2e",
            capturedAt: now,
            hasContext: true
        )
        let commentMarkdown = CaptureContext(
            sessionTitle: "Offline Resilience",
            prompt: "Ensure 409 idempotency on SQLite Memos",
            recentTurns: [ConversationTurn(role: "User", text: "Survive restart")]
        ).formattedCommentMarkdown()

        let entry = OutboxEntry(
            clientClipId: clipID,
            memoContent: rawMemo,
            commentContent: commentMarkdown,
            createdAt: now
        )
        try outbox.enqueue(entry)
        #expect(outbox.loadEntries().count == 1)

        let harness = try await SQLiteMemosHarness()
        defer { harness.cleanup() }
        let client = MemosClient()

        let firstFlush = try await outbox.flush(
            using: client,
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(firstFlush.flushed.count == 1)
        #expect(firstFlush.flushed[0].card.id == clipID)
        #expect(firstFlush.remaining.isEmpty)
        #expect(outbox.loadEntries().isEmpty)

        try outbox.enqueue(entry)
        let replayFlush = try await outbox.flush(
            using: client,
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(replayFlush.flushed.count == 1)
        #expect(replayFlush.flushed[0].card.id == clipID)
        #expect(replayFlush.remaining.isEmpty)
        #expect(outbox.loadEntries().isEmpty)

        let allMemosBeforeRestart = try await client.listAllMemos(
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(allMemosBeforeRestart.count == 1)
        #expect(allMemosBeforeRestart[0].name == "memos/\(clipID)")

        let commentsBeforeRestart = try await client.listMemoComments(
            id: clipID,
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(commentsBeforeRestart.count == 1)

        let initialPID = harness.serverPID
        try await harness.restart()
        #expect(harness.serverPID != initialPID)
        #expect(FileManager.default.fileExists(atPath: harness.dbURL.path))

        let coordinator = try AppCoordinator(
            paths: paths,
            environment: makeQAEnvironment(baseURL: harness.baseURL, token: harness.token),
            memosClient: client,
            capturer: RealE2EStubCapturer(),
            language: .en
        )

        await coordinator.refresh()
        #expect(coordinator.cards.count == 1)
        #expect(coordinator.cards[0].id == clipID)
        #expect(coordinator.cards[0].verbatimText == verbatimText)
        #expect(coordinator.cards[0].isOfflinePending == false)

        await coordinator.refreshPlaceLibrary()
        #expect(coordinator.libraryRecords?.count == 1)
        #expect(coordinator.libraryRecords?.first?.id == clipID)
        #expect(coordinator.libraryRecords?.first?.verbatimText == verbatimText)
    }

    @Test("Multi-page SQLite pagination traverses nextPageToken cursors without truncating clips beyond 100")
    @MainActor
    func realSQLiteMultiPagePaginationLoadsAllClipsWithoutTruncation() async throws {
        let harness = try await SQLiteMemosHarness()
        defer { harness.cleanup() }
        let dataDir = try makeIsolatedDataDir(under: harness.repoRoot)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let client = MemosClient()
        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let pageTwoRef = try #require(PlaceRef(tag: "project/page-two"))
        let pageTwoPlace = PlaceRecord(ref: pageTwoRef, title: "Page Two", aliases: ["p2"])

        let olderUnplacedID = "e2e-unplaced-page2"
        let olderUnplacedContent = """
        #rewind/ready #source/chatgpt

        > **Title:** Older Unplaced Page Two Clip
        > **Source:** [Chat](https://chatgpt.com/c/unplaced-p2) · \(nowISO)

        Unplaced clip living on page two.
        """
        let createdOlder = try await client.createMemo(
            memoID: olderUnplacedID,
            content: olderUnplacedContent,
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(createdOlder != nil)

        for index in 1...108 {
            let clipID = String(format: "e2e-placed-%03d", index)
            let content = """
            #rewind/ready #source/chatgpt #project/page-two

            > **Title:** Placed Clip \(index)
            > **Source:** [Chat](https://chatgpt.com/c/placed-\(index)) · \(nowISO)

            Body for placed clip \(index).
            """
            let created = try await client.createMemo(
                memoID: clipID,
                content: content,
                baseURL: harness.baseURL,
                token: harness.token
            )
            #expect(created != nil)
        }

        let createdPlace = try await client.createMemo(
            memoID: pageTwoRef.memoID,
            content: MemosWireFormat.formatPlaceMemo(pageTwoPlace),
            baseURL: harness.baseURL,
            token: harness.token
        )
        #expect(createdPlace != nil)

        let rawAll = try await client.listAllMemos(baseURL: harness.baseURL, token: harness.token)
        #expect(rawAll.count == 110)

        let hotCards = try await client.listHotClips(
            baseURL: harness.baseURL,
            token: harness.token,
            now: Date()
        )
        #expect(hotCards.count == 109)
        #expect(hotCards.contains(where: { $0.id == olderUnplacedID }))

        let paths = try makePaths(in: dataDir)
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: makeQAEnvironment(baseURL: harness.baseURL, token: harness.token),
            memosClient: client,
            capturer: RealE2EStubCapturer(),
            language: .en
        )
        await coordinator.refreshPlaceLibrary()

        #expect(coordinator.places.contains(where: { $0.ref == pageTwoRef }))
        #expect(coordinator.libraryRecords?.count == 109)
        #expect(coordinator.unplacedCount == 1)
        #expect(coordinator.placeClipCounts[pageTwoRef] == 108)
        #expect(coordinator.libraryRecords?.contains(where: { $0.id == olderUnplacedID }) == true)
    }

    @Test("Real SQLite Memos rejects forbidden legacy v1 route with HTTP 410 while verifyConnection succeeds")
    func realSQLiteRejectsLegacyV1MemosRouteWith410() async throws {
        let harness = try await SQLiteMemosHarness()
        defer { harness.cleanup() }

        let contract = try harness.wireContract()
        #expect(contract.forbiddenLegacyApiPath != contract.apiPath)
        #expect(!contract.forbiddenLegacyApiPath.isEmpty)

        let legacyURL = try #require(
            URL(string: harness.baseURL.absoluteString + contract.forbiddenLegacyApiPath)
        )
        var request = URLRequest(url: legacyURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 410)

        let client = MemosClient()
        try await client.verifyConnection(baseURL: harness.baseURL, token: harness.token)
    }
}

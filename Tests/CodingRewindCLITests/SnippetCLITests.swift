// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Foundation
import Testing

@Suite("CodingRewind Single-Binary CLI Suite")
struct SnippetCLITests {
    @Test("CLIParser supports defaults, >72h windows, synthesized status, global flags anywhere, and canonical ID validation")
    func cliParserBehavior() throws {
        #expect(CLIParser.versionString == "0.7.0")

        let defaultList = try CLIParser.parse(arguments: ["coding-rewind", "list"])
        #expect(defaultList == .list(
            query: SnippetQuery(windowHours: 72, status: .active, sourcePlatform: nil, searchText: nil, limit: 50),
            dataDir: nil,
            json: false
        ))

        let allHistoryList = try CLIParser.parse(arguments: [
            "coding-rewind", "--json", "--data-dir", "/Users/shared/cr-data",
            "list", "--window", "all", "--status", "synthesized", "--source", "claude", "--limit", "200"
        ])
        #expect(allHistoryList == .list(
            query: SnippetQuery(windowHours: nil, status: .synthesized, sourcePlatform: "claude", searchText: nil, limit: 200),
            dataDir: "/Users/shared/cr-data",
            json: true
        ))

        let windowHoursSearch = try CLIParser.parse(arguments: [
            "coding-rewind", "search", "--window-hours=168", "--status=all", "--", "-flagLikeQuery"
        ])
        #expect(windowHoursSearch == .search(
            query: SnippetQuery(windowHours: 168, status: .all, sourcePlatform: nil, searchText: "-flagLikeQuery", limit: 50),
            dataDir: nil,
            json: false
        ))

        #expect(CLIParser.usageText.contains("coding-rewind delete <id> [--json]"))

        let getNoCtx = try CLIParser.parse(arguments: ["coding-rewind", "get", "memos/rw-1", "--no-context", "--json"])
        #expect(getNoCtx == .get(id: "rw-1", includeContext: false, dataDir: nil, json: true))

        let deleteDefault = try CLIParser.parse(arguments: ["coding-rewind", "delete", "rw-1"])
        #expect(deleteDefault == .delete(id: "rw-1", dataDir: nil, json: false))

        let deleteWithFlags = try CLIParser.parse(arguments: [
            "coding-rewind", "delete", "memos/rw-1", "--json", "--data-dir", "/Users/shared/cr-data"
        ])
        #expect(deleteWithFlags == .delete(id: "rw-1", dataDir: "/Users/shared/cr-data", json: true))

        for badArgs in [
            ["coding-rewind"],
            ["coding-rewind", "unknown-cmd"],
            ["coding-rewind", "list", "--limit", "0"],
            ["coding-rewind", "list", "--limit", "501"],
            ["coding-rewind", "list", "--window", "invalid"],
            ["coding-rewind", "list", "--status", "bogus"],
            ["coding-rewind", "search"],
            ["coding-rewind", "get", "memos/../foo"],
            ["coding-rewind", "get", "memos/ foo"],
            ["coding-rewind", "get", ".."],
            ["coding-rewind", "archive", "memos/../foo"],
            ["coding-rewind", "delete"],
            ["coding-rewind", "delete", "rw-1", "extra"],
            ["coding-rewind", "delete", "rw-1", "--unknown"],
            ["coding-rewind", "delete", "rw-1", "-x"],
            ["coding-rewind", "delete", "memos/../foo"],
            ["coding-rewind", "delete", "memos/ foo"],
            ["coding-rewind", "delete", ".."]
        ] {
            #expect(throws: CLIValidationError.self) {
                _ = try CLIParser.parse(arguments: badArgs)
            }
        }

        do {
            _ = try CLIParser.parse(arguments: ["coding-rewind"])
            Issue.record("Expected CLIValidationError for missing subcommand")
        } catch let error as CLIValidationError {
            #expect(error.message.contains("list, search, get, create, update, note, archive, delete, place, mcp"))
        }

        do {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "unknown-cmd"])
            Issue.record("Expected CLIValidationError for unknown subcommand")
        } catch let error as CLIValidationError {
            #expect(error.message.contains("list, search, get, create, update, note, archive, delete, place, mcp"))
        }
    }

    @Test("CLIRunner executes list, search, get, archive, missing-snippet errors, and EX_USAGE 64 on invalid IDs")
    func cliRunnerEndToEndWithBackend() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRecords = SnippetCLIFixtures.makeSampleRecords()
        let backend = FakeSnippetBackend(records: sampleRecords)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let out1 = OutputCollector()
        let err1 = OutputCollector()
        let code1 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: out1.append,
            writeStderr: err1.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code1 == 0)
        #expect(err1.value().isEmpty)
        #expect(out1.value().contains("conversation://a216ac8b-30fc-4662-b3a6-949aee033024"))
        let defaultResult = try decoder.decode(SnippetQueryResult.self, from: Data(out1.value().utf8))
        #expect(defaultResult.snippets.map(\.id) == ["rw-recent-ready"])

        let out2 = OutputCollector()
        let code2 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--window", "all", "--status", "all", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: out2.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code2 == 0)
        let fullResult = try decoder.decode(SnippetQueryResult.self, from: Data(out2.value().utf8))
        #expect(fullResult.snippets.map(\.id) == ["rw-recent-ready", "rw-archived-synth", "rw-old-120h"])

        let outGetHuman = OutputCollector()
        let codeGet = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-recent-ready", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outGetHuman.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeGet == 0)
        let humanText = outGetHuman.value()
        #expect(humanText.contains("[Antigravity Session](conversation://a216ac8b-30fc-4662-b3a6-949aee033024)"))
        #expect(humanText.contains("### Conversation Context"))
        #expect(humanText.contains("#rewind/ready inside body must remain untouched!"))

        let leadRecord = SnippetRecord(
            id: "rw-lead-fmt",
            status: .ready,
            sourcePlatform: "web",
            title: "Guide Clip",
            sourceTitle: "Swift Docs",
            sourceURL: "https://example.com/docs#:~:text=Body%20text",
            verbatimText: "Body text",
            createdAt: SnippetCLIFixtures.fixedNow,
            dataOrigin: .remote,
            conversationContext: CaptureContext(
                sessionTitle: "Swift Docs",
                sessionID: "sess-xyz-9",
                lead: .sessionOpening("Design a zero-copy parser"),
                prompt: "How do slices share storage?",
                recentTurns: [ConversationTurn(role: "User", text: "How do slices share storage?")]
            )
        )
        let formattedChatDetail = SnippetFormatter.formatSnippetDetailMarkdown(leadRecord)
        #expect(formattedChatDetail.contains("- Session ID: sess-xyz-9"))
        #expect(formattedChatDetail.contains("- Prompt: How do slices share storage?"))
        #expect(formattedChatDetail.contains("#### Session Opening\nDesign a zero-copy parser"))
        #expect(formattedChatDetail.contains("#### Recent Turns"))

        let pageLeadRecord = leadRecord.withConversationContext(
            CaptureContext(
                sessionTitle: "Swift Docs",
                lead: .pageLead("Slices share contiguous memory with their base collection."),
                prompt: ""
            )
        )
        let formattedPageDetail = SnippetFormatter.formatSnippetDetailMarkdown(pageLeadRecord)
        #expect(formattedPageDetail.contains("#### Page Lead\nSlices share contiguous memory with their base collection."))
        #expect(!formattedPageDetail.contains("- Session ID:"))
        #expect(!formattedPageDetail.contains("#### Session Opening"))

        let outArchive = OutputCollector()
        let codeArchive = await CLIRunner.run(
            arguments: ["coding-rewind", "archive", "rw-recent-ready", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outArchive.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeArchive == 0)
        let archived = try decoder.decode(SnippetRecord.self, from: Data(outArchive.value().utf8))
        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText == sampleRecords[0].verbatimText)

        let errNotFound = OutputCollector()
        let codeNotFound = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-does-not-exist", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errNotFound.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeNotFound == 1)
        #expect(errNotFound.value().contains("未找到片段：rw-does-not-exist"))

        let errBadID = OutputCollector()
        let codeBadID = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "memos/../foo", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errBadID.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeBadID == 64)
        #expect(errBadID.value().contains("Invalid snippet id"))

        let outDelete1 = OutputCollector()
        let errDelete1 = OutputCollector()
        let codeDelete1 = await CLIRunner.run(
            arguments: ["coding-rewind", "delete", "memos/rw-recent-ready", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outDelete1.append,
            writeStderr: errDelete1.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeDelete1 == 0)
        #expect(errDelete1.value().isEmpty)
        let deleted1 = try decoder.decode(SnippetDeletionResult.self, from: Data(outDelete1.value().utf8))
        #expect(deleted1 == SnippetDeletionResult(id: "rw-recent-ready", deleted: true, disposition: .remoteAndLocal))

        let outDelete2 = OutputCollector()
        let codeDelete2 = await CLIRunner.run(
            arguments: ["coding-rewind", "delete", "rw-recent-ready", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outDelete2.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeDelete2 == 0)
        let deleted2 = try decoder.decode(SnippetDeletionResult.self, from: Data(outDelete2.value().utf8))
        #expect(deleted2 == SnippetDeletionResult(id: "rw-recent-ready", deleted: false, disposition: .alreadyAbsent))

        let errAfterDelete = OutputCollector()
        let codeAfterDelete = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-recent-ready", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errAfterDelete.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeAfterDelete == 1)
        #expect(errAfterDelete.value().contains("未找到片段：rw-recent-ready"))

        let outDeleteHuman = OutputCollector()
        let codeDeleteHuman = await CLIRunner.run(
            arguments: ["coding-rewind", "delete", "rw-old-120h", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outDeleteHuman.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeDeleteHuman == 0)
        #expect(outDeleteHuman.value() == "Deleted snippet rw-old-120h (remote and local cache).\n")

        let outDeleteAbsentHuman = OutputCollector()
        let codeDeleteAbsentHuman = await CLIRunner.run(
            arguments: ["coding-rewind", "delete", "rw-old-120h", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outDeleteAbsentHuman.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeDeleteAbsentHuman == 0)
        #expect(outDeleteAbsentHuman.value() == "Snippet rw-old-120h was already absent.\n")

        let errDeleteBadID = OutputCollector()
        let codeDeleteBadID = await CLIRunner.run(
            arguments: ["coding-rewind", "delete", "memos/../foo", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errDeleteBadID.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeDeleteBadID == 64)
        #expect(errDeleteBadID.value().contains("Invalid snippet id"))

        #expect(SnippetFormatter.formatDeletedMarkdown(
            SnippetDeletionResult(id: "rw-pend", deleted: true, disposition: .localPendingOnly)
        ) == "Deleted offline pending snippet rw-pend.")
        #expect(SnippetFormatter.formatDeletedMarkdown(
            SnippetDeletionResult(id: "rw-cache", deleted: true, disposition: .alreadyAbsent)
        ) == "Removed cached snippet rw-cache (already absent on Memos).")
    }

    @Test("Bare executablePath falls back to Bundle.main.executableURL and never resolves DeveloperCredentials.plist relative to PWD")
    func bareExecutablePathNeverReadsRelativePWDDeveloperCredentials() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let evilBundle = dir.appendingPathComponent("EvilPWD.app", isDirectory: true)
        let evilHelpers = evilBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let evilResources = evilBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let evilMarker = dir.appendingPathComponent("evil-op-ran.txt")
        let evilOp = dir.appendingPathComponent("evil-op")
        try FileManager.default.createDirectory(at: evilHelpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evilResources, withIntermediateDirectories: true)
        try AtomicFile.writeUTF8(
            "#!/bin/sh\necho pwned > \"\(evilMarker.path)\"\nprintf 'evil-token'\n",
            to: evilOp,
            permissions: 0o755
        )
        let evilPlist = evilResources.appendingPathComponent("DeveloperCredentials.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://evil/vault/token",
            "op_executable": evilOp.path
        ], format: .xml, options: 0).write(to: evilPlist)

        let safeExec = dir.appendingPathComponent("bin/coding-rewind")
        #expect(CLIRunner.resolveBundledCredentialsURL(
            executablePath: "coding-rewind",
            hasCustomDataDir: false,
            environment: [:],
            fallbackExecutableURL: safeExec
        ) == nil)

        let realHelperExec = evilHelpers.appendingPathComponent("coding-rewind")
        #expect(CLIRunner.resolveBundledCredentialsURL(
            executablePath: "coding-rewind",
            hasCustomDataDir: false,
            environment: [:],
            fallbackExecutableURL: realHelperExec
        ) == evilPlist.resolvingSymlinksInPath())

        let stagedDir = dir.appendingPathComponent("PathBin", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let sourceBinary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let pathBinary = stagedDir.appendingPathComponent("coding-rewind")
        try FileManager.default.copyItem(at: sourceBinary, to: pathBinary)

        let isolatedHome = dir.appendingPathComponent("FakeHome", isDirectory: true)
        let appSupportDataDir = isolatedHome.appendingPathComponent("Library/Application Support/CodingRewind", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: appSupportDataDir)
        try paths.saveMemosURLString("http://127.0.0.1:9")

        let outPipe = Pipe()
        let errPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["coding-rewind", "list", "--json"]
        proc.currentDirectoryURL = evilHelpers
        proc.environment = [
            "HOME": isolatedHome.path,
            "PATH": "\(stagedDir.path):/usr/bin:/bin",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        #expect(proc.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: evilMarker.path))
    }

    @Test("Real coding-rewind subprocess returns EX_USAGE 64 on malformed IDs and reads offline HotCache without mutating it")
    func subprocessCLIUsageExitCodesAndOfflineCache() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        let recentDate = Date().addingTimeInterval(-3600)
        let rawMemo = """
            #rewind/ready #source/antigravity
            > **Title:** Cached Offline Card
            > **Source:** [AGY Session](conversation://cached-session-1) · \(MemosWireFormat.formatISO8601UTC(recentDate))

            Exact cached body line 1
            Exact cached body line 2
            """
        let card = try #require(MemosWireFormat.parseMemo(
            id: "rw-cached-1",
            rawContent: rawMemo,
            createdAt: recentDate,
            now: Date()
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card], now: Date())
        let cacheBefore = try Data(contentsOf: paths.hotCacheFileURL)

        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")

        for badID in ["memos/../foo", "memos/ foo"] {
            let errPipe = Pipe()
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = ["get", badID, "--data-dir", dataDir.path]
            proc.environment = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe
            try proc.run()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 64)
        }

        let cliOutPipe = Pipe()
        let cliErrPipe = Pipe()
        let cliProc = Process()
        cliProc.executableURL = binary
        cliProc.arguments = ["list", "--data-dir", dataDir.path, "--json"]
        cliProc.environment = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
        cliProc.standardInput = FileHandle.nullDevice
        cliProc.standardOutput = cliOutPipe
        cliProc.standardError = cliErrPipe
        try cliProc.run()
        let cliOutData = cliOutPipe.fileHandleForReading.readDataToEndOfFile()
        let cliErrData = cliErrPipe.fileHandleForReading.readDataToEndOfFile()
        cliProc.waitUntilExit()

        #expect(cliProc.terminationStatus == 0)
        #expect(cliErrData.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cliDecoded = try decoder.decode(SnippetQueryResult.self, from: cliOutData)
        #expect(cliDecoded.resolution == .localOnly)
        #expect(cliDecoded.snippets.map(\.id) == ["rw-cached-1"])
        #expect(cliDecoded.snippets.first?.verbatimText == "Exact cached body line 1\nExact cached body line 2")
        #expect(try Data(contentsOf: paths.hotCacheFileURL) == cacheBefore)
    }

    @Test("Real coding-rewind delete subprocess handles remote 200/404, offline outbox removal, and synced HotCache refusal")
    func subprocessCLIDeleteRemoteAndOfflineBehavior() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        final class DeleteServerState: @unchecked Sendable {
            private let lock = NSLock()
            private var liveIDs: Set<String>
            private var requests: [(method: String, path: String)] = []

            init(liveIDs: Set<String>) {
                self.liveIDs = liveIDs
            }

            func handle(_ req: LoopbackMemosHTTPServer.Request) -> (Int, Data) {
                guard req.authorization == "Bearer qa-delete-token" else {
                    return (401, Data(#"{"message":"unauthorized"}"#.utf8))
                }
                guard let comps = URLComponents(string: "http://localhost\(req.target)") else {
                    return (400, Data())
                }
                let path = comps.path
                lock.lock()
                defer { lock.unlock() }
                requests.append((req.method, path))
                if req.method == "DELETE", path.hasPrefix("/api/memos/") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    if liveIDs.remove(mid) != nil {
                        return (200, Data("{}".utf8))
                    }
                    return (404, Data(#"{"message":"not found"}"#.utf8))
                }
                return (404, Data(#"{"message":"unknown route"}"#.utf8))
            }

            func recordedRequests() -> [(method: String, path: String)] {
                lock.lock()
                defer { lock.unlock() }
                return requests
            }
        }

        let state = DeleteServerState(liveIDs: ["rw-del-online"])
        let server = try LoopbackMemosHTTPServer { state.handle($0) }
        defer { server.shutdown() }

        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func runDeleteSubprocess(_ args: [String], env: [String: String]) throws -> (Int32, Data, Data) {
            let outPipe = Pipe()
            let errPipe = Pipe()
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = args
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, outData, errData)
        }

        let now = Date()
        let isoNow = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-120))
        func makeCard(id: String, body: String, offlinePending: Bool) throws -> RewindCard {
            let tag = offlinePending ? "#rewind/pending" : "#rewind/ready"
            let raw = """
                \(tag) #source/antigravity
                > **Title:** \(id)
                > **Source:** [AGY](conversation://\(id)) · \(isoNow)

                \(body)
                """
            return try #require(MemosWireFormat.parseMemo(
                id: id,
                rawContent: raw,
                createdAt: now.addingTimeInterval(-120),
                now: now,
                isOfflinePending: offlinePending
            ))
        }

        let onlineDir = dir.appendingPathComponent("OnlineData", isDirectory: true)
        let onlinePaths = try StoragePaths(dataDirectoryURL: onlineDir)
        try onlinePaths.saveMemosURLString(server.baseURLString)
        let onlineDelCard = try makeCard(id: "rw-del-online", body: "Online card to delete", offlinePending: false)
        let onlineKeepCard = try makeCard(id: "rw-keep-online", body: "Online card to keep", offlinePending: false)
        try HotCache(fileURL: onlinePaths.hotCacheFileURL).saveCards([onlineDelCard, onlineKeepCard], now: now)

        let onlineEnv = [
            "PATH": "/usr/bin:/bin",
            "CODING_REWIND_QA": "1",
            "CODING_REWIND_MEMOS_TOKEN": "qa-delete-token"
        ]
        let (stOnline1, outOnline1, errOnline1) = try runDeleteSubprocess(
            ["delete", "memos/rw-del-online", "--data-dir", onlineDir.path, "--json"],
            env: onlineEnv
        )
        #expect(stOnline1 == 0)
        #expect(errOnline1.isEmpty)
        let resOnline1 = try decoder.decode(SnippetDeletionResult.self, from: outOnline1)
        #expect(resOnline1 == SnippetDeletionResult(id: "rw-del-online", deleted: true, disposition: .remoteAndLocal))
        #expect(HotCache(fileURL: onlinePaths.hotCacheFileURL).loadCards(now: now).map(\.id) == ["rw-keep-online"])

        let (stOnline2, outOnline2, errOnline2) = try runDeleteSubprocess(
            ["delete", "rw-del-online", "--data-dir", onlineDir.path, "--json"],
            env: onlineEnv
        )
        #expect(stOnline2 == 0)
        #expect(errOnline2.isEmpty)
        let resOnline2 = try decoder.decode(SnippetDeletionResult.self, from: outOnline2)
        #expect(resOnline2 == SnippetDeletionResult(id: "rw-del-online", deleted: false, disposition: .alreadyAbsent))
        #expect(state.recordedRequests().map { "\($0.method) \($0.path)" } == [
            "DELETE /api/memos/rw-del-online",
            "DELETE /api/memos/rw-del-online"
        ])

        let (stBadID, _, errBadID) = try runDeleteSubprocess(
            ["delete", "memos/../foo", "--data-dir", onlineDir.path],
            env: onlineEnv
        )
        #expect(stBadID == 64)
        #expect(!errBadID.isEmpty)

        let offlineDir = dir.appendingPathComponent("OfflineData", isDirectory: true)
        let offlinePaths = try StoragePaths(dataDirectoryURL: offlineDir)
        let pendingCard = try makeCard(id: "rw-outbox-1", body: "Pending offline body", offlinePending: true)
        let syncedCard = try makeCard(id: "rw-synced-1", body: "Synced cached body", offlinePending: false)
        try OfflineOutbox(fileURL: offlinePaths.outboxFileURL).enqueue(
            OutboxEntry(clientClipId: "rw-outbox-1", memoContent: pendingCard.rawContent, commentContent: nil, createdAt: pendingCard.createdAt)
        )
        try HotCache(fileURL: offlinePaths.hotCacheFileURL).saveCards([pendingCard, syncedCard], now: now)

        let qaOfflineEnv = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
        let (stOfflinePending, outOfflinePending, errOfflinePending) = try runDeleteSubprocess(
            ["delete", "rw-outbox-1", "--data-dir", offlineDir.path, "--json"],
            env: qaOfflineEnv
        )
        #expect(stOfflinePending == 0)
        #expect(errOfflinePending.isEmpty)
        let resOfflinePending = try decoder.decode(SnippetDeletionResult.self, from: outOfflinePending)
        #expect(resOfflinePending == SnippetDeletionResult(id: "rw-outbox-1", deleted: true, disposition: .localPendingOnly))
        #expect(OfflineOutbox(fileURL: offlinePaths.outboxFileURL).loadEntries().isEmpty)
        #expect(HotCache(fileURL: offlinePaths.hotCacheFileURL).loadCards(now: now).map(\.id) == ["rw-synced-1"])

        let cacheBeforeRefusal = try Data(contentsOf: offlinePaths.hotCacheFileURL)
        let (stOfflineSynced, _, errOfflineSynced) = try runDeleteSubprocess(
            ["delete", "rw-synced-1", "--data-dir", offlineDir.path, "--json"],
            env: qaOfflineEnv
        )
        #expect(stOfflineSynced != 0)
        #expect(!errOfflineSynced.isEmpty)
        #expect(try Data(contentsOf: offlinePaths.hotCacheFileURL) == cacheBeforeRefusal)
        #expect(HotCache(fileURL: offlinePaths.hotCacheFileURL).loadCards(now: now).map(\.id) == ["rw-synced-1"])
    }
}

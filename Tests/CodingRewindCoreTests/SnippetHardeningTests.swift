// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import Testing

private final class HardeningMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    struct RecordedCall: Sendable {
        let method: String
        let url: URL
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    private nonisolated(unsafe) static var calls: [String: [RecordedCall]] = [:]

    static func register(suiteID: String, handler: @escaping Handler) {
        lock.lock()
        handlers[suiteID] = handler
        calls[suiteID] = []
        lock.unlock()
    }

    static func unregister(suiteID: String) {
        lock.lock()
        handlers.removeValue(forKey: suiteID)
        calls.removeValue(forKey: suiteID)
        lock.unlock()
    }

    static func recordedCalls(suiteID: String) -> [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls[suiteID] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".hardening.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let suiteID = host.components(separatedBy: ".hardening.mock.local").first else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let bodyData = Self.readBody(from: request)
        Self.lock.lock()
        let handler = Self.handlers[suiteID]
        Self.calls[suiteID, default: []].append(
            RecordedCall(method: request.httpMethod ?? "GET", url: url, body: bodyData)
        )
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let (status, payload) = handler(request, bodyData)
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}

@Suite("v0.4.0 Core Release Hardening Regression Suite")
struct SnippetHardeningTests {
    private func makeScratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-core-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMockClient() -> MemosClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HardeningMockURLProtocol.self]
        return MemosClient(session: URLSession(configuration: config))
    }

    @Test func listSnippetsNeverTouchesHotCacheAndCapturesConcurrentOutboxStashDuringPagination() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let appOwnedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-app-sentinel",
            rawContent: "#rewind/ready #source/antigravity\n\n> **Title:** App Sentinel\n\nSentinel body owned by app",
            createdAt: now.addingTimeInterval(-60),
            now: now
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([appOwnedCard], now: now)
        let sentinelBytesBefore = try Data(contentsOf: paths.hotCacheFileURL)

        let outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        let suiteID = UUID().uuidString.lowercased()
        defer { HardeningMockURLProtocol.unregister(suiteID: suiteID) }

        HardeningMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let pageToken = components?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                try? outbox.enqueue(
                    OutboxEntry(
                        clientClipId: "rw-concurrent-clip",
                        memoContent: "#rewind/pending #source/macos\n\nStashed concurrently while page 1 was in flight",
                        commentContent: nil,
                        createdAt: now
                    )
                )
                let page1: [String: Any] = [
                    "memos": [[
                        "name": "memos/rw-remote-page1",
                        "content": "#rewind/ready #source/chatgpt\n\nRemote page 1 body",
                        "createTime": MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-120))
                    ]],
                    "nextPageToken": "page-2"
                ]
                return (200, try! JSONSerialization.data(withJSONObject: page1))
            }
            let page2: [String: Any] = [
                "memos": [[
                    "name": "memos/rw-remote-page2",
                    "content": "#rewind/ready #source/claude\n\nRemote page 2 body",
                    "createTime": MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-240))
                ]],
                "nextPageToken": ""
            ]
            return (200, try! JSONSerialization.data(withJSONObject: page2))
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hardening.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())
        let result = try await repo.listSnippets(now: now)

        #expect(result.resolution == .online)
        #expect(result.pendingOutboxCount == 1)
        #expect(result.snippets.map(\.id) == ["rw-concurrent-clip", "rw-remote-page1", "rw-remote-page2"])
        #expect(result.snippets.first?.dataOrigin == .offlinePending)

        let sentinelBytesAfter = try Data(contentsOf: paths.hotCacheFileURL)
        #expect(sentinelBytesAfter == sentinelBytesBefore)
    }

    @Test func getSnippetPrioritizesRemoteOverStaleOutboxAndFallsBackToOutboxThenHotCache() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let outbox = OfflineOutbox(fileURL: paths.outboxFileURL)

        try outbox.enqueue(
            OutboxEntry(
                clientClipId: "rw-stale-dup",
                memoContent: "#rewind/pending #source/macos\n\nVerbatim shared body",
                commentContent: nil,
                createdAt: now.addingTimeInterval(-300)
            )
        )
        let unsyncedCtx = CaptureContext(
            sessionTitle: "Unsynced Local Session",
            prompt: "Draft locally",
            recentTurns: [ConversationTurn(role: "user", text: "Local turn")]
        )
        try outbox.enqueue(
            OutboxEntry(
                clientClipId: "rw-unsynced-404",
                memoContent: "#rewind/pending #rewind/has-ctx #source/antigravity\n\nUnsynced local body",
                commentContent: unsyncedCtx.formattedCommentMarkdown(),
                createdAt: now.addingTimeInterval(-60)
            )
        )

        let cachedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-hotcache-netfail",
            rawContent: "#rewind/ready #source/claude\n\nHotCache fallback body",
            createdAt: now.addingTimeInterval(-120),
            now: now
        ))
        let staleDeletedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-deleted-remote-404",
            rawContent: "#rewind/ready #source/claude\n\nDeleted on server but stale in HotCache",
            createdAt: now.addingTimeInterval(-150),
            now: now,
            isOfflinePending: false
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([cachedCard, staleDeletedCard], now: now)

        let suiteID = UUID().uuidString.lowercased()
        defer { HardeningMockURLProtocol.unregister(suiteID: suiteID) }

        HardeningMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let path = req.url?.path ?? ""
            if path == "/api/memos/rw-stale-dup" {
                let dto = MemoWireDTO(
                    name: "memos/rw-stale-dup",
                    content: "#rewind/synthesized #source/macos\n\n> **Title:** Enriched & Archived\n\nVerbatim shared body",
                    createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-300))
                )
                return (200, try! JSONEncoder().encode(dto))
            }
            if path == "/api/memos/rw-stale-dup/comments" {
                return (200, Data(#"{"memos":[],"nextPageToken":""}"#.utf8))
            }
            if path == "/api/memos/rw-unsynced-404" {
                return (404, Data(#"{"message":"not synced yet"}"#.utf8))
            }
            if path == "/api/memos/rw-hotcache-netfail" {
                return (-1, Data())
            }
            return (404, Data())
        }

        let onlineEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hardening.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let onlineRepo = SnippetRepository(paths: paths, environment: onlineEnv, client: makeMockClient())

        let resolvedDup = try await onlineRepo.getSnippet(id: "rw-stale-dup", includeContext: true, now: now)
        #expect(resolvedDup.status == .synthesized)
        #expect(resolvedDup.dataOrigin == .remote)
        #expect(resolvedDup.title == "Enriched & Archived")

        let resolvedUnsynced = try await onlineRepo.getSnippet(id: "rw-unsynced-404", includeContext: true, now: now)
        #expect(resolvedUnsynced.dataOrigin == .offlinePending)
        #expect(resolvedUnsynced.conversationContext == unsyncedCtx)

        let resolvedUnsyncedNoCtx = try await onlineRepo.getSnippet(id: "rw-unsynced-404", includeContext: false, now: now)
        #expect(resolvedUnsyncedNoCtx.conversationContext == nil)

        let resolvedHotCache = try await onlineRepo.getSnippet(id: "rw-hotcache-netfail", includeContext: true, now: now)
        #expect(resolvedHotCache.dataOrigin == .localCache)

        await #expect(throws: RewindError.httpError(statusCode: 404, body: "")) {
            _ = try await onlineRepo.getSnippet(id: "rw-deleted-remote-404", includeContext: true, now: now)
        }

        let offlineRepo = SnippetRepository(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeMockClient())
        let offlineOutboxHit = try await offlineRepo.getSnippet(id: "rw-unsynced-404", includeContext: true, now: now)
        #expect(offlineOutboxHit.dataOrigin == .offlinePending)
        #expect(offlineOutboxHit.conversationContext == unsyncedCtx)

        await #expect(throws: RewindError.snippetNotFound("rw-nonexistent")) {
            _ = try await offlineRepo.getSnippet(id: "rw-nonexistent", includeContext: true, now: now)
        }
    }

    @Test func archiveSnippetFlushesOutboxEntryFirstAndRemovesFromOutboxAndHotCache() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        let hotCache = HotCache(fileURL: paths.hotCacheFileURL)
        let ctx = CaptureContext(
            sessionTitle: "Pending Flush Before Archive",
            prompt: "Archive unsynced clip",
            recentTurns: [ConversationTurn(role: "user", text: "Flush first")]
        )
        let targetRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Verbatim unsynced clip body",
            sourcePlatform: "antigravity",
            sourceTitle: "AGY",
            sourceURL: "conversation://flush-arch-1",
            capturedAt: now,
            hasContext: true
        )
        let keepRaw = "#rewind/pending #source/macos\n\nKeep sibling entry"

        try outbox.enqueue(OutboxEntry(
            clientClipId: "rw-flush-arch",
            memoContent: targetRaw,
            commentContent: ctx.formattedCommentMarkdown(),
            createdAt: now
        ))
        try outbox.enqueue(OutboxEntry(
            clientClipId: "rw-keep-outbox",
            memoContent: keepRaw,
            commentContent: nil,
            createdAt: now
        ))

        let targetCard = try #require(MemosWireFormat.parseMemo(id: "rw-flush-arch", rawContent: targetRaw, createdAt: now, now: now, isOfflinePending: true))
        let keepCard = try #require(MemosWireFormat.parseMemo(id: "rw-keep-cache", rawContent: keepRaw, createdAt: now, now: now))
        try hotCache.saveCards([targetCard, keepCard], now: now)

        let suiteID = UUID().uuidString.lowercased()
        defer { HardeningMockURLProtocol.unregister(suiteID: suiteID) }

        final class RemoteState: @unchecked Sendable {
            private let lock = NSLock()
            var storedContent: String?
            var commentPosted = false

            func setContent(_ value: String) {
                lock.lock()
                storedContent = value
                lock.unlock()
            }

            func getContent() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return storedContent
            }

            func markCommentPosted() {
                lock.lock()
                commentPosted = true
                lock.unlock()
            }

            func isCommentPosted() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return commentPosted
            }
        }

        let remote = RemoteState()
        let isoNow = MemosWireFormat.formatISO8601UTC(now)

        HardeningMockURLProtocol.register(suiteID: suiteID) { req, bodyData in
            let path = req.url?.path ?? ""
            let query = req.url?.query ?? ""
            if req.httpMethod == "POST" && path == "/api/memos" && query.contains("memoId=rw-flush-arch") {
                let obj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                let content = obj["content"] as? String ?? ""
                remote.setContent(content)
                let dto = MemoWireDTO(name: "memos/rw-flush-arch", content: content, createTime: isoNow)
                return (200, try! JSONEncoder().encode(dto))
            }
            if req.httpMethod == "POST" && path == "/api/memos/rw-flush-arch/comments" {
                remote.markCommentPosted()
                let dto = MemoWireDTO(name: "memos/rw-flush-arch-ctx", content: "", createTime: isoNow)
                return (200, try! JSONEncoder().encode(dto))
            }
            if req.httpMethod == "GET" && path == "/api/memos/rw-flush-arch" {
                guard let content = remote.getContent() else {
                    return (404, Data("Not Found".utf8))
                }
                let dto = MemoWireDTO(name: "memos/rw-flush-arch", content: content, createTime: isoNow)
                return (200, try! JSONEncoder().encode(dto))
            }
            if req.httpMethod == "PATCH" && path == "/api/memos/rw-flush-arch" {
                let obj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                let content = obj["content"] as? String ?? ""
                remote.setContent(content)
                let dto = MemoWireDTO(name: "memos/rw-flush-arch", content: content, createTime: isoNow)
                return (200, try! JSONEncoder().encode(dto))
            }
            return (404, Data())
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hardening.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())
        let archived = try await repo.archiveSnippet(id: "rw-flush-arch")

        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText == "Verbatim unsynced clip body")
        #expect(remote.isCommentPosted())
        #expect(outbox.loadEntries().map(\.clientClipId) == ["rw-keep-outbox"])
        #expect(hotCache.loadCards(now: now).map(\.id) == ["rw-keep-cache"])

        try outbox.removeEntry(clientClipId: "rw-keep-outbox")
        #expect(!FileManager.default.fileExists(atPath: paths.outboxFileURL.path))
    }

    @Test func getSnippetPreservesDeveloperCredentialErrorsAndQAFailsFastOnMissingToken() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        try OfflineOutbox(fileURL: paths.outboxFileURL).enqueue(
            OutboxEntry(
                clientClipId: "rw-local-hit",
                memoContent: "#rewind/pending #source/macos\n\nLocal outbox hit",
                commentContent: nil,
                createdAt: now
            )
        )
        try Data("invalid-plist-bytes".utf8).write(to: paths.developerCredentialsFileURL)

        let devEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://memos.example.test"
        ]
        let devRepo = SnippetRepository(paths: paths, environment: devEnv, client: makeMockClient())

        let localHit = try await devRepo.getSnippet(id: "rw-local-hit", includeContext: true, now: now)
        #expect(localHit.dataOrigin == .offlinePending)

        await #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            _ = try await devRepo.getSnippet(id: "rw-remote-miss", includeContext: true, now: now)
        }

        let emptyQAKeychain = "com.codingrewind.memos.qa.empty.\(UUID().uuidString.lowercased())"
        let qaMissingTokenEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://memos.example.test",
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            "CODING_REWIND_KEYCHAIN_SERVICE": emptyQAKeychain
        ]
        let qaRepo = SnippetRepository(paths: paths, environment: qaMissingTokenEnv, client: makeMockClient())

        await #expect(throws: RewindError.missingCredentials) {
            _ = try await qaRepo.listSnippets(now: now)
        }
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await qaRepo.getSnippet(id: "rw-local-hit", includeContext: true, now: now)
        }
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await qaRepo.archiveSnippet(id: "rw-local-hit")
        }
    }

    @Test func canonicalIDNormalizerFenceAwareContextParserAndMemosClientDeduplication() async throws {
        #expect(try MemosWireFormat.normalizeSnippetID("  memos/rw-123-abc  ") == "rw-123-abc")
        #expect(try MemosWireFormat.normalizeSnippetID("rw-plain") == "rw-plain")

        let invalidIDs = [
            "",
            "   ",
            "memos/",
            "memos/ rw-space",
            "memos/../escape",
            "../escape",
            ".",
            "..",
            "rw..double",
            "rw/slash",
            "rw\u{0000}null",
            "rw\u{001F}ctrl",
            "rw\nline"
        ]
        for bad in invalidIDs {
            #expect(throws: RewindError.invalidClipID(bad)) {
                _ = try MemosWireFormat.normalizeSnippetID(bad)
            }
        }

        let trickyComment = """
        <!-- rewind-context-v1 -->
        Session Title: Fence Torture Test
        Prompt: ```markdown
        ### Recent Turns
        user: fake turn inside prompt backtick fence
        ```
        And tilde block:
        ~~~yaml
        ### Recent Turns
        assistant: also inside prompt fence
        ~~~

        ### Recent Turns
        user: ```yaml
        system: root
        assistant: fake turn inside user backtick fence
        ```
        Inline ```assistant: inline span``` stays on one line.
        system: yaml key outside fence must not split turn
        assistant: ````md
        ```
        user: nested 3-backtick inside 4-backtick fence
        ```
        ````
        Final assistant line.
        """

        let parsedCtx = try #require(MemosWireFormat.parseContextComment(trickyComment))
        #expect(parsedCtx.sessionTitle == "Fence Torture Test")
        #expect(parsedCtx.prompt.contains("fake turn inside prompt backtick fence"))
        #expect(parsedCtx.prompt.contains("also inside prompt fence"))
        #expect(parsedCtx.recentTurns.count == 2)
        #expect(parsedCtx.recentTurns[0].role == "user")
        #expect(parsedCtx.recentTurns[0].text.contains("assistant: fake turn inside user backtick fence"))
        #expect(parsedCtx.recentTurns[0].text.contains("system: yaml key outside fence must not split turn"))
        #expect(parsedCtx.recentTurns[1].role == "assistant")
        #expect(parsedCtx.recentTurns[1].text.contains("user: nested 3-backtick inside 4-backtick fence"))
        #expect(parsedCtx.recentTurns[1].text.hasSuffix("Final assistant line."))

        let suiteID = UUID().uuidString.lowercased()
        defer { HardeningMockURLProtocol.unregister(suiteID: suiteID) }
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        HardeningMockURLProtocol.register(suiteID: suiteID) { req, _ in
            if req.httpMethod == "POST" && req.url?.path == "/api/memos" {
                let traversalDTO = MemoWireDTO(
                    name: "memos/../evil",
                    content: "#rewind/pending #source/macos\n\nBody",
                    createTime: MemosWireFormat.formatISO8601UTC(now)
                )
                return (200, try! JSONEncoder().encode(traversalDTO))
            }
            if req.httpMethod == "PATCH" && req.url?.path == "/api/memos/rw-card-patch" {
                let dto = MemoWireDTO(
                    name: "memos/rw-card-patch",
                    content: "#rewind/synthesized #source/macos\n\nBody",
                    createTime: MemosWireFormat.formatISO8601UTC(now)
                )
                return (200, try! JSONEncoder().encode(dto))
            }
            return (404, Data())
        }

        let client = makeMockClient()
        let baseURL = URL(string: "https://\(suiteID).hardening.mock.local")!

        await #expect(throws: RewindError.invalidClipID("memos/../evil")) {
            _ = try await client.createClip(
                clientClipId: "rw-1763200000-abcdef12",
                content: "#rewind/pending #source/macos\n\nBody",
                contextComment: "<!-- rewind-context-v1 -->\nSession Title: S\nPrompt: P",
                baseURL: baseURL,
                token: "tok"
            )
        }

        let card = try #require(MemosWireFormat.parseMemo(
            id: "rw-card-patch",
            rawContent: "#rewind/ready #source/macos\n\nBody",
            createdAt: now,
            now: now
        ))
        try await client.markSynthesized(card: card, baseURL: baseURL, token: "tok")
        let calls = HardeningMockURLProtocol.recordedCalls(suiteID: suiteID)
        #expect(calls.contains { $0.method == "PATCH" && $0.url.path == "/api/memos/rw-card-patch" && $0.url.query == "updateMask=content" })
    }
}

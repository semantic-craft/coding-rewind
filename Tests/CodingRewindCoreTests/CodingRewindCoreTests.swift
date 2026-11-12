// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

private final class MockMemosURLProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let method: String
        let url: URL
        let authHeader: String?
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest, Data) async -> (Int, Data)] = [:]
    nonisolated(unsafe) private static var requestsBySuite: [String: [RecordedRequest]] = [:]

    static func register(suiteID: String, handler: @escaping @Sendable (URLRequest, Data) async -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handlers[suiteID] = handler
        requestsBySuite[suiteID] = []
    }

    static func unregister(suiteID: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: suiteID)
        requestsBySuite.removeValue(forKey: suiteID)
    }

    static func recordedRequests(suiteID: String) -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsBySuite[suiteID] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".mock.memos.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".mock.memos.local", with: "")
        let bodyData = Self.readBody(from: request)

        Self.lock.lock()
        let handler = Self.handlers[suiteID]
        Self.requestsBySuite[suiteID, default: []].append(
            RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: url,
                authHeader: request.value(forHTTPHeaderField: "Authorization"),
                body: String(decoding: bodyData, as: UTF8.self)
            )
        )
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Task {
            let (status, respData) = await handler(request, bodyData)
            respond(url: url, status: status, data: respData)
        }
    }

    private func respond(url: URL, status: Int, data: Data) {
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let httpResp = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buf, maxLength: buf.count)
            if count <= 0 { break }
            out.append(buf, count: count)
        }
        return out
    }
}

private actor MemosResponseGate {
    private var responses: [CheckedContinuation<(Int, Data), Never>?] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func response() async -> (Int, Data) {
        await withCheckedContinuation { continuation in
            responses.append(continuation)
            let ready = arrivalWaiters.filter { $0.0 <= responses.count }
            arrivalWaiters.removeAll { $0.0 <= responses.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if responses.count >= count { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((count, continuation))
        }
    }

    func release(_ index: Int, status: Int) {
        responses[index]?.resume(returning: (status, Data()))
        responses[index] = nil
    }
}

private struct StubCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

@Suite("CodingRewindCore Memos Wire, Outbox & Plugin Suite")
struct CodingRewindCoreTests {
    private func makeIsolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-rewind-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockMemosURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("Synthesizing changes only exact first-line state tokens and preserves the remaining bytes", arguments: ["pending", "ready"])
    func synthesizedTagPreservesVerbatimBytes(state: String) {
        let header = "#rewind/\(state) #rewind/has-ctx #source/macos #rewind/pending-extra #rewind/ready-made #rewind/has-ctx-more"
        let suffix = "\r\n\r\n> **Source:** [Notes](macos://macos)\r\n\r\n#rewind/pending #rewind/ready #rewind/has-ctx #rewind/synthesized\n  原样 e\u{301} 😀\t\r\n"
        let expected = "#rewind/synthesized #source/macos #rewind/pending-extra #rewind/ready-made #rewind/has-ctx-more" + suffix
        let actual = MemosWireFormat.replacingWithSynthesizedTag(header + suffix)
        #expect(Data(actual.utf8) == Data(expected.utf8))
        #expect(MemosWireFormat.replacingWithSynthesizedTag(actual) == actual)

        let unrelated = "#rewind/ready-made #source/macos\n\n#rewind/pending"
        #expect(MemosWireFormat.replacingWithSynthesizedTag(unrelated) == unrelated)
    }

    @Test("Memo state comes only from exact first-line tokens")
    func memoStateIgnoresBodyTags() {
        let now = Date(timeIntervalSince1970: 1_794_452_400)
        let cases: [(String, CardStatus?)] = [
            ("#rewind/pending\t#source/macos\n\n#rewind/ready", .pending),
            ("#rewind/ready #source/macos\n\n#rewind/synthesized", .ready),
            ("#rewind/pending #rewind/synthesized-extra\n\nbody", .pending),
            ("#rewind/pending-extra #source/macos\n\nbody", nil),
            ("#rewind/ready-made #source/macos\n\nbody", nil),
            ("#rewind/has-ctx #source/macos\n\nbody", nil),
            ("ordinary first line\n\n#rewind/ready", nil),
            ("\n#rewind/ready #source/macos\n\nbody", nil),
            ("#rewind/synthesized #source/macos\n\n#rewind/pending", nil)
        ]
        for (raw, expectedStatus) in cases {
            let card = MemosWireFormat.parseMemo(id: "memo-state", rawContent: raw, createdAt: now, now: now)
            #expect(card?.status == expectedStatus, "Input: \(raw)")
            if let card {
                #expect(card.rawContent == raw)
                #expect(card.verbatimText == raw.components(separatedBy: "\n\n").last)
            }
        }
    }

    @Test("HotCache repairs cached state from the first line and ignores body state tags")
    func hotCacheUsesHeaderState() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = HotCache(fileURL: dir.appendingPathComponent("hot_cache.json"))
        let now = Date(timeIntervalSince1970: 1_794_452_400)
        func card(_ id: String, _ raw: String, createdAt: Date? = nil) -> RewindCard {
            RewindCard(
                id: id, rawContent: raw, status: .ready, sourcePlatform: "macos",
                sourceTitle: "macos", verbatimText: "body", createdAt: createdAt ?? now,
                isOfflinePending: true
            )
        }
        let cards = [
            card("pending", "#rewind/pending #source/macos\n\n#rewind/ready"),
            card("ready", "#rewind/ready #source/macos\n\n#rewind/synthesized"),
            card("synthesized", "#rewind/synthesized #source/macos\n\n#rewind/pending"),
            card("prefix", "#rewind/pending-extra #source/macos\n\nbody"),
            card("body-only", "body\n\n#rewind/pending"),
            card("old", "#rewind/ready #source/macos\n\nbody", createdAt: now.addingTimeInterval(-RewindCard.hotWindowSeconds - 1))
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cards).write(to: cache.fileURL)
        let loaded = cache.loadCards(now: now)
        #expect(Set(loaded.map(\.id)) == Set(["pending", "ready"]))
        #expect(loaded.first { $0.id == "pending" }?.status == .pending)
        #expect(loaded.first { $0.id == "ready" }?.verbatimText == "#rewind/synthesized")
        #expect(loaded.allSatisfy { $0.isOfflinePending })

        try cache.saveCards(cards, now: now)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode([RewindCard].self, from: Data(contentsOf: cache.fileURL))
        #expect(Set(saved.map(\.id)) == Set(["pending", "ready"]))
        #expect(saved.first { $0.id == "pending" }?.status == .pending)
    }

    @Test("Outbox flush retains new and replaced entries queued while the request is suspended", arguments: [false, true], [nil, "replacement", "\u{e9}"])
    func outboxPreservesEnqueuesDuringFlush(independentWriter: Bool, replacementBody: String?) async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = OfflineOutbox(fileURL: dir.appendingPathComponent("outbox.jsonl"))
        let writer = independentWriter ? OfflineOutbox(fileURL: outbox.fileURL) : outbox
        let now = Date(timeIntervalSince1970: 1_794_452_400)
        let replaceSnapshot = replacementBody != nil
        let old = OutboxEntry(clientClipId: "queued-old", memoContent: "#rewind/pending\n\ne\u{301}", commentContent: nil, createdAt: now)
        let replacement = OutboxEntry(clientClipId: old.clientClipId, memoContent: "#rewind/pending\n\n\(replacementBody ?? "")", commentContent: nil, createdAt: now)
        let added = OutboxEntry(clientClipId: "queued-new", memoContent: "#rewind/pending\n\nnew", commentContent: nil, createdAt: now)
        try outbox.enqueue(old)

        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let baseURL = try #require(URL(string: "https://\(suiteID).mock.memos.local"))
        let gate = MemosResponseGate()
        MockMemosURLProtocol.register(suiteID: suiteID) { _, _ in await gate.response() }
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let flush = Task { try await outbox.flush(using: MemosClient(session: session), baseURL: baseURL, token: "test-token") }
        await gate.waitForRequests(1)
        if replaceSnapshot { try writer.enqueue(replacement) }
        try writer.enqueue(added)
        await gate.release(0, status: 409)
        let result = try await flush.value

        let expected = replaceSnapshot ? [replacement, added] : [added]
        #expect(result.flushed.map(\.id) == [old.clientClipId])
        #expect(result.remaining == expected)
        #expect(OfflineOutbox(fileURL: outbox.fileURL).loadEntries() == expected)
    }

    @Test("A failed overlapping flush cannot resurrect entries removed by a successful flush")
    func overlappingOutboxFlushDoesNotResurrectEntries() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = OfflineOutbox(fileURL: dir.appendingPathComponent("outbox.jsonl"))
        let second = OfflineOutbox(fileURL: first.fileURL)
        try first.enqueue(OutboxEntry(clientClipId: "overlapping", memoContent: "#rewind/pending\n\nbody", commentContent: nil))
        let firstSuite = UUID().uuidString.lowercased()
        let secondSuite = UUID().uuidString.lowercased()
        defer {
            MockMemosURLProtocol.unregister(suiteID: firstSuite)
            MockMemosURLProtocol.unregister(suiteID: secondSuite)
        }
        let firstURL = try #require(URL(string: "https://\(firstSuite).mock.memos.local"))
        let secondURL = try #require(URL(string: "https://\(secondSuite).mock.memos.local"))
        let firstGate = MemosResponseGate()
        let secondGate = MemosResponseGate()
        MockMemosURLProtocol.register(suiteID: firstSuite) { _, _ in await firstGate.response() }
        MockMemosURLProtocol.register(suiteID: secondSuite) { _, _ in await secondGate.response() }
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let client = MemosClient(session: session)
        let failedFlush = Task { try await first.flush(using: client, baseURL: firstURL, token: "test-token") }
        await firstGate.waitForRequests(1)
        let successfulFlush = Task { try await second.flush(using: client, baseURL: secondURL, token: "test-token") }
        await secondGate.waitForRequests(1)
        await secondGate.release(0, status: 409)
        let success = try await successfulFlush.value
        #expect(success.flushed.map(\.id) == ["overlapping"])
        #expect(first.loadEntries().isEmpty)
        await firstGate.release(0, status: 503)
        let failure = try await failedFlush.value
        #expect(failure.remaining.isEmpty)
        #expect(first.loadEntries().isEmpty)
    }

    @Test("MemosClient wire contract creates pending clip + context comment, lists 72h hot cards, and patches synthesized")
    func memosClientWireContractEndToEnd() async throws {
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }

        let now = try #require(MemosWireFormat.parseISO8601("2026-11-11T03:00:00Z"))
        let baseURL = try #require(URL(string: "https://\(suiteID).mock.memos.local"))

        MockMemosURLProtocol.register(suiteID: suiteID) { req, bodyData in
            let path = req.url?.path ?? ""
            if req.httpMethod == "POST" && path == "/api/memos" {
                let obj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                let content = obj["content"] as? String ?? ""
                let resp: [String: Any] = [
                    "name": "memos/srv-101",
                    "content": content,
                    "createTime": "2026-11-11T02:55:00Z",
                    "updateTime": "2026-11-11T02:55:00Z"
                ]
                let data = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data()
                return (200, data)
            }
            if req.httpMethod == "POST" && path == "/api/memos/srv-101/comments" {
                let resp: [String: Any] = ["name": "memos/srv-101-ctx", "content": "ok"]
                return (200, (try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
            }
            if req.httpMethod == "GET" && path == "/api/memos" {
                let readyMarkdown = """
                #rewind/ready #source/antigravity

                > **Title:** NSPanel 不抢焦点浮窗
                > **Session:** coding-rewind · 状态栏重构
                > **Context:** 讨论 macOS 悬浮面板如何响应点击却不打断当前编辑器输入焦点。
                > **Keywords:** NSPanel, nonactivatingPanel, AppKit
                > **Source:** [coding-rewind](conversation://conv-alpha) · 2026-11-11T02:50:00Z

                > Quoted inside verbatim
                let mask: NSWindow.StyleMask = [.nonactivatingPanel]
                """
                let pendingPlain = """
                #rewind/pending #source/macos

                > **Source:** [Preview](macos://macos) · 2026-11-11T01:00:00Z

                Plain macOS snippet
                """
                let synthesizedDone = """
                #rewind/synthesized #source/claude

                > **Source:** [Thread](https://claude.ai/chat/1) · 2026-11-11T02:59:00Z

                Already synthesized
                """
                let expiredOld = """
                #rewind/ready #source/chatgpt

                > **Source:** [Old](https://chatgpt.com/c/old) · 2026-11-01T00:00:00Z

                Older than 72 hours
                """
                let listResp: [String: Any] = [
                    "memos": [
                        ["name": "memos/m-old", "content": expiredOld, "createTime": "2026-11-01T00:00:00Z"],
                        ["name": "memos/m-synth", "content": synthesizedDone, "createTime": "2026-11-11T02:59:00Z"],
                        ["name": "memos/m-pending", "content": pendingPlain, "createTime": "2026-11-11T01:00:00.123456Z"],
                        ["name": "memos/m-ready", "content": readyMarkdown, "createTime": "2026-11-11T02:50:00Z"],
                        ["name": "memos/m-unrelated", "content": "Shopping list without rewind tag", "createTime": "2026-11-11T02:58:00Z"]
                    ]
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: listResp)) ?? Data())
            }
            if req.httpMethod == "PATCH" && path == "/api/memos/m-ready" {
                let resp: [String: Any] = ["name": "memos/m-ready", "content": "patched"]
                return (200, (try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
            }
            return (404, Data("{\"error\":\"unexpected\"}".utf8))
        }

        let client = MemosClient(session: makeMockSession())
        let clipID = MemosWireFormat.makeClientClipID(now: now)
        #expect(MemosWireFormat.isValidMemoID(clipID))
        #expect(MemosWireFormat.isValidMemoID("\(clipID)-ctx"))

        let ctx = CaptureContext(
            sessionTitle: "coding-rewind",
            prompt: "如何设计不抢焦点的 HUD？",
            recentTurns: [
                ConversationTurn(role: "User", text: "如何设计不抢焦点的 HUD？"),
                ConversationTurn(role: "Assistant", text: "使用 NSPanel 与 .nonactivatingPanel。")
            ]
        )
        let rawWithCtx = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "func demo() {\n    print(\"verbatim\")\n}",
            sourcePlatform: "antigravity",
            sourceTitle: "coding-rewind",
            sourceURL: "conversation://conv-alpha",
            capturedAt: now,
            hasContext: true
        )
        let created = try await client.createClip(
            clientClipId: clipID,
            content: rawWithCtx,
            contextComment: ctx.formattedCommentMarkdown(),
            baseURL: baseURL,
            token: "tok-secret-test",
            fallbackCreatedAt: now
        )
        #expect(created.id == "srv-101")
        #expect(created.verbatimText == "func demo() {\n    print(\"verbatim\")\n}")

        let rawWithoutCtx = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "No context excerpt",
            sourcePlatform: "macos",
            sourceTitle: "Notes",
            sourceURL: nil,
            capturedAt: now,
            hasContext: false
        )
        #expect(!rawWithoutCtx.contains("#rewind/has-ctx"))
        #expect(rawWithoutCtx.hasPrefix("#rewind/pending #source/macos"))

        let hotCards = try await client.listHotClips(baseURL: baseURL, token: "tok-secret-test", now: now)
        #expect(hotCards.count == 2)
        #expect(hotCards[0].id == "m-ready")
        #expect(hotCards[0].status == .ready)
        #expect(hotCards[0].title == "NSPanel 不抢焦点浮窗")
        #expect(hotCards[0].sessionTopic == "coding-rewind · 状态栏重构")
        #expect(hotCards[0].contextSummary?.contains("悬浮面板") == true)
        #expect(hotCards[0].keywords == ["NSPanel", "nonactivatingPanel", "AppKit"])
        #expect(hotCards[0].sourceURL == "conversation://conv-alpha")
        #expect(hotCards[0].verbatimText == "> Quoted inside verbatim\nlet mask: NSWindow.StyleMask = [.nonactivatingPanel]")
        #expect(hotCards[1].id == "m-pending")
        #expect(hotCards[1].status == .pending)
        #expect(hotCards[1].reopenURL == nil)

        let pastedEndpointBaseURL = try #require(URL(string: "https://\(suiteID).mock.memos.local/api/memos/"))
        try await client.markSynthesized(card: hotCards[0], baseURL: pastedEndpointBaseURL, token: "tok-secret-test")

        let recorded = MockMemosURLProtocol.recordedRequests(suiteID: suiteID)
        #expect(recorded.count == 4)
        #expect(recorded[0].authHeader == "Bearer tok-secret-test")
        #expect(recorded[0].url.path == "/api/memos")
        #expect(recorded[0].url.query?.contains("memoId=\(clipID)") == true)
        #expect(recorded[0].body.contains("\"visibility\":\"PRIVATE\""))
        #expect(recorded[0].body.contains("#rewind/pending #rewind/has-ctx #source/antigravity"))
        #expect(recorded[1].url.path == "/api/memos/srv-101/comments")
        #expect(recorded[1].url.query?.contains("commentId=\(clipID)-ctx") == true)
        #expect(recorded[1].body.contains("<!-- rewind-context-v1 -->"))
        #expect(recorded[2].url.path == "/api/memos")
        #expect(recorded[3].method == "PATCH")
        #expect(recorded[3].url.path == "/api/memos/m-ready")
        #expect(recorded[3].url.query == "updateMask=content")
        #expect(recorded[3].body.contains("#rewind\\/synthesized") || recorded[3].body.contains("#rewind/synthesized"))
        #expect(!recorded[3].body.contains("#rewind/ready"))
        #expect(MemosClient.normalizeBaseURLString("https://memos.example.com/api/memos/") == "https://memos.example.com")
        #expect(MemosClient.normalizeBaseURLString("https://memos.example.com/api/v1/memos/") == "https://memos.example.com")
    }

    @Test("OfflineOutbox + HotCache survive network failure and flush idempotently on 409 retry")
    @MainActor
    func offlineOutboxAndHotCacheIdempotentFlush() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("GeminiConfig")
        )
        let selection = CapturedSelection(
            text: "Offline resilient highlight $E = mc^2$",
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Claude Architecture Chat - Claude",
            documentURL: "https://claude.ai/chat/resilient-1"
        )

        let offlineCoord = try AppCoordinator(
            paths: paths,
            environment: [:],
            memosClient: MemosClient(session: makeMockSession()),
            capturer: StubCapturer(selection: selection)
        )
        await offlineCoord.captureSelection()

        #expect(offlineCoord.cards.count == 1)
        #expect(offlineCoord.cards[0].isOfflinePending == true)
        #expect(offlineCoord.cards[0].sourcePlatform == "claude")
        #expect(offlineCoord.outbox.loadEntries().count == 1)

        let queuedClipID = offlineCoord.outbox.loadEntries()[0].clientClipId
        let reloadStart = DispatchTime.now().uptimeNanoseconds
        let coldStartCoord = try AppCoordinator(
            paths: paths,
            environment: [:],
            memosClient: MemosClient(session: makeMockSession()),
            capturer: StubCapturer(selection: selection)
        )
        let reloadMS = Double(DispatchTime.now().uptimeNanoseconds - reloadStart) / 1_000_000.0
        #expect(reloadMS < 25.0)
        #expect(coldStartCoord.cards.count == 1)
        #expect(coldStartCoord.cards[0].verbatimText == "Offline resilient highlight $E = mc^2$")

        MockMemosURLProtocol.register(suiteID: suiteID) { req, _ in
            if req.httpMethod == "POST" && req.url?.path == "/api/memos" {
                return (409, Data("{\"message\":\"already exists\"}".utf8))
            }
            if req.httpMethod == "GET" && req.url?.path == "/api/memos" {
                let content = """
                #rewind/ready #source/claude

                > **Title:** 离线队列恢复测试
                > **Source:** [Claude Architecture Chat](https://claude.ai/chat/resilient-1) · \(MemosWireFormat.formatISO8601UTC(Date()))

                Offline resilient highlight $E = mc^2$
                """
                let payload: [String: Any] = [
                    "memos": [
                        [
                            "name": "memos/\(queuedClipID)",
                            "content": content,
                            "createTime": MemosWireFormat.formatISO8601UTC(Date())
                        ]
                    ]
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
            }
            return (500, Data())
        }

        coldStartCoord.environment = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local",
            StoragePaths.memosTokenEnvironmentKey: "env-token-xyz"
        ]
        await coldStartCoord.refresh()

        #expect(coldStartCoord.outbox.loadEntries().isEmpty)
        #expect(coldStartCoord.cards.count == 1)
        #expect(coldStartCoord.cards[0].status == .ready)
        #expect(coldStartCoord.cards[0].isOfflinePending == false)
    }

    @Test("Credentials & QA isolation never write memos_token to disk and isolate Keychain service under CODING_REWIND_QA=1")
    func credentialsAndQAIsolation() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("IsolatedData")
        let paths = try StoragePaths.resolve(environment: [
            StoragePaths.dataDirEnvironmentKey: dataDir.path
        ])
        #expect(paths.dataDirectoryURL == dataDir.standardizedFileURL)

        try paths.saveMemosURLString("https://memos.example.com/api/memos/")
        #expect(paths.readConfiguredMemosURLString(environment: [:]) == "https://memos.example.com")
        try paths.saveMemosURLString("https://memos.example.com/api/v1/memos")
        #expect(paths.readConfiguredMemosURLString(environment: [:]) == "https://memos.example.com")

        let rawConfigText = try String(contentsOf: paths.configFileURL, encoding: .utf8)
        let rawConfigJSON = try #require(JSONSerialization.jsonObject(with: Data(rawConfigText.utf8)) as? [String: Any])
        #expect(Set(rawConfigJSON.keys) == Set(["memos_url"]))
        #expect(!rawConfigText.contains("token"))

        #expect(KeychainTokenStore.serviceName(environment: [:]) == "com.codingrewind.memos")
        #expect(KeychainTokenStore.serviceName(environment: ["CODING_REWIND_QA": "1"]) == "com.codingrewind.memos.qa")
        #expect(
            KeychainTokenStore.serviceName(environment: [
                "CODING_REWIND_QA": "1",
                "CODING_REWIND_KEYCHAIN_SERVICE": "com.codingrewind.memos"
            ]) == "com.codingrewind.memos.qa"
        )
    }

    @Test("AntigravityHookRunner parses camelCase lastUserInput + 4 recent turns from transcript.jsonl into active_turn.json")
    func hookRunnerExtractsLastUserInputAndFourTurns() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("Data")
        let transcriptURL = dir.appendingPathComponent("transcript.jsonl")
        let transcriptLines = [
            "{\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"content\":\"Turn 1 question\"}",
            "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"content\":\"Turn 1 answer\"}",
            "{\"type\":\"USER_INPUT\",\"source\":\"SYSTEM\",\"content\":\"<SYSTEM_MESSAGE>ignored system wake</SYSTEM_MESSAGE>\"}",
            "{\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"content\":\"Turn 2 question\"}",
            "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"content\":\"\"}",
            "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"content\":\"Turn 2 answer\"}",
            "{\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"content\":\"Turn 3 latest question\"}",
            "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"content\":\"Turn 3 latest answer\"}"
        ].joined(separator: "\n") + "\n"
        try transcriptLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let store = try ActiveTurnStore(dataDirectoryURL: dataDir)
        let stdinPayload = try JSONSerialization.data(withJSONObject: [
            "conversationId": "conv-2x-test",
            "lastUserInput": "Explicit stdin lastUserInput",
            "workspacePaths": [dir.appendingPathComponent("coding-rewind").path],
            "transcriptPath": transcriptURL.path,
            "hookEventName": "Stop"
        ])

        var capturedOut = Data()
        let code = AntigravityHookRunner.run(
            stdin: stdinPayload,
            environment: [:],
            activeTurnStore: store,
            stdout: { capturedOut.append($0) }
        )
        #expect(code == 0)
        #expect(String(decoding: capturedOut, as: UTF8.self) == "{}\n")
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("active_turn.json").path))

        let recorded = try #require(store.latestTurn(forFrontmostBundleID: CapturedSelection.antigravityBundleIdentifier))
        #expect(recorded.conversationId == "conv-2x-test")
        #expect(recorded.sessionTitle == "coding-rewind")
        #expect(recorded.lastUserInput == "Explicit stdin lastUserInput")
        #expect(recorded.hookEventName == "Stop")
        #expect(recorded.recentTurns == [
            ConversationTurn(role: "User", text: "Turn 2 question"),
            ConversationTurn(role: "Assistant", text: "Turn 2 answer"),
            ConversationTurn(role: "User", text: "Turn 3 latest question"),
            ConversationTurn(role: "Assistant", text: "Turn 3 latest answer")
        ])
    }

    @Test("AntigravityIntegration writes official 2.x plugin.json, flat hooks.json, and copies binaries outside .build")
    func officialPluginAndHookInstallerSchema() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeBuildDir = dir.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBuildDir, withIntermediateDirectories: true)
        let fakeHookSrc = fakeBuildDir.appendingPathComponent("coding-rewind-hook")
        let fakeBridgeSrc = dir.appendingPathComponent("memos-mcp-bridge.sh")
        try AtomicFile.writeUTF8("#!/bin/sh\necho '{}'\n", to: fakeHookSrc, permissions: 0o755)
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: fakeBridgeSrc, permissions: 0o755)

        let dataDir = dir.appendingPathComponent("Application Support/CodingRewind", isDirectory: true)
        let configDir = dir.appendingPathComponent("gemini-config", isDirectory: true)

        let pluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: dataDir,
            configDirectoryURL: configDir,
            sourceHookBinaryURL: fakeHookSrc,
            sourceMCPBridgeURL: fakeBridgeSrc
        )

        let status = AntigravityIntegration.verify(dataDirectoryURL: dataDir, configDirectoryURL: configDir)
        guard case .installed(_, let installedHookURL) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(!installedHookURL.path.contains("/.build/"))
        #expect(FileManager.default.isExecutableFile(atPath: installedHookURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: AntigravityIntegration.stableMCPBridgeURL(in: dataDir).path))

        let pluginJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))) as? [String: Any]
        )
        #expect(Set(pluginJSON.keys) == Set(["name", "version", "description", "suggestedPrompts"]))
        #expect(pluginJSON["name"] as? String == "coding-rewind")
        #expect(pluginJSON["version"] as? String == "0.2.0")
        let prompts = try #require(pluginJSON["suggestedPrompts"] as? [String])
        #expect(prompts.count == 3)

        let hooksJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: pluginDir.appendingPathComponent("hooks.json"))) as? [String: Any]
        )
        let group = try #require(hooksJSON["coding-rewind"] as? [String: Any])
        for event in ["PostInvocation", "Stop"] {
            let flatArray = try #require(group[event] as? [[String: Any]])
            #expect(flatArray.count == 1)
            #expect(flatArray[0]["hooks"] == nil)
            #expect(flatArray[0]["matcher"] == nil)
            #expect(flatArray[0]["type"] as? String == "command")
            #expect(flatArray[0]["timeout"] as? Int == 5)
            let cmd = try #require(flatArray[0]["command"] as? String)
            #expect(!cmd.contains(".build"))
            #expect(cmd.hasPrefix("'") && cmd.hasSuffix("'"))
        }
    }

    @Test("AntigravityLauncher invokes agentapi new-conversation directly without shell interpolation and falls back cleanly")
    func agentAPILauncherDirectProcessAndFallback() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let argsDumpFile = dir.appendingPathComponent("argv.json")
        let mockAgentAPI = dir.appendingPathComponent("agentapi")
        let pythonMock = """
        #!/usr/bin/env python3
        import json, os, sys
        with open(os.environ["MOCK_ARGV_OUT"], "w", encoding="utf-8") as fh:
            json.dump(sys.argv[1:], fh, ensure_ascii=False)
        """
        try AtomicFile.writeUTF8(pythonMock + "\n", to: mockAgentAPI, permissions: 0o755)
        _ = chmod(mockAgentAPI.path, 0o755)

        let card = RewindCard(
            id: "card-1",
            rawContent: "#rewind/ready #source/antigravity",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "零 Shell 注入测试",
            sessionTopic: "coding-rewind",
            contextSummary: "确保提示词中的反引号与 $(cmd) 原样作为进程参数传递。",
            sourceTitle: "coding-rewind",
            sourceURL: "conversation://conv-safe-99",
            verbatimText: "Dangerous literal: $(touch should_not_exist) `uname -a`",
            createdAt: Date()
        )

        var clipboardCaptured: String?
        var openedApp = false
        let outcome = AntigravityLauncher.launchConversation(
            cards: [card],
            environment: [
                AntigravityLauncher.agentAPIEnvironmentKey: mockAgentAPI.path,
                "MOCK_ARGV_OUT": argsDumpFile.path,
                "PATH": "/usr/bin:/bin"
            ],
            defaultAppBinaryPath: dir.appendingPathComponent("missing-agentapi").path,
            copyToClipboard: { clipboardCaptured = $0 },
            openAntigravityApp: { openedApp = true }
        )

        guard case .launchedViaAgentAPI(let binURL, let prompt) = outcome else {
            Issue.record("Expected launchedViaAgentAPI, got \(outcome)")
            return
        }
        #expect(binURL == mockAgentAPI.standardizedFileURL)
        #expect(clipboardCaptured == nil)
        #expect(openedApp == false)

        let recordedArgv = try JSONDecoder().decode([String].self, from: Data(contentsOf: argsDumpFile))
        #expect(recordedArgv.count == 2)
        #expect(recordedArgv[0] == "new-conversation")
        #expect(recordedArgv[1] == prompt)
        #expect(prompt.contains("[出处](conversation://conv-safe-99)"))
        #expect(prompt.contains("$(touch should_not_exist) `uname -a`"))

        let fallbackOutcome = AntigravityLauncher.launchConversation(
            cards: [card],
            environment: ["PATH": dir.appendingPathComponent("empty-path").path],
            defaultAppBinaryPath: dir.appendingPathComponent("nonexistent-agentapi").path,
            copyToClipboard: { clipboardCaptured = $0 },
            openAntigravityApp: { openedApp = true }
        )
        #expect(fallbackOutcome == .copiedToClipboardFallback(prompt: prompt))
        #expect(clipboardCaptured == prompt)
        #expect(openedApp == true)
    }

    @Test("MenuStatusSnapshot models connection host+port, outbox badge, recent card truncation, and focusAndCheckCard")
    @MainActor
    func menuStatusSnapshotAndFocusCardBehavior() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
        let configDir = dir.appendingPathComponent("GeminiConfig", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir, antigravityConfigDirectoryURL: configDir)

        let selection = CapturedSelection(
            text: "First   line\n\nSecond\tline with extra spaces that exceeds thirty-six characters easily",
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Gemini Thread",
            documentURL: "https://gemini.google.com/app/123"
        )
        let coord = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            memosClient: MemosClient(session: makeMockSession()),
            capturer: StubCapturer(selection: selection)
        )

        let initialSnap = coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: false)
        #expect(initialSnap.connection == .unconfigured)
        #expect(initialSnap.hotCardCount == 0)
        #expect(initialSnap.checkedCardCount == 0)
        #expect(initialSnap.pendingOutboxCount == 0)
        #expect(initialSnap.isPluginReady == false)
        #expect(initialSnap.isAccessibilityTrusted == false)
        #expect(initialSnap.recentCards.isEmpty)
        #expect(initialSnap.headerTitle == "Coding Rewind · 0 张热卡")
        #expect(initialSnap.headerSubtitle == "Memos 未配置（离线队列可用） · 插件待安装")
        #expect(initialSnap.toggleHUDTitle == "打开 Rewind 浮窗")
        #expect(initialSnap.launchTitle == "在 Antigravity 开聊")

        await coord.captureSelection()
        let pendingSnap = coord.menuStatusSnapshot(isHUDVisible: true, isAccessibilityTrusted: true)
        #expect(pendingSnap.hotCardCount == 1)
        #expect(pendingSnap.checkedCardCount == 1)
        #expect(pendingSnap.pendingOutboxCount == 1)
        #expect(pendingSnap.isAccessibilityTrusted == true)
        #expect(pendingSnap.headerTitle == "Coding Rewind · 1 张热卡（待同步 1）")
        #expect(pendingSnap.toggleHUDTitle == "收起 Rewind 浮窗")
        #expect(pendingSnap.launchTitle == "在 Antigravity 开聊（已选 1 张）")
        #expect(pendingSnap.recentCards.count == 1)
        #expect(pendingSnap.recentCards[0].sourcePlatform == "gemini")
        #expect(pendingSnap.recentCards[0].isChecked == true)
        #expect(pendingSnap.recentCards[0].titlePreview == "First line Second line with extra sp…")

        try paths.saveMemosURLString("https://memos.example.com:443/api/memos/")
        let defaultPortSnap = coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: true)
        #expect(
            defaultPortSnap.connection == .connected(
                hostSummary: "memos.example.com",
                baseURL: try #require(URL(string: "https://memos.example.com:443"))
            )
        )

        try paths.saveMemosURLString("http://localhost:5230")
        let fakeHook = dir.appendingPathComponent("coding-rewind-hook")
        try AtomicFile.writeUTF8("#!/bin/sh\necho '{}'\n", to: fakeHook, permissions: 0o755)
        coord.installOrRepairPlugin(sourceHookURL: fakeHook, sourceBridgeURL: nil)

        let now = Date()
        coord.checkedCardIDs.removeAll()
        coord.cards = (1...6).map { idx in
            RewindCard(
                id: "c-\(idx)",
                rawContent: "#rewind/ready #source/claude",
                status: .ready,
                sourcePlatform: "claude",
                title: idx == 1 ? "  Multi\n  line\tCard One  " : "Card \(idx)",
                sourceTitle: "Claude",
                verbatimText: "Body \(idx)",
                createdAt: now.addingTimeInterval(Double(-idx))
            )
        }
        coord.focusAndCheckCard(id: "nonexistent-id")
        #expect(coord.checkedCardIDs.isEmpty)

        coord.focusAndCheckCard(id: "c-3")
        #expect(coord.focusedCardID == "c-3")
        #expect(coord.checkedCardIDs == Set(["c-3"]))

        let customPortSnap = coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: true)
        #expect(
            customPortSnap.connection == .connected(
                hostSummary: "localhost:5230",
                baseURL: try #require(URL(string: "http://localhost:5230"))
            )
        )
        #expect(customPortSnap.isPluginReady == true)
        #expect(customPortSnap.headerSubtitle == "Memos 已连接 localhost:5230 · 插件已就绪")
        #expect(customPortSnap.recentCards.count == 5)
        #expect(customPortSnap.recentCards[0].titlePreview == "Multi line Card One")
        #expect(customPortSnap.recentCards[2].id == "c-3")
        #expect(customPortSnap.recentCards[2].isChecked == true)
        #expect(customPortSnap.launchTitle == "在 Antigravity 开聊（已选 1 张）")
    }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Darwin
import Foundation
import Testing

private final class SnippetMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        request.url?.host?.hasSuffix(".snippet.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".snippet.mock.local", with: "")
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
        Self.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Task {
            let (status, respData) = await handler(request, bodyData)
            respond(url: url, status: status, data: respData)
        }
    }

    private static func unlock() {
        lock.unlock()
    }

    private func respond(url: URL, status: Int, data: Data) {
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
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

private func makeMockClient() -> MemosClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SnippetMockURLProtocol.self]
    return MemosClient(session: URLSession(configuration: config))
}

private func makeTempDir() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-tmp-snippet-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func encodeJSON<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data()
}

@Suite("SnippetRepository, Wire Parsers & Credential Isolation Suite")
struct SnippetRepositoryTests {
    @Test("parseSnippetRecord supports pending, ready, and synthesized regardless of age while ignoring non-rewind memos")
    func parseSnippetRecordSupportsAllStatusesAndAges() throws {
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let tenDaysAgo = now.addingTimeInterval(-240 * 3600)
        let verbatim = """
        First paragraph with #rewind/ready and #rewind/synthesized literal text.

        ```swift
        func keepBlankLines() {

            print("verbatim 100% 汉字 e\u{301}")
        }
        ```
        """
        let rawSynthesized = """
        #rewind/synthesized #source/antigravity

        > **Title:** 归档架构讨论
        > **Session:** 单二进制演进
        > **Context:** 合并 CLI 与 MCP 至单一可执行文件。
        > **Keywords:** mcp, cli, swift
        > **Source:** [Architecture Chat](conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc) · 2026-11-05T12:00:00Z

        \(verbatim)
        """

        let parsed = try #require(MemosWireFormat.parseSnippetRecord(
            id: "memos/rw-old-synth",
            rawContent: rawSynthesized,
            createdAt: tenDaysAgo,
            dataOrigin: .remote
        ))
        #expect(parsed.id == "rw-old-synth")
        #expect(parsed.status == .synthesized)
        #expect(parsed.sourcePlatform == "antigravity")
        #expect(parsed.title == "归档架构讨论")
        #expect(parsed.sessionTopic == "单二进制演进")
        #expect(parsed.contextSummary == "合并 CLI 与 MCP 至单一可执行文件。")
        #expect(parsed.keywords == ["mcp", "cli", "swift"])
        #expect(parsed.sourceTitle == "Architecture Chat")
        #expect(parsed.sourceURL == "conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc")
        #expect(parsed.verbatimText == verbatim)
        #expect(parsed.createdAt == tenDaysAgo)
        #expect(parsed.dataOrigin == .remote)
        #expect(MemosWireFormat.parseMemo(id: "memos/rw-old-synth", rawContent: rawSynthesized, createdAt: tenDaysAgo, now: now) == nil)

        let nonRewindWithBodyTag = """
        #notes/daily

        Body mentions #rewind/ready on line 3, not header.
        """
        #expect(MemosWireFormat.parseSnippetRecord(
            id: "memos/plain-1",
            rawContent: nonRewindWithBodyTag,
            createdAt: now,
            dataOrigin: .remote
        ) == nil)
    }

    @Test("parseContextComment parses multiline prompts and multiline turns from desktop and web clipper formats")
    func parseContextCommentHandlesMultilinePromptsAndTurns() throws {
        let original = CaptureContext(
            sessionTitle: "Actor Reentrancy & Pagination",
            prompt: """
            Why did page 2 fail silently?
            ```swift
            let items = try await fetchPage(token)
            ```
            Explain fail-closed semantics.
            """,
            recentTurns: [
                ConversationTurn(
                    role: "User",
                    text: "First question line 1\nFirst question line 2"
                ),
                ConversationTurn(
                    role: "Assistant",
                    text: "Answer paragraph 1\n\nNote: Do not publish partial hot cache.\nExample: keep previous snapshot."
                )
            ]
        )

        let desktopMarkdown = original.formattedCommentMarkdown()
        let parsedDesktop = try #require(MemosWireFormat.parseContextComment(desktopMarkdown))
        #expect(parsedDesktop == original)

        let webClipperComment = """
        <!-- rewind-context-v1 -->\r
        Session Title: Web Clipper Gemini Session\r
        Prompt: Multiline web prompt\r
        line two\r
        \r
        ### Recent Turns\r
        User: First web turn\r
        \r
        Assistant: Second web turn\r
        with code:\r
        ```js\r
        const x = 1;\r
        ```\r
        """
        let parsedWeb = try #require(MemosWireFormat.parseContextComment(webClipperComment))
        #expect(parsedWeb.sessionTitle == "Web Clipper Gemini Session")
        #expect(parsedWeb.prompt == "Multiline web prompt\nline two")
        #expect(parsedWeb.recentTurns == [
            ConversationTurn(role: "User", text: "First web turn"),
            ConversationTurn(role: "Assistant", text: "Second web turn\nwith code:\n```js\nconst x = 1;\n```")
        ])

        #expect(MemosWireFormat.parseContextComment("Plain user comment without marker") == nil)
        #expect(MemosWireFormat.parseContextComment("<!-- rewind-context-v1 -->\nSession Title: \nPrompt: \n\n### Recent Turns\n") == nil)
    }

    @Test("listSnippets paginates all pages, merges outbox, preserves 72h HotCache contract, and supports >72h & synthesized filters")
    func listSnippetsPaginationFiltersAndHotCacheContract() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))

        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let iso = MemosWireFormat.formatISO8601UTC

        let tRecentReady = now.addingTimeInterval(-2 * 3600)
        let tOutboxPending = now.addingTimeInterval(-4 * 3600)
        let tRecentPending = now.addingTimeInterval(-10 * 3600)
        let tRecentSynth = now.addingTimeInterval(-12 * 3600)
        let tOldReady = now.addingTimeInterval(-120 * 3600)
        let tOldSynth = now.addingTimeInterval(-200 * 3600)

        let outboxRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Unsent offline thought about SQLite FTS5",
            sourcePlatform: "macos",
            sourceTitle: "Local Notes",
            sourceURL: nil,
            capturedAt: tOutboxPending,
            hasContext: false
        )
        try OfflineOutbox(fileURL: paths.outboxFileURL).enqueue(
            OutboxEntry(clientClipId: "rw-outbox-1", memoContent: outboxRaw, commentContent: nil, createdAt: tOutboxPending)
        )

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let pageToken = components?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                let payload: [String: Any] = [
                    "memos": [
                        [
                            "name": "memos/rw-recent-ready",
                            "content": "#rewind/ready #source/antigravity\n\n> **Title:** Swift MCP Transport\n> **Session:** Single Binary Design\n> **Context:** Stdio JSON-RPC framing.\n> **Keywords:** stdio, jsonrpc\n> **Source:** [AGY Session](conversation://abc-123) · \(iso(tRecentReady))\n\nUse newline-delimited JSON-RPC 2.0.",
                            "createTime": iso(tRecentReady)
                        ],
                        [
                            "name": "memos/plain-unrelated",
                            "content": "Shopping list: coffee beans",
                            "createTime": iso(now)
                        ],
                        [
                            "name": "memos/rw-recent-synth",
                            "content": "#rewind/synthesized #source/gemini\n\n> **Title:** Archived Gemini Clip\n> **Source:** [Gemini](https://gemini.google.com/app/1) · \(iso(tRecentSynth))\n\nAlready synthesized body.",
                            "createTime": iso(tRecentSynth)
                        ]
                    ],
                    "nextPageToken": "page-2"
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            } else if pageToken == "page-2" {
                let payload: [String: Any] = [
                    "memos": [
                        [
                            "name": "memos/rw-recent-pending",
                            "content": "#rewind/pending #source/chatgpt\n\n> **Source:** [ChatGPT Thread](https://chatgpt.com/c/xyz) · \(iso(tRecentPending))\n\nPending ChatGPT excerpt.",
                            "createTime": iso(tRecentPending)
                        ],
                        [
                            "name": "memos/rw-old-ready",
                            "content": "#rewind/ready #source/claude\n\n> **Title:** Five Days Ago Insight\n> **Keywords:** history, deepdive\n> **Source:** [Claude Chat](https://claude.ai/chat/old) · \(iso(tOldReady))\n\nOlder than 72 hours ready body.",
                            "createTime": iso(tOldReady)
                        ],
                        [
                            "name": "memos/rw-old-synth",
                            "content": "#rewind/synthesized #source/web\n\n> **Title:** Ancient Archived Note\n> **Source:** [Blog](https://example.com/post) · \(iso(tOldSynth))\n\nOld synthesized excerpt.",
                            "createTime": iso(tOldSynth)
                        ]
                    ],
                    "nextPageToken": ""
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            }
            return (400, Data())
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "test-token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())

        let defaultResult = try await repo.listSnippets(SnippetQuery(), now: now)
        #expect(defaultResult.resolution == .online)
        #expect(defaultResult.pendingOutboxCount == 1)
        #expect(defaultResult.snippets.map(\.id) == ["rw-recent-ready", "rw-outbox-1", "rw-recent-pending"])
        #expect(defaultResult.snippets.map(\.dataOrigin) == [.remote, .offlinePending, .remote])

        let allActiveHistory = try await repo.listSnippets(
            SnippetQuery(windowHours: nil, status: .active),
            now: now
        )
        #expect(allActiveHistory.snippets.map(\.id) == [
            "rw-recent-ready",
            "rw-outbox-1",
            "rw-recent-pending",
            "rw-old-ready"
        ])

        let synthesizedAllHistory = try await repo.listSnippets(
            SnippetQuery(windowHours: nil, status: .synthesized),
            now: now
        )
        #expect(synthesizedAllHistory.snippets.map(\.id) == ["rw-recent-synth", "rw-old-synth"])

        let everything = try await repo.listSnippets(
            SnippetQuery(windowHours: nil, status: .all),
            now: now
        )
        #expect(everything.snippets.map(\.id) == [
            "rw-recent-ready",
            "rw-outbox-1",
            "rw-recent-pending",
            "rw-recent-synth",
            "rw-old-ready",
            "rw-old-synth"
        ])

        let claudeSearch = try await repo.listSnippets(
            SnippetQuery(windowHours: nil, status: .all, sourcePlatform: "CLAUDE", searchText: "deepdive"),
            now: now
        )
        #expect(claudeSearch.snippets.map(\.id) == ["rw-old-ready"])

        let clampedLimited = try await repo.listSnippets(
            SnippetQuery(windowHours: nil, status: .all, limit: 2),
            now: now
        )
        #expect(clampedLimited.snippets.count == 2)
        #expect(SnippetQuery(limit: 0).limit == 1)
        #expect(SnippetQuery(limit: 999).limit == 500)

        #expect(!FileManager.default.fileExists(atPath: paths.hotCacheFileURL.path))
    }

    @Test("listSnippets fails closed to offlineFallback when a later page fails and serves localOnly when unconfigured")
    func listSnippetsFailClosedPaginationAndLocalOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let cachedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-cached-good",
            rawContent: "#rewind/ready #source/macos\n\n> **Title:** Cached Safe Card\n\nCached body",
            createdAt: now.addingTimeInterval(-3600),
            now: now
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([cachedCard], now: now)

        let unconfiguredRepo = SnippetRepository(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            client: makeMockClient()
        )
        let localOnlyResult = try await unconfiguredRepo.listSnippets(now: now)
        #expect(localOnlyResult.resolution == .localOnly)
        #expect(localOnlyResult.snippets.map(\.id) == ["rw-cached-good"])
        #expect(localOnlyResult.snippets.first?.dataOrigin == .localCache)

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let pageToken = components?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                let page1: [String: Any] = [
                    "memos": [[
                        "name": "memos/rw-partial-page1",
                        "content": "#rewind/ready #source/macos\n\nPartial page 1 card",
                        "createTime": MemosWireFormat.formatISO8601UTC(now)
                    ]],
                    "nextPageToken": "page-2-broken"
                ]
                return (200, try! JSONSerialization.data(withJSONObject: page1))
            }
            return (502, Data("Bad Gateway".utf8))
        }

        let onlineEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let failingPageRepo = SnippetRepository(paths: paths, environment: onlineEnv, client: makeMockClient())
        let fallbackResult = try await failingPageRepo.listSnippets(now: now)
        if case .offlineFallback(let reason) = fallbackResult.resolution {
            #expect(reason.contains("502"))
        } else {
            Issue.record("Expected offlineFallback when page 2 fails, got \(fallbackResult.resolution)")
        }
        #expect(fallbackResult.snippets.map(\.id) == ["rw-cached-good"])
        #expect(HotCache(fileURL: paths.hotCacheFileURL).loadCards(now: now).map(\.id) == ["rw-cached-good"])
    }

    @Test("getSnippet resolves outbox with context, fetches remote memo + comments, and falls back to HotCache offline")
    func getSnippetOutboxRemoteAndOfflineFallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let outboxCtx = CaptureContext(
            sessionTitle: "Offline Session",
            prompt: "Offline prompt",
            recentTurns: [ConversationTurn(role: "User", text: "Offline turn")]
        )
        let outboxMemo = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Offline body",
            sourcePlatform: "antigravity",
            sourceTitle: "Offline Session",
            sourceURL: "conversation://offline-1",
            capturedAt: now,
            hasContext: true
        )
        try OfflineOutbox(fileURL: paths.outboxFileURL).enqueue(
            OutboxEntry(
                clientClipId: "rw-outbox-ctx",
                memoContent: outboxMemo,
                commentContent: outboxCtx.formattedCommentMarkdown(),
                createdAt: now
            )
        )

        let cachedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-cached-only",
            rawContent: "#rewind/ready #source/macos\n\nCached fallback snippet",
            createdAt: now.addingTimeInterval(-600),
            now: now
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([cachedCard], now: now)

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        let remoteCtx = CaptureContext(
            sessionTitle: "Remote Deep Dive",
            prompt: "Explain stdio MCP\nwith code",
            recentTurns: [
                ConversationTurn(role: "User", text: "Explain stdio MCP\nwith code"),
                ConversationTurn(role: "Assistant", text: "Here is the framing:\n```json\n{\"jsonrpc\":\"2.0\"}\n```")
            ]
        )

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let path = req.url?.path ?? ""
            if path == "/api/memos/rw-remote-1" {
                let dto = MemoWireDTO(
                    name: "memos/rw-remote-1",
                    content: "#rewind/ready #source/antigravity\n\n> **Title:** Remote Title\n> **Source:** [Remote Deep Dive](conversation://rem-1) · \(MemosWireFormat.formatISO8601UTC(now))\n\nVerbatim remote body",
                    createTime: MemosWireFormat.formatISO8601UTC(now)
                )
                return (200, encodeJSON(dto))
            }
            if path == "/api/memos/rw-remote-1/comments" {
                let payload: [String: Any] = [
                    "memos": [
                        ["name": "memos/unrelated-comment", "content": "A plain note"],
                        ["name": "memos/rw-remote-1-ctx", "content": remoteCtx.formattedCommentMarkdown()]
                    ]
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            }
            if path == "/api/memos/plain-memo" {
                let dto = MemoWireDTO(name: "memos/plain-memo", content: "Not a rewind snippet", createTime: MemosWireFormat.formatISO8601UTC(now))
                return (200, encodeJSON(dto))
            }
            if path == "/api/memos/missing-memo" {
                return (404, Data("Not Found".utf8))
            }
            if path == "/api/memos/rw-cached-only" {
                return (-1, Data())
            }
            return (500, Data())
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())

        let fromOutboxWithCtx = try await repo.getSnippet(id: "memos/rw-outbox-ctx", includeContext: true, now: now)
        #expect(fromOutboxWithCtx.dataOrigin == .offlinePending)
        #expect(fromOutboxWithCtx.conversationContext == outboxCtx)

        let fromOutboxNoCtx = try await repo.getSnippet(id: "rw-outbox-ctx", includeContext: false, now: now)
        #expect(fromOutboxNoCtx.conversationContext == nil)

        let remoteWithCtx = try await repo.getSnippet(id: "memos/rw-remote-1", includeContext: true, now: now)
        #expect(remoteWithCtx.id == "rw-remote-1")
        #expect(remoteWithCtx.dataOrigin == .remote)
        #expect(remoteWithCtx.verbatimText == "Verbatim remote body")
        #expect(remoteWithCtx.conversationContext == remoteCtx)

        let remoteWithoutCtx = try await repo.getSnippet(id: "rw-remote-1", includeContext: false, now: now)
        #expect(remoteWithoutCtx.conversationContext == nil)

        let offlineCached = try await repo.getSnippet(id: "rw-cached-only", includeContext: true, now: now)
        #expect(offlineCached.dataOrigin == .localCache)
        #expect(offlineCached.verbatimText == "Cached fallback snippet")

        await #expect(throws: RewindError.snippetNotFound("plain-memo")) {
            _ = try await repo.getSnippet(id: "plain-memo", includeContext: true, now: now)
        }
        await #expect(throws: (any Error).self) {
            _ = try await repo.getSnippet(id: "missing-memo", includeContext: true, now: now)
        }
    }

    @Test("archiveSnippet flips tag to #rewind/synthesized preserving 100% verbatim body and evicts HotCache")
    func archiveSnippetPreservesVerbatimBodyAndUpdatesHotCache() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let verbatim = "Line 1 with #rewind/ready in body\n\n```python\ndef foo():\n\n    return 'bar — 100% 原文'\n```\nTrailing line"
        let initialRaw = """
        #rewind/pending #rewind/has-ctx #source/chatgpt

        > **Title:** Python Snippet
        > **Source:** [ChatGPT](https://chatgpt.com/c/123) · \(MemosWireFormat.formatISO8601UTC(now))

        \(verbatim)
        """
        let otherRaw = "#rewind/ready #source/macos\n\nKeep me in cache"

        let targetCard = try #require(MemosWireFormat.parseMemo(id: "rw-archive-1", rawContent: initialRaw, createdAt: now, now: now))
        let otherCard = try #require(MemosWireFormat.parseMemo(id: "rw-keep-2", rawContent: otherRaw, createdAt: now, now: now))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([targetCard, otherCard], now: now)

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, bodyData in
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET" && path == "/api/memos/rw-archive-1" {
                return (200, encodeJSON(MemoWireDTO(name: "memos/rw-archive-1", content: initialRaw, createTime: MemosWireFormat.formatISO8601UTC(now))))
            }
            if req.httpMethod == "PATCH" && path == "/api/memos/rw-archive-1" {
                let query = req.url?.query ?? ""
                guard query.contains("updateMask=content"),
                      let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
                      let patchedContent = json["content"] else {
                    return (400, Data())
                }
                return (200, encodeJSON(MemoWireDTO(name: "memos/rw-archive-1", content: patchedContent, createTime: MemosWireFormat.formatISO8601UTC(now))))
            }
            if req.httpMethod == "GET" && path == "/api/memos/non-rewind" {
                return (200, encodeJSON(MemoWireDTO(name: "memos/non-rewind", content: "Regular note", createTime: MemosWireFormat.formatISO8601UTC(now))))
            }
            return (404, Data())
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())

        let archived = try await repo.archiveSnippet(id: "memos/rw-archive-1")
        #expect(archived.id == "rw-archive-1")
        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText.utf8.elementsEqual(verbatim.utf8))

        let requests = SnippetMockURLProtocol.recordedRequests(suiteID: suiteID)
        #expect(requests.contains(where: { $0.method == "PATCH" && $0.url.query == "updateMask=content" }))

        let remainingCached = HotCache(fileURL: paths.hotCacheFileURL).loadCards(now: now)
        #expect(remainingCached.map(\.id) == ["rw-keep-2"])

        await #expect(throws: RewindError.snippetNotFound("non-rewind")) {
            _ = try await repo.archiveSnippet(id: "non-rewind")
        }
        let patchToNonRewind = SnippetMockURLProtocol.recordedRequests(suiteID: suiteID)
            .contains { $0.method == "PATCH" && $0.url.path.contains("non-rewind") }
        #expect(!patchToNonRewind)
    }

    @Test("DeveloperCredentialsResolver enforces token precedence, QA isolation, and NEVER falls back to Keychain when DeveloperCredentials.plist fails")
    func developerCredentialsPrecedenceQAIsolationAndZeroKeychainFallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)

        let cachedCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-safe-local",
            rawContent: "#rewind/ready #source/macos\n\nLocal safe fallback",
            createdAt: now,
            now: now
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([cachedCard], now: now)

        let customKeychainService = "com.codingrewind.memos.tests.\(UUID().uuidString.lowercased())"
        let keychainEnv = ["CODING_REWIND_KEYCHAIN_SERVICE": customKeychainService]
        defer { try? KeychainTokenStore.deleteToken(environment: keychainEnv) }
        try KeychainTokenStore.saveToken("PERSONAL-KEYCHAIN-SENTINEL-DO-NOT-READ", environment: keychainEnv)

        let opArgsURL = dir.appendingPathComponent("op-args.txt")
        let fakeOpURL = dir.appendingPathComponent("fake-op")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(opArgsURL.path)"
        if [ "${FAKE_OP_HANG:-0}" = "1" ]; then
          sleep 30
        fi
        printf '%s' "${FAKE_OP_OUTPUT:-dev-op-token}"
        exit "${FAKE_OP_EXIT:-0}"
        """.write(to: fakeOpURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpURL.path)

        let validPlistData = try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://dev-vault/memos/token",
            "op_executable": fakeOpURL.path
        ], format: .xml, options: 0)
        try AtomicFile.writeData(validPlistData, to: paths.developerCredentialsFileURL, permissions: 0o600)

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let dto = MemoWireDTO(
                name: "memos/rw-remote-auth",
                content: "#rewind/ready #source/macos\n\nAuthorized remote snippet",
                createTime: MemosWireFormat.formatISO8601UTC(now)
            )
            if req.url?.path == "/api/memos" {
                let payload: [String: Any] = [
                    "memos": [[
                        "name": dto.name,
                        "content": dto.content,
                        "createTime": dto.createTime!
                    ]]
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            }
            return (200, encodeJSON(dto))
        }

        let baseEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            "CODING_REWIND_KEYCHAIN_SERVICE": customKeychainService
        ]

        // Production default validator rejects unsigned fake-op and never falls back to personal Keychain
        let untrustedOpRepo = SnippetRepository(paths: paths, environment: baseEnv, client: makeMockClient())
        await #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            _ = try await untrustedOpRepo.archiveSnippet(id: "rw-safe-local")
        }
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).isEmpty)

        let validOpRepo = SnippetRepository(
            paths: paths,
            environment: baseEnv,
            client: makeMockClient(),
            executableValidator: { _ in true }
        )
        let opList = try await validOpRepo.listSnippets(now: now)
        #expect(opList.resolution == .online)
        #expect(opList.snippets.map(\.id) == ["rw-remote-auth"])
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).last?.authHeader == "Bearer dev-op-token")

        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([cachedCard], now: now)

        let failingOpEnv = baseEnv.merging(["FAKE_OP_EXIT": "1"]) { _, new in new }
        let failingOpRepo = SnippetRepository(
            paths: paths,
            environment: failingOpEnv,
            client: makeMockClient(),
            executableValidator: { _ in true }
        )
        let requestCountBeforeFailure = SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).count

        let degradedList = try await failingOpRepo.listSnippets(now: now)
        if case .offlineFallback(let reason) = degradedList.resolution {
            #expect(reason.contains("1Password"))
        } else {
            Issue.record("Expected offlineFallback when op fails, got \(degradedList.resolution)")
        }
        #expect(degradedList.snippets.map(\.id) == ["rw-safe-local"])

        let degradedGet = try await failingOpRepo.getSnippet(id: "rw-safe-local", includeContext: true, now: now)
        #expect(degradedGet.dataOrigin == .localCache)

        await #expect(throws: DeveloperCredentialsResolver.Failure.credentialReadFailed) {
            _ = try await failingOpRepo.archiveSnippet(id: "rw-safe-local")
        }
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).count == requestCountBeforeFailure)

        let timeoutEnv = baseEnv.merging(["FAKE_OP_HANG": "1"]) { _, new in new }
        let timeoutRepo = SnippetRepository(
            paths: paths,
            environment: timeoutEnv,
            client: makeMockClient(),
            credentialTimeoutSeconds: 0.15,
            executableValidator: { _ in true }
        )
        await #expect(throws: DeveloperCredentialsResolver.Failure.credentialReadTimedOut) {
            _ = try await timeoutRepo.archiveSnippet(id: "rw-safe-local")
        }
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).count == requestCountBeforeFailure)

        try Data("corrupt-plist".utf8).write(to: paths.developerCredentialsFileURL)
        let corruptRepo = SnippetRepository(paths: paths, environment: baseEnv, client: makeMockClient())
        let corruptList = try await corruptRepo.listSnippets(now: now)
        if case .offlineFallback(let reason) = corruptList.resolution {
            #expect(reason.contains("invalid"))
        } else {
            Issue.record("Expected offlineFallback on invalid plist, got \(corruptList.resolution)")
        }
        await #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            _ = try await corruptRepo.archiveSnippet(id: "rw-safe-local")
        }
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).count == requestCountBeforeFailure)

        try? FileManager.default.removeItem(at: opArgsURL)
        let qaEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.qaEnvironmentKey: "1",
            "CODING_REWIND_KEYCHAIN_SERVICE": customKeychainService
        ]
        #expect(KeychainTokenStore.serviceName(environment: qaEnv) == KeychainTokenStore.qaService)
        let qaResolution = DeveloperCredentialsResolver.resolveToken(paths: paths, environment: qaEnv)
        #expect(qaResolution != .resolved("PERSONAL-KEYCHAIN-SENTINEL-DO-NOT-READ"))
        if case .developerCredentialsFailed = qaResolution {
            Issue.record("QA mode must ignore DeveloperCredentials.plist")
        }
        #expect(!FileManager.default.fileExists(atPath: opArgsURL.path))
    }

    @Test("deleteSnippet handles remote 200, 404 idempotence, and refuses offline or 500 errors preserving HotCache")
    func deleteSnippetRemoteIdempotenceAndErrorPreservation() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-core-snippet-del-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let hotCache = HotCache(fileURL: paths.hotCacheFileURL)

        let card200 = try #require(MemosWireFormat.parseMemo(id: "rw-del-200", rawContent: "#rewind/ready #source/macos\n\nDelete 200", createdAt: now, now: now))
        let card404 = try #require(MemosWireFormat.parseMemo(id: "rw-del-404-cached", rawContent: "#rewind/ready #source/macos\n\nDelete 404 cached", createdAt: now, now: now))
        let card500 = try #require(MemosWireFormat.parseMemo(id: "rw-del-500", rawContent: "#rewind/ready #source/macos\n\nDelete 500", createdAt: now, now: now))
        let cardNetFail = try #require(MemosWireFormat.parseMemo(id: "rw-del-net", rawContent: "#rewind/ready #source/macos\n\nDelete net fail", createdAt: now, now: now))
        let cardKeep = try #require(MemosWireFormat.parseMemo(id: "rw-keep", rawContent: "#rewind/ready #source/macos\n\nKeep me", createdAt: now, now: now))
        try hotCache.saveCards([card200, card404, card500, cardNetFail, cardKeep], now: now)

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            guard req.httpMethod == "DELETE" else { return (405, Data()) }
            switch req.url?.path {
            case "/api/memos/rw-del-200":
                return (200, Data("{}".utf8))
            case "/api/memos/rw-del-404-cached", "/api/memos/rw-del-404-absent":
                return (404, Data("{\"message\":\"not found\"}".utf8))
            case "/api/memos/rw-del-500":
                return (500, Data("server boom".utf8))
            case "/api/memos/rw-del-net":
                return (-1, Data())
            default:
                return (404, Data())
            }
        }

        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let repo = SnippetRepository(paths: paths, environment: env, client: makeMockClient())

        let res200 = try await repo.deleteSnippet(id: "memos/rw-del-200")
        #expect(res200 == SnippetDeletionResult(id: "rw-del-200", deleted: true, disposition: .remoteAndLocal))
        #expect(!hotCache.loadCards(now: now).contains { $0.id == "rw-del-200" })

        let res404Cached = try await repo.deleteSnippet(id: "rw-del-404-cached")
        #expect(res404Cached == SnippetDeletionResult(id: "rw-del-404-cached", deleted: true, disposition: .alreadyAbsent))
        #expect(!hotCache.loadCards(now: now).contains { $0.id == "rw-del-404-cached" })

        let res404Absent = try await repo.deleteSnippet(id: "rw-del-404-absent")
        #expect(res404Absent == SnippetDeletionResult(id: "rw-del-404-absent", deleted: false, disposition: .alreadyAbsent))

        await #expect(throws: RewindError.httpError(statusCode: 500, body: "server boom")) {
            _ = try await repo.deleteSnippet(id: "rw-del-500")
        }
        await #expect(throws: (any Error).self) {
            _ = try await repo.deleteSnippet(id: "rw-del-net")
        }

        let unconfiguredRepo = SnippetRepository(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeMockClient())
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await unconfiguredRepo.deleteSnippet(id: "rw-keep")
        }

        #expect(Set(hotCache.loadCards(now: now).map(\.id)) == Set(["rw-del-500", "rw-del-net", "rw-keep"]))
    }

    @Test("deleteSnippet handles outbox offline/online/404/network failure, HTTP 500 refusal, QA missing-token fast fail, and invalid IDs")
    func deleteSnippetOutboxQAIsolationAndInvalidIDs() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-core-snippet-outbox-del-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        let hotCache = HotCache(fileURL: paths.hotCacheFileURL)

        func addPending(_ id: String) throws -> RewindCard {
            let raw = "#rewind/pending #source/macos\n\nPending \(id)"
            try outbox.enqueue(OutboxEntry(clientClipId: id, memoContent: raw, commentContent: nil, createdAt: now))
            return try #require(MemosWireFormat.parseMemo(id: id, rawContent: raw, createdAt: now, now: now, isOfflinePending: true))
        }

        let offlineCard = try addPending("rw-outbox-offline")
        let nonQACard = try addPending("rw-outbox-nonqa")
        let online200Card = try addPending("rw-outbox-200")
        let online404Card = try addPending("rw-outbox-404")
        let onlineNetCard = try addPending("rw-outbox-net")
        let online500Card = try addPending("rw-outbox-500")
        let qaBlockedCard = try addPending("rw-outbox-qa")
        try hotCache.saveCards([offlineCard, nonQACard, online200Card, online404Card, onlineNetCard, online500Card, qaBlockedCard], now: now)

        let offlineRepo = SnippetRepository(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeMockClient())
        #expect(try await offlineRepo.deleteSnippet(id: "rw-outbox-offline") == SnippetDeletionResult(id: "rw-outbox-offline", deleted: true, disposition: .localPendingOnly))
        #expect(!outbox.loadEntries().contains { $0.clientClipId == "rw-outbox-offline" })
        #expect(!hotCache.loadCards(now: now).contains { $0.id == "rw-outbox-offline" })

        let suiteID = UUID().uuidString.lowercased()
        defer { SnippetMockURLProtocol.unregister(suiteID: suiteID) }

        SnippetMockURLProtocol.register(suiteID: suiteID) { req, _ in
            guard req.httpMethod == "DELETE" else { return (405, Data()) }
            switch req.url?.path {
            case "/api/memos/rw-outbox-200":
                return (200, Data("{}".utf8))
            case "/api/memos/rw-outbox-404":
                return (404, Data())
            case "/api/memos/rw-outbox-net":
                return (-1, Data())
            case "/api/memos/rw-outbox-500":
                return (500, Data("db error".utf8))
            default:
                return (404, Data())
            }
        }

        let nonQAMissingTokenEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]
        let nonQARepo = SnippetRepository(paths: paths, environment: nonQAMissingTokenEnv, client: makeMockClient())
        #expect(try await nonQARepo.deleteSnippet(id: "rw-outbox-nonqa") == SnippetDeletionResult(id: "rw-outbox-nonqa", deleted: true, disposition: .localPendingOnly))
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: suiteID).isEmpty)

        let onlineEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        let onlineRepo = SnippetRepository(paths: paths, environment: onlineEnv, client: makeMockClient())

        #expect(try await onlineRepo.deleteSnippet(id: "memos/rw-outbox-200") == SnippetDeletionResult(id: "rw-outbox-200", deleted: true, disposition: .remoteAndLocal))
        #expect(try await onlineRepo.deleteSnippet(id: "rw-outbox-404") == SnippetDeletionResult(id: "rw-outbox-404", deleted: true, disposition: .localPendingOnly))
        #expect(try await onlineRepo.deleteSnippet(id: "rw-outbox-net") == SnippetDeletionResult(id: "rw-outbox-net", deleted: true, disposition: .localPendingOnly))

        await #expect(throws: RewindError.httpError(statusCode: 500, body: "db error")) {
            _ = try await onlineRepo.deleteSnippet(id: "rw-outbox-500")
        }
        #expect(outbox.loadEntries().contains { $0.clientClipId == "rw-outbox-500" })
        #expect(hotCache.loadCards(now: now).contains { $0.id == "rw-outbox-500" })

        let emptyQAKeychain = "com.codingrewind.memos.qa.empty.\(UUID().uuidString.lowercased())"
        let qaMissingTokenEnv = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            "CODING_REWIND_KEYCHAIN_SERVICE": emptyQAKeychain
        ]
        let qaMissingRepo = SnippetRepository(paths: paths, environment: qaMissingTokenEnv, client: makeMockClient())
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await qaMissingRepo.deleteSnippet(id: "rw-outbox-qa")
        }
        #expect(outbox.loadEntries().contains { $0.clientClipId == "rw-outbox-qa" })
        #expect(hotCache.loadCards(now: now).contains { $0.id == "rw-outbox-qa" })

        try Data("invalid-plist".utf8).write(to: paths.developerCredentialsFileURL)
        let failingDevRepo = SnippetRepository(
            paths: paths,
            environment: [StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local"],
            client: makeMockClient()
        )
        await #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            _ = try await failingDevRepo.deleteSnippet(id: "rw-outbox-500")
        }
        await #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            _ = try await failingDevRepo.deleteSnippet(id: "rw-remote-only")
        }

        for badID in ["", "   ", "../escape", "memos/", "a/b", "rw space"] {
            await #expect(throws: RewindError.invalidClipID(badID)) {
                _ = try await onlineRepo.deleteSnippet(id: badID)
            }
        }
    }
}

private final class MemoStore: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: String]

    init(_ contents: [String: String]) {
        self.contents = contents
    }

    subscript(id: String) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return contents[id] }
        set { lock.lock(); contents[id] = newValue; lock.unlock() }
    }

    var all: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return contents.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

private func installMemoStoreHandler(suiteID: String, store: MemoStore, createTime: String) {
    SnippetMockURLProtocol.register(suiteID: suiteID) { req, body in
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let path = components.path
        let respond: (String, String) -> (Int, Data) = { id, content in
            (200, try! JSONSerialization.data(withJSONObject: ["name": "memos/\(id)", "content": content, "createTime": createTime]))
        }
        switch (req.httpMethod ?? "GET", path) {
        case ("GET", "/api/memos"):
            let memos = store.all.map { ["name": "memos/\($0.0)", "content": $0.1, "createTime": createTime] }
            return (200, try! JSONSerialization.data(withJSONObject: ["memos": memos, "nextPageToken": ""]))
        case ("POST", "/api/memos"):
            let id = components.queryItems!.first { $0.name == "memoId" }!.value!
            if store[id] != nil { return (409, Data()) }
            let content = (try! JSONSerialization.jsonObject(with: body) as! [String: Any])["content"] as! String
            store[id] = content
            return respond(id, content)
        case ("GET", _):
            let id = String(path.dropFirst("/api/memos/".count))
            guard let content = store[id] else { return (404, Data()) }
            return respond(id, content)
        case ("PATCH", _):
            let id = String(path.dropFirst("/api/memos/".count))
            let content = (try! JSONSerialization.jsonObject(with: body) as! [String: Any])["content"] as! String
            store[id] = content
            return respond(id, content)
        default:
            return (400, Data())
        }
    }
}

@Suite("SnippetRepository places: list, upsert, cache and place filters")
struct SnippetRepositoryPlacesTests {
    private let now = Date(timeIntervalSince1970: 1_763_200_000)

    private func makeContext() throws -> (dir: URL, paths: StoragePaths, suiteID: String, env: [String: String]) {
        let dir = try makeTempDir()
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let suiteID = UUID().uuidString.lowercased()
        let env = [
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "token",
            StoragePaths.qaEnvironmentKey: "1"
        ]
        return (dir, paths, suiteID, env)
    }

    @Test("listPlaces reads place memos, hides archived by default, writes a 0600 cache and falls back to it offline")
    func listPlacesOnlineAndOffline() async throws {
        let ctx = try makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir); SnippetMockURLProtocol.unregister(suiteID: ctx.suiteID) }
        let paper = PlaceRecord(ref: PlaceRef(tag: "project/paper-02")!, title: "身体预设", aliases: ["论文02"])
        let old = PlaceRecord(ref: PlaceRef(tag: "topic/old")!, title: "Old", archived: true)
        let ada = PlaceRecord(ref: PlaceRef(tag: "person/ada")!, title: "Ada")
        let store = MemoStore([
            paper.ref.memoID: MemosWireFormat.formatPlaceMemo(paper, body: "notes"),
            old.ref.memoID: MemosWireFormat.formatPlaceMemo(old),
            ada.ref.memoID: MemosWireFormat.formatPlaceMemo(ada),
            "rw-1": "#rewind/ready #source/web #project/paper-02\n\nbody"
        ])
        installMemoStoreHandler(suiteID: ctx.suiteID, store: store, createTime: MemosWireFormat.formatISO8601UTC(now))
        let repo = SnippetRepository(paths: ctx.paths, environment: ctx.env, client: makeMockClient())

        let active = try await repo.listPlaces(includeArchived: false)
        #expect(active.resolution == .online)
        #expect(active.places == [paper, ada])
        #expect(try await repo.listPlaces(includeArchived: true).places == [paper, old, ada])

        let attributes = try FileManager.default.attributesOfItem(atPath: ctx.paths.placesCacheFileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        SnippetMockURLProtocol.unregister(suiteID: ctx.suiteID)
        let offline = try await repo.listPlaces(includeArchived: false)
        guard case .offlineFallback = offline.resolution else {
            Issue.record("expected offline fallback, got \(offline.resolution)")
            return
        }
        #expect(offline.places == [paper, ada])

        let localOnly = SnippetRepository(paths: ctx.paths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeMockClient())
        let local = try await localOnly.listPlaces(includeArchived: true)
        #expect(local.resolution == .localOnly)
        #expect(local.places == [paper, old, ada])
    }

    @Test("upsertPlace creates with the deterministic memoId, updates in place preserving the free body, and never queues offline")
    func upsertPlaceIsIdempotentAndOnlineOnly() async throws {
        let ctx = try makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir); SnippetMockURLProtocol.unregister(suiteID: ctx.suiteID) }
        let store = MemoStore([:])
        installMemoStoreHandler(suiteID: ctx.suiteID, store: store, createTime: MemosWireFormat.formatISO8601UTC(now))
        let repo = SnippetRepository(paths: ctx.paths, environment: ctx.env, client: makeMockClient())
        let ref = try #require(PlaceRef(tag: "project/paper-02"))

        let first = PlaceRecord(ref: ref, title: "身体预设", aliases: ["论文02"], externalRef: "Linear XWR-12")
        #expect(try await repo.upsertPlace(first) == first)
        #expect(store["pl-p-paper-02"] == MemosWireFormat.formatPlaceMemo(first))
        #expect(SnippetMockURLProtocol.recordedRequests(suiteID: ctx.suiteID).first?.body.contains("\"visibility\":\"PRIVATE\"") == true)

        let handBody = "## 位置页\n\n  手写正文\t保留\r\n\n"
        store["pl-p-paper-02"] = MemosWireFormat.formatPlaceMemo(first, body: handBody)
        let second = PlaceRecord(ref: ref, title: "著作权法的身体预设", aliases: ["论文02", "embodiment"], archived: true)
        #expect(try await repo.upsertPlace(second) == second)
        #expect(try await repo.upsertPlace(second) == second)
        let stored = try #require(store["pl-p-paper-02"])
        #expect(stored == MemosWireFormat.formatPlaceMemo(second, body: handBody))
        #expect(Data(try #require(MemosWireFormat.parsePlaceMemo(stored)).body.utf8) == Data(handBody.utf8))
        #expect(PlacesCache(fileURL: ctx.paths.placesCacheFileURL).load() == [second])

        store["pl-t-clash"] = "#rewind/ready #source/web\n\nnot a place"
        await #expect(throws: RewindError.self) {
            _ = try await repo.upsertPlace(PlaceRecord(ref: PlaceRef(tag: "topic/clash")!, title: "Clash"))
        }
        #expect(store["pl-t-clash"] == "#rewind/ready #source/web\n\nnot a place")

        SnippetMockURLProtocol.unregister(suiteID: ctx.suiteID)
        await #expect(throws: RewindError.self) {
            _ = try await repo.upsertPlace(first)
        }
        let localOnly = SnippetRepository(paths: ctx.paths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeMockClient())
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await localOnly.upsertPlace(first)
        }
        #expect(OfflineOutbox(fileURL: ctx.paths.outboxFileURL).loadEntries().isEmpty)
    }

    @Test("listSnippets filters by place across all time and derives the unplaced queue")
    func listSnippetsPlaceAndUnplacedFilters() async throws {
        let ctx = try makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir); SnippetMockURLProtocol.unregister(suiteID: ctx.suiteID) }
        let store = MemoStore([
            "pl-p-paper-02": MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: PlaceRef(tag: "project/paper-02")!, title: "P")),
            "rw-placed": "#rewind/ready #source/web #Project/Paper-02\n\nplaced",
            "rw-placed-synth": "#rewind/synthesized #source/web #project/paper-02\n\nplaced archived",
            "rw-unplaced-ready": "#rewind/ready #source/web #habit/run\n\nunplaced",
            "rw-unplaced-synth": "#rewind/synthesized #source/web\n\nunplaced archived",
            "rw-pending": "#rewind/pending #source/web\n\npending"
        ])
        installMemoStoreHandler(suiteID: ctx.suiteID, store: store, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-200 * 3600)))
        let repo = SnippetRepository(paths: ctx.paths, environment: ctx.env, client: makeMockClient())

        let placed = try await repo.listSnippets(SnippetQuery(windowHours: nil, status: .all, place: PlaceRef(tag: "project/paper-02")), now: now)
        #expect(placed.snippets.map(\.id) == ["rw-placed", "rw-placed-synth"])
        #expect(try await repo.listSnippets(SnippetQuery(place: PlaceRef(tag: "project/paper-02")), now: now).snippets.isEmpty)

        let unplaced = try await repo.listSnippets(SnippetQuery(windowHours: nil, status: .all, unplaced: true), now: now)
        #expect(unplaced.snippets.map(\.id) == ["rw-unplaced-ready", "rw-unplaced-synth"])
    }
}

private struct PlacesUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.emptySelection
    }
}

@MainActor
@Suite("AppCoordinator places: sections, picker, chips and place search")
struct AppCoordinatorPlacesTests {
    @Test("library refresh drives unplaced and map counts; picker and chip removal round-trip tags without touching the body")
    func placeSectionsPickerAndChips() async throws {
        let dir = try makeTempDir()
        let suiteID = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: dir); SnippetMockURLProtocol.unregister(suiteID: suiteID) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let paper = try #require(PlaceRef(tag: "project/paper-02"))
        let law = try #require(PlaceRef(tag: "topic/law"))
        let hotRaw = "#rewind/ready #source/web\n\n> **Title:** Hot one\n\n  hot body\n\n```\ncode\n```\n"
        let store = MemoStore([
            paper.memoID: MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: paper, title: "身体预设", aliases: ["embodiment"])),
            law.memoID: MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: law, title: "著作权法")),
            "pl-u-old": MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: PlaceRef(tag: "person/old")!, title: "Old", archived: true)),
            "rw-hot-1": hotRaw,
            "rw-hot-2": "#rewind/ready #source/web #project/paper-02\n\nplaced body",
            "rw-synth": "#rewind/synthesized #source/web\n\nold archived body"
        ])
        installMemoStoreHandler(suiteID: suiteID, store: store, createTime: MemosWireFormat.formatISO8601UTC(Date()))
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).snippet.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "token",
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            memosClient: makeMockClient(),
            capturer: PlacesUnusedCapturer()
        )
        #expect(coordinator.unplacedCount == nil)

        await coordinator.refresh()
        await coordinator.refreshPlaceLibrary()
        #expect(Set(coordinator.cards.map(\.id)) == ["rw-hot-1", "rw-hot-2"])
        #expect(coordinator.activePlaces.map(\.ref) == [paper, law])
        #expect(coordinator.unplacedCount == 2)
        #expect(coordinator.placeClipCounts[paper] == 1)
        #expect(coordinator.placeTitle(for: paper) == "身体预设")
        #expect(coordinator.placeTitle(for: PlaceRef(tag: "topic/unknown")!) == "unknown")

        coordinator.searchText = "Embodiment"
        #expect(coordinator.filteredCards.map(\.id) == ["rw-hot-2"])
        coordinator.searchText = ""

        coordinator.hudSection = .unplaced
        #expect(coordinator.filteredCards.isEmpty)
        #expect(coordinator.browseRecords.map(\.id) == ["rw-hot-1", "rw-synth"])
        #expect(coordinator.browseRecords.first { $0.id == "rw-synth" }?.status == .synthesized)

        coordinator.hudSection = .hot
        coordinator.focusedCardID = "rw-hot-1"
        #expect(coordinator.openPlacePicker())
        #expect(coordinator.placePicker?.targetID == "rw-hot-1")
        #expect(coordinator.placePickerMatches.map(\.ref) == [paper, law])
        coordinator.updatePlacePickerQuery("zzz")
        #expect(coordinator.placePickerMatches.isEmpty)
        coordinator.updatePlacePickerQuery("law")
        await coordinator.commitPlacePicker()
        #expect(coordinator.placePicker == nil)
        let placed = try #require(store["rw-hot-1"])
        #expect(placed.hasPrefix("#rewind/ready #source/web #topic/law\n"))
        #expect(placed.hasSuffix("\n\n  hot body\n\n```\ncode\n```\n"))
        #expect(coordinator.cards.first { $0.id == "rw-hot-1" }?.places == [law])
        #expect(coordinator.unplacedCount == 1)

        await coordinator.removePlace(law, from: "rw-hot-1")
        #expect(store["rw-hot-1"] == hotRaw)
        #expect(coordinator.cards.first { $0.id == "rw-hot-1" }?.places == [])

        await coordinator.showPlace(paper)
        #expect(coordinator.hudSection == .place(paper))
        #expect(coordinator.filteredCards.isEmpty)
        #expect(coordinator.browseRecords.map(\.id) == ["rw-hot-2"])
        #expect(coordinator.openPlacePicker())
        #expect(coordinator.placePicker?.targetID == "rw-hot-2")
        #expect(coordinator.placePickerMatches.map(\.ref) == [law])
        coordinator.hudSection = .map
        #expect(coordinator.placePicker == nil)
        #expect(!coordinator.openPlacePicker())

        SnippetMockURLProtocol.unregister(suiteID: suiteID)
        await coordinator.removePlace(paper, from: "rw-hot-2")
        #expect(coordinator.isErrorBanner)
        #expect(store["rw-hot-2"] == "#rewind/ready #source/web #project/paper-02\n\nplaced body")
    }
}

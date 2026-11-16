// SPDX-License-Identifier: MIT

import Foundation
import os
import Testing
@testable import CodingRewindCore

private final class ProvenanceMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private static let requestCounts = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    static func register(suiteID: String, handler: @escaping Handler) {
        handlers.withLock { $0[suiteID] = handler }
        requestCounts.withLock { $0[suiteID] = [] }
    }

    static func unregister(suiteID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: suiteID) }
        _ = requestCounts.withLock { $0.removeValue(forKey: suiteID) }
    }

    static func recordedPaths(suiteID: String) -> [String] {
        requestCounts.withLock { $0[suiteID] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".provenance.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".provenance.mock.local", with: "")
        let method = request.httpMethod ?? "GET"
        Self.requestCounts.withLock { $0[suiteID, default: []].append("\(method) \(url.path)") }
        guard let handler = Self.handlers.withLock({ $0[suiteID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (statusCode, data) = try handler(request)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FixedSelectionCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

@Suite("Provenance Lead, SourceLocator, Fence-Protected Context & Coordinator Detail State")
struct ProvenanceLeadAndSourceLocatorTests {
    private func makeTestDir() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data/provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("CaptureContext normalizes NUL/whitespace, evaluates 5-field isEmpty, and uses flat backward-compatible JSON")
    func captureContextNormalizationAndFlatCodable() throws {
        let empty = CaptureContext(
            sessionTitle: " \0 \n ",
            sessionID: "  \0  ",
            lead: .sessionOpening(" \0\t "),
            prompt: "\0",
            recentTurns: [ConversationTurn(role: "User", text: " \0 ")]
        )
        #expect(empty.isEmpty)
        #expect(empty.sessionID == nil)
        #expect(empty.lead == nil)
        #expect(empty.sessionOpening == nil)
        #expect(empty.pageLead == nil)

        let idOnly = CaptureContext(sessionTitle: "", sessionID: "  chat-42\0 ", prompt: "")
        #expect(!idOnly.isEmpty)
        #expect(idOnly.sessionID == "chat-42")

        let pageOnly = CaptureContext(sessionTitle: "", lead: .pageLead(" \0Intro paragraph\n"), prompt: "")
        #expect(!pageOnly.isEmpty)
        #expect(pageOnly.pageLead == "Intro paragraph")
        #expect(pageOnly.sessionOpening == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let legacy = CaptureContext(sessionTitle: "Legacy Chat", prompt: "Why?", recentTurns: [])
        let legacyJSON = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        #expect(!legacyJSON.contains("sessionID"))
        #expect(!legacyJSON.contains("sessionOpening"))
        #expect(!legacyJSON.contains("pageLead"))
        #expect(!legacyJSON.contains("\"lead\""))
        #expect(try decoder.decode(CaptureContext.self, from: Data(legacyJSON.utf8)) == legacy)

        let chatCtx = CaptureContext(
            sessionTitle: "Architecture",
            sessionID: "6eb720d3-188b-4783-a0c6-9592c554f3fc",
            lead: .sessionOpening("Build a docked inspector"),
            prompt: "How should Esc behave?",
            recentTurns: [ConversationTurn(role: "User", text: "How should Esc behave?")]
        )
        let chatJSON = String(decoding: try encoder.encode(chatCtx), as: UTF8.self)
        #expect(chatJSON.contains("\"sessionID\":\"6eb720d3-188b-4783-a0c6-9592c554f3fc\""))
        #expect(chatJSON.contains("\"sessionOpening\":\"Build a docked inspector\""))
        #expect(!chatJSON.contains("\"pageLead\""))
        #expect(!chatJSON.contains("\"lead\""))
        #expect(try decoder.decode(CaptureContext.self, from: Data(chatJSON.utf8)) == chatCtx)

        let webCtx = CaptureContext(
            sessionTitle: "W3C Spec",
            lead: .pageLead("Text fragments link directly to a snippet of text."),
            prompt: ""
        )
        let webJSON = String(decoding: try encoder.encode(webCtx), as: UTF8.self)
        #expect(webJSON.contains("\"pageLead\":\"Text fragments link directly to a snippet of text.\""))
        #expect(!webJSON.contains("\"sessionOpening\""))
        #expect(!webJSON.contains("\"sessionID\""))
        #expect(try decoder.decode(CaptureContext.self, from: Data(webJSON.utf8)) == webCtx)
    }

    @Test("SourceLocator parses conversation://, http(s) with W3C text fragments, chat session IDs, and preserves handoff prompt citations")
    func sourceLocatorParsingAndChatSessionIDExtraction() throws {
        #expect(
            SourceLocator.parse(sourceURL: "conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc")
                == .antigravitySession(sessionID: "6eb720d3-188b-4783-a0c6-9592c554f3fc")
        )
        #expect(
            SourceLocator.parse(sourceURL: "conversation://conv-alpha/")
                == .antigravitySession(sessionID: "conv-alpha")
        )
        #expect(SourceLocator.parse(sourceURL: "conversation://") == nil)
        #expect(SourceLocator.parse(sourceURL: "conversation:///") == nil)
        #expect(SourceLocator.parse(sourceURL: "macos://xcode") == nil)
        #expect(SourceLocator.parse(sourceURL: "file:///Users/dev/guide.md") == nil)
        #expect(SourceLocator.parse(sourceURL: nil) == nil)
        #expect(SourceLocator.parse(sourceURL: "   ") == nil)

        let w3cURL = "https://developer.apple.com/documentation/swift#overview:~:text=prefix-,Sendable%20conformance,actor%20isolation,-suffix"
        let parsedW3C = try #require(SourceLocator.parse(sourceURL: w3cURL))
        #expect(parsedW3C == .web(url: try #require(URL(string: w3cURL)), sessionID: nil))
        #expect(parsedW3C.sessionID == nil)

        let chatCases: [(String, String?)] = [
            ("https://chatgpt.com/c/67f12345-abcd", "67f12345-abcd"),
            ("https://chat.openai.com/g/g-swift-pro/c/67f12345-abcd#:~:text=actor", "67f12345-abcd"),
            ("https://chatgpt.com/", nil),
            ("https://claude.ai/chat/99887766-aaaa", "99887766-aaaa"),
            ("https://claude.ai/new", nil),
            ("https://gemini.google.com/app/abcdef0123456789", "abcdef0123456789"),
            ("https://gemini.google.com/u/1/app/abcdef0123456789", "abcdef0123456789"),
            ("https://gemini.google.com/app", nil)
        ]
        for (rawURL, expectedID) in chatCases {
            let locator = try #require(SourceLocator.parse(sourceURL: rawURL))
            #expect(locator.sessionID == expectedID)
        }

        let geminiHomeCard = RewindCard(
            id: "rw-gem-home",
            rawContent: "#rewind/ready #source/gemini\n\nExcerpt",
            status: .ready,
            sourcePlatform: "gemini",
            sourceTitle: "Gemini",
            sourceURL: "https://gemini.google.com/app",
            verbatimText: "Excerpt",
            createdAt: Date(timeIntervalSince1970: 1_763_300_000)
        )
        let fallbackCtx = CaptureContext(sessionTitle: "Gemini", sessionID: "fallback-gem-id", prompt: "Hi")
        #expect(geminiHomeCard.effectiveSessionID(context: nil) == nil)
        #expect(geminiHomeCard.effectiveSessionID(context: fallbackCtx) == "fallback-gem-id")

        let antigravityCard = RewindCard(
            id: "rw-ag-1",
            rawContent: "#rewind/ready #source/antigravity\n\nAG Excerpt",
            status: .ready,
            sourcePlatform: "antigravity",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc",
            verbatimText: "AG Excerpt",
            createdAt: Date(timeIntervalSince1970: 1_763_300_000)
        )
        let w3cCard = RewindCard(
            id: "rw-w3c-1",
            rawContent: "#rewind/ready #source/web\n\nW3C Excerpt",
            status: .ready,
            sourcePlatform: "web",
            sourceTitle: "Swift Docs",
            sourceURL: w3cURL,
            verbatimText: "W3C Excerpt",
            createdAt: Date(timeIntervalSince1970: 1_763_300_000)
        )
        let prompt = ConversationPrompt.buildPrompt(for: [antigravityCard, w3cCard], language: .en)
        #expect(prompt.contains("conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc"))
        #expect(prompt.contains(w3cURL))
    }

    @Test("MemosWireFormat round-trips new sections, protects fenced blocks across all headings, and shares parseMemoComments")
    func fenceProtectedWireFormatAndSharedCommentParser() throws {
        let fencedOpening = """
        Design goal:
        ```markdown
        ### Page Lead
        ### Prompt
        ### Recent Turns
        User: fake turn inside opening fence
        ```
        Keep everything intact.
        """
        let fencedPrompt = """
        Check tilde fence:
        ~~~md
        ### Session Opening
        ### Page Lead
        ### Recent Turns
        Assistant: fake turn inside prompt fence
        ~~~
        Real prompt tail.
        """
        let original = CaptureContext(
            sessionTitle: "Fence Safety",
            sessionID: "sess-fence-1",
            lead: .sessionOpening(fencedOpening),
            prompt: fencedPrompt,
            recentTurns: [
                ConversationTurn(
                    role: "User",
                    text: "```md\n### Session Opening\nAssistant: nested fake\n```"
                ),
                ConversationTurn(role: "Assistant", text: "Verified safe.")
            ]
        )
        let wire = original.formattedCommentMarkdown()
        #expect(wire.hasPrefix("<!-- rewind-context-v1 -->\n"))
        #expect(wire.contains("Session ID: sess-fence-1"))
        #expect(wire.contains("\n\n### Session Opening\n"))
        #expect(MemosWireFormat.parseContextComment(wire) == original)

        let reorderedSections = """
        <!-- rewind-context-v1 -->
        Session ID: reordered-99
        Session Title: Reordered Title

        ### Recent Turns
        User: Turn A
        Assistant: Turn B

        ### Page Lead
        ~~~yaml
        ### Prompt
        User: not a turn
        ~~~
        Article lead conclusion.

        ### Prompt
        Section-form prompt line 1
        line 2
        """
        let parsedReordered = try #require(MemosWireFormat.parseContextComment(reorderedSections))
        #expect(parsedReordered.sessionTitle == "Reordered Title")
        #expect(parsedReordered.sessionID == "reordered-99")
        #expect(parsedReordered.pageLead?.contains("### Prompt\nUser: not a turn") == true)
        #expect(parsedReordered.pageLead?.hasSuffix("Article lead conclusion.") == true)
        #expect(parsedReordered.prompt == "Section-form prompt line 1\nline 2")
        #expect(parsedReordered.recentTurns.count == 2)

        let now = Date(timeIntervalSince1970: 1_763_300_000)
        let noteRaw = try MemosWireFormat.formatNoteComment(
            note: "Synthesized takeaway",
            author: "codex",
            createdAt: now.addingTimeInterval(20)
        )
        let localNote = SnippetNote(
            id: "rw-note-local",
            author: "local",
            content: "Offline annotation",
            createdAt: now.addingTimeInterval(10)
        )
        let comments = [
            MemoWireDTO(name: "memos/c-ctx", content: wire, createTime: MemosWireFormat.formatISO8601UTC(now)),
            MemoWireDTO(name: "memos/rw-note-remote", content: noteRaw, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(20)))
        ]
        let merged = MemosWireFormat.parseMemoComments(comments, localNotes: [localNote], includeContext: true, now: now)
        #expect(merged.context == original)
        #expect(merged.notes.map(\.id) == ["rw-note-local", "rw-note-remote"])

        let withoutCtx = MemosWireFormat.parseMemoComments(comments, localNotes: [localNote], includeContext: false, now: now)
        #expect(withoutCtx.context == nil)
        #expect(withoutCtx.notes.map(\.id) == ["rw-note-local", "rw-note-remote"])
    }

    @Test("Capture slicers truncate sessionOpening at 300 chars and NativeConversationContext enforces virtualization .gap guard")
    func captureSlicersSessionOpeningTruncationAndGapGuard() throws {
        let longOpening = String(repeating: "o", count: 340)
        let entriesWithOpening: [NativeConversationSnapshot.Entry] = [
            .message(.init(role: .user, renderedText: longOpening)),
            .message(.init(role: .assistant, renderedText: "Answer 1")),
            .gap,
            .message(.init(role: .user, renderedText: "Turn 10 prompt")),
            .message(.init(role: .assistant, renderedText: "Selected answer 10"))
        ]
        let backlink = try #require(URL(string: "https://chatgpt.com/g/g-arch/c/chat-uuid-777"))
        let resolvedWithOpening = try #require(NativeConversationContext.resolve(
            selectedText: "Selected answer 10",
            snapshot: .init(entries: entriesWithOpening),
            sessionTitle: "Long Session",
            backlink: backlink
        ))
        #expect(resolvedWithOpening.sessionID == "chat-uuid-777")
        #expect(resolvedWithOpening.sessionOpening == String(repeating: "o", count: 300) + "…")
        #expect(resolvedWithOpening.prompt == "Turn 10 prompt")

        let entriesWithLeadingGap: [NativeConversationSnapshot.Entry] = [
            .gap,
            .message(.init(role: .user, renderedText: "Scrolled mid-session question")),
            .message(.init(role: .assistant, renderedText: "Scrolled mid-session answer"))
        ]
        let resolvedMidSession = try #require(NativeConversationContext.resolve(
            selectedText: "Scrolled mid-session answer",
            snapshot: .init(entries: entriesWithLeadingGap),
            sessionTitle: "Virtualized Session",
            backlink: URL(string: "https://gemini.google.com/u/0/app/gem-session-888")
        ))
        #expect(resolvedMidSession.sessionID == "gem-session-888")
        #expect(resolvedMidSession.sessionOpening == nil)
        #expect(resolvedMidSession.lead == nil)
        #expect(resolvedMidSession.prompt == "Scrolled mid-session question")
    }

    @Test("AppCoordinator keeps copy/source actions hermetic and resolves 3-tier CardDetail across offline, remote, cache, flush, and delete")
    @MainActor
    func coordinatorHermeticActionsAndCardDetailLifecycle() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ProvenanceMockURLProtocol.unregister(suiteID: suiteID) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProvenanceMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: config))
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )

        let backlink = try #require(URL(string: "https://chatgpt.com/c/offline-chat-1"))
        let native = NativeChatCapture(
            host: .chatGPT,
            title: "Offline Chat",
            backlink: backlink,
            snapshot: .init(entries: [
                .message(.init(role: .user, renderedText: "Initial design goal")),
                .message(.init(role: .assistant, renderedText: "First reply")),
                .message(.init(role: .user, renderedText: "Follow-up prompt")),
                .message(.init(role: .assistant, renderedText: "Offline captured excerpt"))
            ])
        )
        let selection = CapturedSelection(
            text: "Offline captured excerpt",
            bundleIdentifier: "com.openai.chat",
            appName: "ChatGPT",
            nativeChat: native
        )

        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            memosClient: memosClient,
            capturer: FixedSelectionCapturer(selection: selection),
            language: .en
        )

        var copiedStrings: [String] = []
        var openedURLs: [URL] = []
        var wokenHosts: [ConversationHost] = []
        coord.onCopyText = { copiedStrings.append($0) }
        coord.onOpenURL = { url in
            openedURLs.append(url)
            return false
        }
        coord.onWakeHost = { wokenHosts.append($0) }

        let outcome = await coord.captureSelection()
        guard case .queuedOffline(let offlineID) = outcome else {
            Issue.record("Expected offline queued capture")
            return
        }

        let localStore = LocalNotesStore(fileURL: paths.localNotesFileURL)
        try localStore.appendNote(
            SnippetNote(id: "note-1", author: "agent", content: "Local note body", createdAt: Date(timeIntervalSince1970: 1_763_300_010)),
            for: offlineID
        )

        coord.toggleCardPreview(id: offlineID)
        #expect(coord.inspectedCardID == offlineID)
        #expect(ProvenanceMockURLProtocol.recordedPaths(suiteID: suiteID).isEmpty)
        guard case .loaded(let offlineDetail) = coord.cardDetailState(for: offlineID) else {
            Issue.record("Expected synchronous loaded state for offline card")
            return
        }
        #expect(!offlineDetail.isCompleteFromServer)
        #expect(offlineDetail.context?.sessionID == "offline-chat-1")
        #expect(offlineDetail.context?.sessionOpening == "Initial design goal")
        #expect(offlineDetail.context?.prompt == "Follow-up prompt")
        #expect(offlineDetail.notes.map(\.content) == ["Local note body"])

        let offlineCard = try #require(coord.inspectedCard)
        coord.performSourceAction(for: offlineCard)
        #expect(openedURLs == [backlink])
        #expect(coord.isErrorBanner)
        #expect(coord.bannerMessage?.contains(backlink.absoluteString) == true)

        let agCard = RewindCard(
            id: "rw-ag-only",
            rawContent: "#rewind/ready #source/antigravity\n\nAG snippet",
            status: .ready,
            sourcePlatform: "antigravity",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://6eb720d3-188b-4783-a0c6-9592c554f3fc",
            verbatimText: "AG snippet",
            createdAt: Date()
        )
        openedURLs.removeAll()
        coord.performSourceAction(for: agCard)
        #expect(openedURLs.isEmpty)
        #expect(copiedStrings == ["6eb720d3-188b-4783-a0c6-9592c554f3fc"])
        #expect(!coord.isErrorBanner)

        coord.copyClipText("Clip body to copy")
        #expect(copiedStrings.last == "Clip body to copy")
        coord.wakeAntigravity()
        #expect(wokenHosts == [.antigravity])

        let remoteCtx = CaptureContext(
            sessionTitle: "Synced Session",
            sessionID: "synced-sess-1",
            lead: .sessionOpening("Synced opening"),
            prompt: "Synced prompt",
            recentTurns: [ConversationTurn(role: "User", text: "Synced prompt")]
        )
        let shouldFailComments = OSAllocatedUnfairLock(initialState: true)
        let nowISO = MemosWireFormat.formatISO8601UTC(Date())
        ProvenanceMockURLProtocol.register(suiteID: suiteID) { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "POST" && path == "/api/memos" {
                let dto = MemoWireDTO(
                    name: "memos/server-flushed-1",
                    content: "#rewind/ready #source/chatgpt\n\nOffline captured excerpt",
                    createTime: nowISO
                )
                return (200, try JSONEncoder().encode(dto))
            }
            if req.httpMethod == "POST" && path.hasSuffix("/comments") {
                let dto = MemoWireDTO(name: "memos/c-1", content: "", createTime: nowISO)
                return (200, try JSONEncoder().encode(dto))
            }
            if req.httpMethod == "GET" && path == "/api/memos" {
                let dto = MemoWireDTO(
                    name: "memos/server-flushed-1",
                    content: "#rewind/ready #source/chatgpt\n\nOffline captured excerpt",
                    createTime: nowISO
                )
                return (200, try JSONEncoder().encode(["memos": [dto]]))
            }
            if req.httpMethod == "GET" && path == "/api/memos/server-flushed-1/comments" {
                if shouldFailComments.withLock({ $0 }) {
                    return (502, Data("Bad Gateway".utf8))
                }
                let commentDTO = MemoWireDTO(
                    name: "memos/c-ctx",
                    content: remoteCtx.formattedCommentMarkdown(),
                    createTime: nowISO
                )
                return (200, try JSONEncoder().encode(["memos": [commentDTO]]))
            }
            if req.httpMethod == "DELETE" {
                return (200, Data("{}".utf8))
            }
            return (404, Data("{}".utf8))
        }

        coord.environment[StoragePaths.memosURLEnvironmentKey] = "https://\(suiteID).provenance.mock.local"
        coord.environment[StoragePaths.memosTokenEnvironmentKey] = "qa-prov-token"

        await coord.refresh()
        #expect(coord.inspectedCardID == "server-flushed-1")

        for _ in 0..<50 {
            if case .failed = coord.cardDetailState(for: "server-flushed-1") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = coord.cardDetailState(for: "server-flushed-1") else {
            Issue.record("Expected failed state when /comments returns HTTP 502")
            return
        }

        shouldFailComments.withLock { $0 = false }
        coord.reloadCardDetail(id: "server-flushed-1")
        for _ in 0..<50 {
            if case .loaded(let d) = coord.cardDetailState(for: "server-flushed-1"), d.isCompleteFromServer { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .loaded(let remoteDetail) = coord.cardDetailState(for: "server-flushed-1") else {
            Issue.record("Expected loaded state after retry")
            return
        }
        #expect(remoteDetail.isCompleteFromServer)
        #expect(remoteDetail.context == remoteCtx)

        let countBeforeReopen = ProvenanceMockURLProtocol.recordedPaths(suiteID: suiteID)
            .filter { $0 == "GET /api/memos/server-flushed-1/comments" }.count
        coord.closeCardPreview()
        #expect(coord.inspectedCardID == nil)
        coord.toggleCardPreview(id: "server-flushed-1")
        let countAfterReopen = ProvenanceMockURLProtocol.recordedPaths(suiteID: suiteID)
            .filter { $0 == "GET /api/memos/server-flushed-1/comments" }.count
        #expect(countAfterReopen == countBeforeReopen)

        await coord.requestDeleteCards(ids: ["server-flushed-1"], bypassConfirmation: true)
        #expect(coord.inspectedCardID == nil)
        #expect(coord.cardDetailState(for: "server-flushed-1") == .idle)
    }
}

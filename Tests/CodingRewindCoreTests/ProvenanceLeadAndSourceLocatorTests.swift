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
            ("https://claude.ai/project/proj-uuid-1/chat/99887766-bbbb", "99887766-bbbb"),
            ("https://www.claude.ai/project/proj-uuid-1/chat/99887766-cccc#:~:text=hello", "99887766-cccc"),
            ("https://claude.ai/project/proj-uuid-1", nil),
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
        guard case .failed(let partialOn502, _) = coord.cardDetailState(for: "server-flushed-1") else {
            Issue.record("Expected failed state when /comments returns HTTP 502")
            return
        }
        #expect(partialOn502?.context?.sessionOpening == "Initial design goal")
        #expect(partialOn502?.notes.map(\.content) == ["Local note body"])
        #expect(localStore.loadNotes(for: offlineID).isEmpty)
        #expect(localStore.loadNotes(for: "server-flushed-1").map(\.content) == ["Local note body"])

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
        #expect(remoteDetail.notes.map(\.content) == ["Local note body"])

        let countBeforeReopen = ProvenanceMockURLProtocol.recordedPaths(suiteID: suiteID)
            .filter { $0 == "GET /api/memos/server-flushed-1/comments" }.count
        coord.closeCardPreview()
        #expect(coord.inspectedCardID == nil)
        coord.toggleCardPreview(id: "server-flushed-1")
        let countAfterReopen = ProvenanceMockURLProtocol.recordedPaths(suiteID: suiteID)
            .filter { $0 == "GET /api/memos/server-flushed-1/comments" }.count
        #expect(countAfterReopen == countBeforeReopen)

        ProvenanceMockURLProtocol.register(suiteID: suiteID) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await coord.refresh()
        #expect(coord.isErrorBanner)
        #expect(coord.inspectedCardID == "server-flushed-1")
        guard case .loaded(let preservedAfterDrop) = coord.cardDetailState(for: "server-flushed-1") else {
            Issue.record("Expected network drop during refresh to preserve loaded card detail")
            return
        }
        #expect(preservedAfterDrop == remoteDetail)

        ProvenanceMockURLProtocol.register(suiteID: suiteID) { req in
            if req.httpMethod == "DELETE" {
                return (200, Data("{}".utf8))
            }
            return (200, Data("{\"memos\":[]}".utf8))
        }
        await coord.requestDeleteCards(ids: ["server-flushed-1"], bypassConfirmation: true)
        #expect(coord.inspectedCardID == nil)
        #expect(coord.cardDetailState(for: "server-flushed-1") == .idle)
        #expect(localStore.loadNotes(for: "server-flushed-1").isEmpty)
    }

    @Test("Truncated or unclosed Markdown code fences close cleanly without swallowing subsequent sections or turns")
    func truncatedAndUnclosedCodeFencesRoundTripCleanly() throws {
        let longFencedOpening = "Setup:\n```swift\n" + String(repeating: "let value = 42\n", count: 30) + "```\nTail"
        let longFencedTurn = "Script:\n~~~bash\n" + String(repeating: "echo step\n", count: 100) + "~~~\nDone"
        let sliced = try #require(ConversationContextSlicer.slice(
            selectedText: "Final Chinese summary 你好世界",
            messages: [
                .init(role: .user, matchText: longFencedOpening),
                .init(role: .assistant, matchText: longFencedTurn),
                .init(role: .user, matchText: "Summarize in Chinese"),
                .init(role: .assistant, matchText: "Final Chinese summary 你好世界")
            ],
            anchor: .uniqueSubstring,
            sessionTitle: "Truncation Fence Safety",
            sessionID: "sess-trunc-fence"
        ))
        #expect(sliced.sessionOpening?.hasSuffix("…\n```") == true)
        let wire = sliced.formattedCommentMarkdown()
        let reparsed = try #require(MemosWireFormat.parseContextComment(wire))
        #expect(reparsed == sliced)
        #expect(reparsed.recentTurns.count == 4)
        #expect(reparsed.recentTurns.last?.text == "Final Chinese summary 你好世界")

        let streamInterrupted = CaptureContext(
            sessionTitle: "Interrupted Stream",
            sessionID: "sess-interrupted",
            lead: .sessionOpening("````markdown\n```python\nunclosed nested fence"),
            prompt: "```ts\nconst broken = true;",
            recentTurns: [
                ConversationTurn(role: "User", text: "```ts\nconst broken = true;"),
                ConversationTurn(role: "Assistant", text: "~~~sh\ncurl -s https://example.com"),
                ConversationTurn(role: "User", text: "Did all turns survive?"),
                ConversationTurn(role: "Assistant", text: "Yes, every turn survived.")
            ]
        )
        let interruptedWire = streamInterrupted.formattedCommentMarkdown()
        let parsedInterrupted = try #require(MemosWireFormat.parseContextComment(interruptedWire))
        #expect(parsedInterrupted.sessionOpening?.hasSuffix("\n````") == true)
        #expect(parsedInterrupted.prompt.hasSuffix("\n```"))
        #expect(parsedInterrupted.recentTurns.count == 4)
        #expect(parsedInterrupted.recentTurns[2].text == "Did all turns survive?")
        #expect(parsedInterrupted.recentTurns[3].text == "Yes, every turn survived.")
    }

    @Test("Multi-line Prompt lines starting with Session ID or Session Title never hijack headers or drop prompt lines")
    func multiLinePromptDoesNotHijackSessionHeaders() throws {
        let promptWithHeaderLookalikes = """
        Investigate this crash log:
        Session ID: hijacked-session-999
        Session Title: Hijacked Session Title
        Final line of user prompt.
        """
        let withExplicitHeaders = CaptureContext(
            sessionTitle: "Real Title",
            sessionID: "real-session-123",
            lead: .sessionOpening("Initial question"),
            prompt: promptWithHeaderLookalikes,
            recentTurns: [ConversationTurn(role: "User", text: promptWithHeaderLookalikes)]
        )
        let parsedWithHeaders = try #require(MemosWireFormat.parseContextComment(withExplicitHeaders.formattedCommentMarkdown()))
        #expect(parsedWithHeaders.sessionTitle == "Real Title")
        #expect(parsedWithHeaders.sessionID == "real-session-123")
        #expect(parsedWithHeaders.prompt == promptWithHeaderLookalikes)

        let withoutPriorSessionHeaders = CaptureContext(
            sessionTitle: "",
            sessionID: nil,
            prompt: promptWithHeaderLookalikes
        )
        let parsedWithoutHeaders = try #require(MemosWireFormat.parseContextComment(withoutPriorSessionHeaders.formattedCommentMarkdown()))
        #expect(parsedWithoutHeaders.sessionTitle.isEmpty)
        #expect(parsedWithoutHeaders.sessionID == nil)
        #expect(parsedWithoutHeaders.prompt == promptWithHeaderLookalikes)
    }

    @Test("MemosWireFormat escapes and unescapes backslashes and brackets in sourceTitle without link corruption")
    func backslashAndBracketSourceTitleRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_763_300_000)
        let url = "https://claude.ai/project/proj-42/chat/sess-99#:~:text= Sendable".replacingOccurrences(of: " ", with: "%20")
        let trickyTitles = [
            #"C:\Users\dev\workspace\"#,
            #" inject\](https://evil.example)tail"#.trimmingCharacters(in: .whitespaces),
            #"\[foo\]"#,
            #"\\[bar\\]"#,
            #"Windows\Path\[v1\]\"#
        ]
        for title in trickyTitles {
            let raw = try MemosWireFormat.formatRawMemoContent(
                verbatimText: "Body",
                sourcePlatform: "claude",
                sourceTitle: title,
                sourceURL: url,
                capturedAt: now,
                hasContext: false
            )
            let card = try #require(MemosWireFormat.parseMemo(
                id: "rw-bs",
                rawContent: raw,
                createdAt: now,
                now: now
            ))
            #expect(card.sourceTitle == title)
            #expect(card.sourceURL == url)
            #expect(card.sourceLocator?.sessionID == "sess-99")
        }
    }

    @Test("Filter reconciliation closes hidden inspected cards, targetActionCardIDs prioritizes visible inspectedCard, and LocalNotesStore remaps IDs")
    @MainActor
    func filterReconciliationTargetCardSafetyAndNoteIDRemap() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ProvenanceMockURLProtocol.unregister(suiteID: suiteID) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let notesStore = LocalNotesStore(fileURL: paths.localNotesFileURL)
        let t0 = Date(timeIntervalSince1970: 1_763_300_000)
        try notesStore.appendNote(SnippetNote(id: "n-shared", author: "user", content: "Updated", createdAt: t0.addingTimeInterval(5)), for: "rw-old")
        try notesStore.appendNote(SnippetNote(id: "n-old-only", author: "agent", content: "Offline note", createdAt: t0.addingTimeInterval(1)), for: "rw-old")
        try notesStore.appendNote(SnippetNote(id: "n-shared", author: "user", content: "Stale", createdAt: t0), for: "rw-new")
        try notesStore.appendNote(SnippetNote(id: "n-new-only", author: "agent", content: "Remote cache note", createdAt: t0.addingTimeInterval(10)), for: "rw-new")

        try notesStore.remapCardID(from: "rw-old", to: "rw-new")
        try notesStore.remapCardID(from: "rw-old", to: "rw-new")
        #expect(notesStore.loadNotes(for: "rw-old").isEmpty)
        #expect(notesStore.loadNotes(for: "rw-new").map(\.id) == ["n-old-only", "n-shared", "n-new-only"])
        #expect(notesStore.loadNotes(for: "rw-new").first(where: { $0.id == "n-shared" })?.content == "Updated")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProvenanceMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: config))
        let nowISO = MemosWireFormat.formatISO8601UTC(Date())
        let readyAlpha = "#rewind/ready #source/chatgpt\n\n> **Title:** Alpha Ready\n\nAlpha body"
        let pendingBeta = "#rewind/pending #source/claude\n\nBeta pending body"

        ProvenanceMockURLProtocol.register(suiteID: suiteID) { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET" && path == "/api/memos" {
                let memos = [
                    MemoWireDTO(name: "memos/rw-alpha", content: readyAlpha, createTime: nowISO),
                    MemoWireDTO(name: "memos/rw-beta", content: pendingBeta, createTime: nowISO)
                ]
                return (200, try JSONEncoder().encode(["memos": memos]))
            }
            if req.httpMethod == "POST" && path == "/api/memos" {
                let queryItems = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let memoID = queryItems.first(where: { $0.name == "memoId" })?.value ?? "rw-same"
                let dto = MemoWireDTO(name: "memos/\(memoID)", content: pendingBeta, createTime: nowISO)
                return (200, try JSONEncoder().encode(dto))
            }
            return (200, Data("{\"memos\":[]}".utf8))
        }

        let selection = CapturedSelection(
            text: "Same ID offline-to-online clip",
            bundleIdentifier: "com.apple.Notes",
            appName: "Notes"
        )
        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).provenance.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "qa-filter-token"
            ],
            memosClient: memosClient,
            capturer: FixedSelectionCapturer(selection: selection),
            language: .en
        )

        await coord.refresh()
        #expect(coord.filteredCards.map(\.id) == ["rw-alpha", "rw-beta"])

        coord.toggleCardPreview(id: "rw-beta")
        coord.focusedCardID = "rw-alpha"
        #expect(coord.inspectedCardID == "rw-beta")
        #expect(coord.targetActionCardIDs == ["rw-beta"])

        coord.toggleFocusedCardPreview()
        #expect(coord.inspectedCardID == nil)

        coord.toggleCardPreview(id: "rw-beta")
        #expect(coord.inspectedCard?.id == "rw-beta")

        coord.statusFilter = .ready
        #expect(coord.inspectedCardID == nil)
        #expect(coord.inspectedCard == nil)
        #expect(coord.targetActionCardIDs == ["rw-alpha"])

        coord.statusFilter = .all
        coord.toggleCardPreview(id: "rw-alpha")
        #expect(coord.inspectedCard?.id == "rw-alpha")

        coord.searchText = "Beta pending"
        #expect(coord.inspectedCardID == nil)
        #expect(coord.inspectedCard == nil)
        #expect(coord.targetActionCardIDs == ["rw-beta"])
        coord.searchText = ""

        coord.environment.removeValue(forKey: StoragePaths.memosURLEnvironmentKey)
        let queued = await coord.captureSelection()
        guard case .queuedOffline(let sameClipID) = queued else {
            Issue.record("Expected offline capture")
            return
        }
        coord.checkedCardIDs.removeAll()
        coord.toggleCardPreview(id: sameClipID)
        guard case .loaded(let localPendingDetail) = coord.cardDetailState(for: sameClipID) else {
            Issue.record("Expected local pending detail")
            return
        }
        #expect(!localPendingDetail.isCompleteFromServer)

        coord.environment[StoragePaths.memosURLEnvironmentKey] = "https://\(suiteID).provenance.mock.local"
        _ = await coord.captureSelection()
        for _ in 0..<50 {
            if case .loaded(let d) = coord.cardDetailState(for: sameClipID), d.isCompleteFromServer { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .loaded(let upgradedSameIDDetail) = coord.cardDetailState(for: sameClipID) else {
            Issue.record("Expected inspected card with unchanged ID to upgrade after flush")
            return
        }
        #expect(upgradedSameIDDetail.isCompleteFromServer)
    }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import os
import Testing

private final class LibraryMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func register(suiteID: String, handler: @escaping Handler) {
        handlers.withLock { $0[suiteID] = handler }
    }

    static func unregister(suiteID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".library.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".library.mock.local", with: "")
        guard let handler = Self.handlers.withLock({ $0[suiteID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let bodyData = Self.readBody(from: request)
        do {
            let (statusCode, data) = try handler(request, bodyData)
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

private struct LibraryFixedCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

@Suite("Library Models, Projector, Coordinator & Handoff")
struct LibraryProjectorTests {
    private func makeTestDir() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-library-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeClient() -> MemosClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryMockURLProtocol.self]
        return MemosClient(session: URLSession(configuration: config))
    }

    @Test("Unified deduplication across RewindCard and SnippetRecord preserves status, offline flag, and non-nil inspector across scopes")
    func deduplicationAndScopesPreserveInspector() throws {
        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let placeRef = try #require(PlaceRef(tag: "project/rewind"))
        let place = PlaceRecord(ref: placeRef, title: "Coding Rewind", aliases: ["rewind"])

        let hotOffline = RewindCard(
            id: "clip-hot-offline",
            rawContent: "#rewind/pending #source/chatgpt\n\n> **Title:** Hot Offline\n\n```swift\nfunc sync() {}\n```",
            status: .pending,
            sourcePlatform: "chatgpt",
            title: "Hot Offline",
            sourceTitle: "ChatGPT",
            sourceURL: "https://chatgpt.com/c/chat-1#:~:text=func",
            verbatimText: "```swift\nfunc sync() {}\n```",
            createdAt: now.addingTimeInterval(-3600),
            isOfflinePending: true
        )

        let staleServerCopyOfHot = SnippetRecord(
            id: "clip-hot-offline",
            status: .ready,
            sourcePlatform: "chatgpt",
            title: "Hot Offline",
            sourceTitle: "ChatGPT",
            sourceURL: "https://chatgpt.com/c/chat-1",
            verbatimText: "```swift\nfunc sync() {}\n```",
            createdAt: now.addingTimeInterval(-3600),
            dataOrigin: .remote
        )

        let olderPlaced = SnippetRecord(
            id: "clip-old-placed",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "Older AG Placed",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://ag-sess-99",
            verbatimText: "Prose line one.\nProse line two.",
            createdAt: now.addingTimeInterval(-5 * 86400),
            dataOrigin: .remote,
            tags: ["project/rewind", "architecture"]
        )

        let archivedPlaced = SnippetRecord(
            id: "clip-archived",
            status: .synthesized,
            sourcePlatform: "gemini",
            title: "Archived Gemini",
            sourceTitle: "Gemini",
            sourceURL: "https://gemini.google.com/app/gem-7",
            verbatimText: "Archived insight.",
            createdAt: now.addingTimeInterval(-10 * 86400),
            dataOrigin: .remote,
            tags: ["project/rewind"]
        )

        let scopes: [LibraryScope] = [
            .all,
            .unplacedInbox,
            .hot72Hours,
            .source(.chatGPTApp),
            .place(placeRef),
            .archived
        ]

        for scope in scopes {
            let projection = LibraryProjector.project(
                hotCards: [hotOffline],
                libraryRecords: [staleServerCopyOfHot, olderPlaced, archivedPlaced],
                placeRecords: [olderPlaced, archivedPlaced],
                activePlaces: [place],
                scope: scope,
                now: now
            )
            #expect(projection.inspectedItem != nil, "Inspector must be non-nil for scope \(scope)")
            #expect(projection.scopeCounts[.all] == 2)
            #expect(projection.scopeCounts[.unplacedInbox] == 1)
            #expect(projection.scopeCounts[.hot72Hours] == 1)
            #expect(projection.scopeCounts[.archived] == 1)
            #expect(projection.scopeCounts[.source(.chatGPTApp)] == 1)
            #expect(projection.scopeCounts[.source(.antigravity)] == 1)
            #expect(projection.scopeCounts[.source(.geminiWeb)] == 0)
            #expect(projection.scopeCounts[.place(placeRef)] == 2)
        }

        let allProj = LibraryProjector.project(
            hotCards: [hotOffline],
            libraryRecords: [staleServerCopyOfHot, olderPlaced, archivedPlaced],
            activePlaces: [place],
            scope: .all,
            now: now
        )
        let first = try #require(allProj.visibleItems.first)
        #expect(first.id == "clip-hot-offline")
        #expect(first.isQueuedOffline == true)
        #expect(first.isCodeDominant == true)
        #expect(first.codePreviewLines == "func sync() {}")

        let placeProj = LibraryProjector.project(
            hotCards: [hotOffline],
            libraryRecords: [staleServerCopyOfHot, olderPlaced, archivedPlaced],
            activePlaces: [place],
            scope: .place(placeRef),
            now: now
        )
        #expect(placeProj.visibleItems.map(\.id) == ["clip-old-placed", "clip-archived"])
        #expect(placeProj.visibleItems.last?.status == .synthesized)
    }

    @Test("Structured search filters and 4-slot SearchHitSlot attribution")
    func structuredSearchAndHitSlots() throws {
        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let rewindRef = try #require(PlaceRef(tag: "project/rewind"))
        let rewindPlace = PlaceRecord(ref: rewindRef, title: "Coding Rewind", aliases: ["rewind"])

        let metaClip = SnippetRecord(
            id: "c-meta",
            status: .ready,
            sourcePlatform: "chatgpt",
            title: "Meta Title Needle",
            keywords: ["alpha"],
            sourceTitle: "ChatGPT",
            verbatimText: "Plain body without term",
            createdAt: now.addingTimeInterval(-100),
            dataOrigin: .remote
        )

        let bodyClip = SnippetRecord(
            id: "c-body",
            status: .ready,
            sourcePlatform: "chatgpt",
            title: "Generic Title",
            sourceTitle: "ChatGPT",
            verbatimText: "Line 1\nBodyTermSpecial appears here",
            createdAt: now.addingTimeInterval(-200),
            dataOrigin: .remote,
            tags: ["project/rewind"]
        )

        let contextClip = SnippetRecord(
            id: "c-ctx",
            status: .ready,
            sourcePlatform: "gemini",
            title: "Context Carrier",
            sourceTitle: "Gemini",
            verbatimText: "Unrelated markdown",
            createdAt: now.addingTimeInterval(-300),
            dataOrigin: .remote
        )

        let noteClip = SnippetRecord(
            id: "c-note",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "Note Carrier",
            sourceTitle: "Antigravity",
            verbatimText: "Another unrelated markdown",
            createdAt: now.addingTimeInterval(-400),
            dataOrigin: .remote
        )

        let details: [String: CardDetail] = [
            "c-ctx": CardDetail(
                context: CaptureContext(
                    sessionTitle: "Gemini Session",
                    sessionID: "g-1",
                    lead: .sessionOpening("OpeningSecretPhrase"),
                    prompt: "PromptQuestionUnique"
                ),
                notes: [],
                isCompleteFromServer: true
            ),
            "c-note": CardDetail(
                context: nil,
                notes: [
                    SnippetNote(
                        id: "n-1",
                        author: "agent",
                        content: "AgentConclusionToken",
                        createdAt: now
                    )
                ],
                isCompleteFromServer: true
            )
        ]

        let records = [metaClip, bodyClip, contextClip, noteClip]

        let chatGPTUnplaced = LibraryProjector.project(
            hotCards: [],
            libraryRecords: records,
            activePlaces: [rewindPlace],
            cachedDetails: details,
            searchText: "source:chatgpt is:unplaced",
            now: now
        )
        #expect(chatGPTUnplaced.visibleItems.map(\.id) == ["c-meta"])
        #expect(chatGPTUnplaced.visibleItems.first?.hitSlot == nil)

        let placedRewind = LibraryProjector.project(
            hotCards: [],
            libraryRecords: records,
            activePlaces: [rewindPlace],
            cachedDetails: details,
            searchText: "place:project/rewind BodyTermSpecial",
            now: now
        )
        #expect(placedRewind.visibleItems.map(\.id) == ["c-body"])
        #expect(placedRewind.visibleItems.first?.hitSlot == .verbatimBody)

        let metaHit = LibraryProjector.project(
            hotCards: [],
            libraryRecords: records,
            activePlaces: [rewindPlace],
            cachedDetails: details,
            searchText: "Meta Title",
            now: now
        )
        #expect(metaHit.visibleItems.first?.hitSlot == .metadata)

        let ctxHit = LibraryProjector.project(
            hotCards: [],
            libraryRecords: records,
            activePlaces: [rewindPlace],
            cachedDetails: details,
            searchText: "PromptQuestionUnique",
            now: now
        )
        #expect(ctxHit.visibleItems.map(\.id) == ["c-ctx"])
        #expect(ctxHit.visibleItems.first?.hitSlot == .promptContext)

        let noteHit = LibraryProjector.project(
            hotCards: [],
            libraryRecords: records,
            activePlaces: [rewindPlace],
            cachedDetails: details,
            searchText: "AgentConclusionToken",
            now: now
        )
        #expect(noteHit.visibleItems.map(\.id) == ["c-note"])
        #expect(noteHit.visibleItems.first?.hitSlot == .agentNote)
    }

    @Test("Session bundles group by sessionID, conversation://, and chatgpt.com/c/<uuid> with chronological clips")
    func sessionBundlesGroupingAndOrdering() throws {
        let base = Date(timeIntervalSince1970: 1_763_800_000)

        let chat1 = SnippetRecord(
            id: "chat-1",
            status: .ready,
            sourcePlatform: "chatgpt",
            title: "First chat clip",
            sourceTitle: "ChatGPT",
            sourceURL: "https://chatgpt.com/c/abc-uuid#:~:text=first",
            verbatimText: "First message",
            createdAt: base.addingTimeInterval(-600),
            dataOrigin: .remote
        )
        let chat2 = SnippetRecord(
            id: "chat-2",
            status: .ready,
            sourcePlatform: "chatgpt",
            title: "Second chat clip",
            sourceTitle: "ChatGPT",
            sourceURL: "https://chatgpt.com/c/abc-uuid#:~:text=second",
            verbatimText: "Second message",
            createdAt: base.addingTimeInterval(-100),
            dataOrigin: .remote
        )

        let ag1 = SnippetRecord(
            id: "ag-1",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "AG older",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://ag-42",
            verbatimText: "AG first",
            createdAt: base.addingTimeInterval(-900),
            dataOrigin: .remote
        )
        let ag2 = SnippetRecord(
            id: "ag-2",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "AG newer",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://ag-42",
            verbatimText: "AG second",
            createdAt: base.addingTimeInterval(-300),
            dataOrigin: .remote
        )

        let ctxClip = SnippetRecord(
            id: "ctx-1",
            status: .ready,
            sourcePlatform: "gemini",
            title: "Gemini Session Clip",
            sourceTitle: "Gemini",
            verbatimText: "Gemini body",
            createdAt: base.addingTimeInterval(-200),
            dataOrigin: .remote
        )
        let details: [String: CardDetail] = [
            "ctx-1": CardDetail(
                context: CaptureContext(
                    sessionTitle: "Gemini Deep Dive",
                    sessionID: "gem-sid-9",
                    lead: .sessionOpening("How does Swift 6 Sendable work?"),
                    prompt: "Explain @MainActor"
                ),
                notes: [],
                isCompleteFromServer: true
            )
        ]

        let projection = LibraryProjector.project(
            hotCards: [],
            libraryRecords: [chat1, chat2, ag1, ag2, ctxClip],
            activePlaces: [],
            cachedDetails: details,
            now: base
        )

        #expect(projection.sessionBundles.count == 3)
        #expect(projection.sessionBundles.map(\.key.rawValue) == [
            "web:chatgpt.com/c/abc-uuid",
            "sid:gem-sid-9",
            "ag:ag-42"
        ])
        #expect(projection.sessionBundles[0].clips.map(\.id) == ["chat-1", "chat-2"])
        #expect(projection.sessionBundles[1].sessionOpening == "How does Swift 6 Sendable work?")
        #expect(projection.sessionBundles[2].clips.map(\.id) == ["ag-1", "ag-2"])
        #expect(projection.sessionBundles.allSatisfy { !$0.key.isSyntheticFallback })
    }

    @Test("Closed-vocabulary place suggestions, triage intent advancing focus, and relatedPlaceItems")
    @MainActor
    func closedVocabularySuggestionsAndTriageIntent() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { LibraryMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let paperRef = try #require(PlaceRef(tag: "project/paper-02"))
        let swiftRef = try #require(PlaceRef(tag: "topic/swift"))
        let archivedRef = try #require(PlaceRef(tag: "topic/old"))

        let paperPlace = PlaceRecord(ref: paperRef, title: "Paper 02", aliases: ["论文02", "embodiment"])
        let swiftPlace = PlaceRecord(ref: swiftRef, title: "Swift Concurrency", aliases: ["actor"])
        let archivedPlace = PlaceRecord(ref: archivedRef, title: "Archived Topic", aliases: ["actor"], archived: true)

        let rawPlacedSibling = "#rewind/ready #source/chatgpt #project/paper-02\n\n> **Title:** Placed Sibling\n> **Source:** [Chat](https://chatgpt.com/c/sess-shared) · \(nowISO)\n\nSibling context."
        let rawTarget1 = "#rewind/ready #source/chatgpt\n\n> **Title:** Target 1\n> **Source:** [Chat](https://chatgpt.com/c/sess-shared) · \(nowISO)\n\nNeeds placement from session."
        let rawTarget2 = "#rewind/ready #source/antigravity\n\n> **Title:** Target 2\n> **Keywords:** actor\n> **Source:** [AG](conversation://ag-2) · \(nowISO)\n\nDiscuss #topic/nonexistent and Swift actor isolation."

        final class MockServer: @unchecked Sendable {
            private let lock = NSLock()
            var memos: [String: MemoWireDTO]

            init(memos: [String: MemoWireDTO]) {
                self.memos = memos
            }

            func handle(_ req: URLRequest, _ body: Data, _ iso: String) -> (Int, Data) {
                lock.lock()
                defer { lock.unlock() }
                let path = req.url?.path ?? ""
                let method = req.httpMethod ?? "GET"
                let enc = JSONEncoder()
                enc.outputFormatting = [.withoutEscapingSlashes]
                if method == "GET" && path == "/api/memos" {
                    let list = Array(memos.values)
                    return (200, (try? enc.encode(["memos": list])) ?? Data())
                }
                if path.hasPrefix("/api/memos/") && !path.hasSuffix("/comments") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    if method == "GET", let dto = memos[mid] {
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                    if method == "PATCH", let existing = memos[mid],
                       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let content = obj["content"] as? String {
                        let updated = MemoWireDTO(name: existing.name, content: content, createTime: existing.createTime)
                        memos[mid] = updated
                        return (200, (try? enc.encode(updated)) ?? Data())
                    }
                }
                if method == "GET" && path.hasSuffix("/comments") {
                    return (200, Data("{\"memos\":[]}".utf8))
                }
                return (404, Data())
            }
        }

        let server = MockServer(memos: [
            "pl-p-paper-02": MemoWireDTO(name: "memos/pl-p-paper-02", content: MemosWireFormat.formatPlaceMemo(paperPlace), createTime: nowISO),
            "pl-t-swift": MemoWireDTO(name: "memos/pl-t-swift", content: MemosWireFormat.formatPlaceMemo(swiftPlace), createTime: nowISO),
            "pl-t-old": MemoWireDTO(name: "memos/pl-t-old", content: MemosWireFormat.formatPlaceMemo(archivedPlace), createTime: nowISO),
            "clip-placed": MemoWireDTO(name: "memos/clip-placed", content: rawPlacedSibling, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-300))),
            "clip-t1": MemoWireDTO(name: "memos/clip-t1", content: rawTarget1, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-60))),
            "clip-t2": MemoWireDTO(name: "memos/clip-t2", content: rawTarget2, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-120)))
        ])
        LibraryMockURLProtocol.register(suiteID: suiteID) { req, body in
            server.handle(req, body, nowISO)
        }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).library.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "qa-lib-token"
            ],
            memosClient: makeClient(),
            capturer: LibraryFixedCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "com.apple.Notes", appName: "Notes")),
            language: .en
        )

        await coord.refreshLibraryWorkspace()
        await coord.handleLibraryIntent(.selectScope(.unplacedInbox))

        let inboxBefore = coord.libraryProjection
        #expect(inboxBefore.visibleItems.map(\.id) == ["clip-t1", "clip-t2"])
        #expect(inboxBefore.triageProgress == TriageProgressSnapshot(remainingUnplacedCount: 2, triagedInSessionCount: 0))

        let t1 = try #require(inboxBefore.visibleItems.first(where: { $0.id == "clip-t1" }))
        #expect(t1.suggestedPlaces == [SuggestedPlaceCandidate(place: paperPlace, reason: .sameSessionInherited)])
        #expect(inboxBefore.relatedPlaceItems.map(\.id) == ["clip-placed"])

        let t2 = try #require(inboxBefore.visibleItems.first(where: { $0.id == "clip-t2" }))
        #expect(t2.suggestedPlaces == [SuggestedPlaceCandidate(place: swiftPlace, reason: .keywordAlias)])
        #expect(!t2.suggestedPlaces.contains(where: { $0.place.ref == archivedRef }))

        await coord.handleLibraryIntent(.acceptSuggestedPlaces(clipID: "clip-t1", refs: [paperRef], advanceFocus: true))

        let inboxAfter = coord.libraryProjection
        #expect(inboxAfter.visibleItems.map(\.id) == ["clip-t2"])
        #expect(coord.libraryFocusedClipID == "clip-t2")
        #expect(inboxAfter.inspectedItem?.id == "clip-t2")
        #expect(inboxAfter.triageProgress == TriageProgressSnapshot(remainingUnplacedCount: 1, triagedInSessionCount: 1))
    }

    @Test("Staging >72h SnippetRecord via stageAndOpenHandoff, detail loading, note append, archive/unarchive, and delete")
    @MainActor
    func olderSnippetHandoffNotesAndMutations() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { LibraryMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date()
        let oldDate = now.addingTimeInterval(-10 * 86400)
        let oldISO = MemosWireFormat.formatISO8601UTC(oldDate)
        let nowISO = MemosWireFormat.formatISO8601UTC(now)

        let rawOld = "#rewind/ready #source/chatgpt #project/paper-02\n\n> **Title:** Old Important Excerpt\n> **Source:** [Chat](https://chatgpt.com/c/old-chat) · \(oldISO)\n\nExact >72h verbatim quote line."
        let ctxComment = CaptureContext(
            sessionTitle: "Old Session",
            sessionID: "old-chat",
            lead: .sessionOpening("Old opening question"),
            prompt: "Follow up prompt"
        ).formattedCommentMarkdown()

        final class MockServer: @unchecked Sendable {
            private let lock = NSLock()
            var memos: [String: MemoWireDTO]
            var comments: [String: [MemoWireDTO]]

            init(memos: [String: MemoWireDTO], comments: [String: [MemoWireDTO]]) {
                self.memos = memos
                self.comments = comments
            }

            func handle(_ req: URLRequest, _ body: Data, _ iso: String) -> (Int, Data) {
                lock.lock()
                defer { lock.unlock() }
                let path = req.url?.path ?? ""
                let method = req.httpMethod ?? "GET"
                let comps = req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                let enc = JSONEncoder()
                enc.outputFormatting = [.withoutEscapingSlashes]
                if method == "GET" && path == "/api/memos" {
                    return (200, (try? enc.encode(["memos": Array(memos.values)])) ?? Data())
                }
                if path.hasPrefix("/api/memos/") && path.hasSuffix("/comments") {
                    let mid = path.replacingOccurrences(of: "/api/memos/", with: "").replacingOccurrences(of: "/comments", with: "")
                    if method == "POST" {
                        let cid = comps?.queryItems?.first(where: { $0.name == "commentId" })?.value ?? "rw-note-1"
                        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                        let dto = MemoWireDTO(name: "memos/\(cid)", content: obj["content"] as? String ?? "", createTime: iso)
                        comments[mid, default: []].append(dto)
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                    return (200, (try? enc.encode(["memos": comments[mid] ?? []])) ?? Data())
                }
                if path.hasPrefix("/api/memos/") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    if method == "GET", let dto = memos[mid] {
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                    if method == "PATCH", let existing = memos[mid],
                       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let content = obj["content"] as? String {
                        let updated = MemoWireDTO(name: existing.name, content: content, createTime: existing.createTime)
                        memos[mid] = updated
                        return (200, (try? enc.encode(updated)) ?? Data())
                    }
                    if method == "DELETE" {
                        let existed = memos.removeValue(forKey: mid) != nil
                        return (existed ? 200 : 404, Data("{}".utf8))
                    }
                }
                return (404, Data())
            }
        }

        let server = MockServer(
            memos: ["clip-old-1": MemoWireDTO(name: "memos/clip-old-1", content: rawOld, createTime: oldISO)],
            comments: ["clip-old-1": [MemoWireDTO(name: "memos/clip-old-1-ctx", content: ctxComment, createTime: oldISO)]]
        )
        LibraryMockURLProtocol.register(suiteID: suiteID) { req, body in
            server.handle(req, body, nowISO)
        }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).library.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "qa-old-token"
            ],
            memosClient: makeClient(),
            capturer: LibraryFixedCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "com.apple.Notes", appName: "Notes")),
            language: .en
        )

        await coord.refreshLibraryWorkspace()
        #expect(coord.cards.isEmpty)
        #expect(coord.libraryProjection.visibleItems.map(\.id) == ["clip-old-1"])

        for _ in 0..<50 {
            if case .loaded(let d) = coord.libraryProjection.inspectedDetailState, d.isCompleteFromServer { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .loaded(let loadedDetail) = coord.libraryProjection.inspectedDetailState else {
            Issue.record("Expected loaded detail for >72h library clip")
            return
        }
        #expect(loadedDetail.context?.sessionOpening == "Old opening question")

        await coord.handleLibraryIntent(.appendNote(clipID: "clip-old-1", text: "Synthesis note for >72h clip"))
        guard case .loaded(let notedDetail) = coord.libraryProjection.inspectedDetailState else {
            Issue.record("Expected loaded detail after note append")
            return
        }
        #expect(notedDetail.notes.map(\.content) == ["Synthesis note for >72h clip"])
        #expect(notedDetail.context?.sessionOpening == "Old opening question")

        await coord.handleLibraryIntent(.stageAndOpenHandoff(clipIDs: ["clip-old-1"]))
        let draft = try #require(coord.conversationDraft)
        #expect(draft.cardIDs == ["clip-old-1"])
        #expect(draft.text.contains("Exact >72h verbatim quote line."))
        #expect(draft.text.contains("clip-old-1"))
        coord.dismissConversationDraft()

        await coord.handleLibraryIntent(.archiveClips(["clip-old-1"]))
        #expect(coord.libraryProjection.visibleItems.isEmpty)
        await coord.handleLibraryIntent(.selectScope(.archived))
        #expect(coord.libraryProjection.visibleItems.map(\.id) == ["clip-old-1"])

        await coord.handleLibraryIntent(.unarchiveClips(["clip-old-1"]))
        #expect(coord.libraryProjection.visibleItems.isEmpty)
        await coord.handleLibraryIntent(.selectScope(.all))
        #expect(coord.libraryProjection.visibleItems.map(\.id) == ["clip-old-1"])

        await coord.handleLibraryIntent(.requestDelete(["clip-old-1"], immediate: false))
        #expect(coord.pendingDeleteConfirmation?.cardIDs == ["clip-old-1"])
        await coord.confirmPendingDelete()
        #expect(coord.pendingDeleteConfirmation == nil)
        #expect(coord.libraryProjection.visibleItems.isEmpty)
    }
}

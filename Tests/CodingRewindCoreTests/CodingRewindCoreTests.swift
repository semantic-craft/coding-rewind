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

    func release(_ index: Int, status: Int, data: Data = Data()) {
        responses[index]?.resume(returning: (status, data))
        responses[index] = nil
    }
}

private struct StubCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

private actor GatedCapturer: SelectionCapturing {
    private(set) var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func captureFrontmostSelection() async throws -> CapturedSelection {
        calls += 1
        if calls == 1 {
            started?.resume()
            started = nil
            await withCheckedContinuation { release = $0 }
        }
        return CapturedSelection(text: "Only one clip", bundleIdentifier: "test.capture", appName: "Fixture")
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() { release?.resume(); release = nil }
}

@Suite("CodingRewindCore Memos Wire, Outbox & Plugin Suite")
struct CodingRewindCoreTests {
    @Test("Environment-managed connection fields never overwrite local settings")
    @MainActor
    func managedConnectionSettingsDoNotWrite() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        try paths.saveMemosURLString("https://saved.example.com")
        let before = try Data(contentsOf: paths.configFileURL)
        let environment = [StoragePaths.memosURLEnvironmentKey: "https://managed.example.com", StoragePaths.memosTokenEnvironmentKey: "fixture", StoragePaths.qaEnvironmentKey: "1"]
        let coordinator = try AppCoordinator(paths: paths, environment: environment, capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        #expect(coordinator.connectionSettings.isURLManaged)
        #expect(coordinator.connectionSettings.isTokenManaged)
        #expect(coordinator.connectionSettings.memosURL == "https://managed.example.com")
        try coordinator.saveCredentials(memosURL: "https://ignored.example.com", token: "")
        #expect(try Data(contentsOf: paths.configFileURL) == before)
    }

    @Test("Editable connection saves and invalid input preserves the prior address")
    @MainActor
    func editableConnectionSettingsPersist() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let environment = [StoragePaths.qaEnvironmentKey: "1"]
        let coordinator = try AppCoordinator(paths: paths, environment: environment, capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        #expect(!coordinator.connectionSettings.isURLManaged)
        #expect(!coordinator.connectionSettings.isTokenManaged)
        try coordinator.saveCredentials(memosURL: "https://saved.example.com", token: "")
        let reopened = try AppCoordinator(paths: paths, environment: environment, capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        #expect(reopened.connectionSettings.memosURL == "https://saved.example.com")
        #expect(throws: (any Error).self) { try reopened.saveCredentials(memosURL: "invalid", token: "") }
        #expect(reopened.connectionSettings.memosURL == "https://saved.example.com")
        #expect(reopened.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: false).headerSubtitle.contains("已配置"))
    }

    private func makeIsolatedDir() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/test-data", isDirectory: true)
            .appendingPathComponent("coding-rewind-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Overlapping capture requests create one offline clip")
    @MainActor
    func captureReentrancy() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let capturer = GatedCapturer()
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: capturer)
        let first = Task { await coordinator.captureSelection() }
        await capturer.waitUntilStarted()
        await coordinator.captureSelection()
        await capturer.finish()
        await first.value
        #expect(await capturer.calls == 1)
        #expect(coordinator.outbox.loadEntries().count == 1)
        #expect(!coordinator.isCapturingSelection)
    }

    @Test("A refresh preserves a clip captured while its remote list is in flight", arguments: [false, true], [false, true])
    @MainActor
    func refreshPreservesConcurrentCapture(captureSucceeds: Bool, refreshFails: Bool) async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let gate = MemosResponseGate()
        let createdAt = MemosWireFormat.formatISO8601UTC(Date())
        MockMemosURLProtocol.register(suiteID: suiteID) { request, body in
            if request.httpMethod == "GET" { return await gate.response() }
            guard captureSucceeds,
                  let content = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["content"] as? String,
                  let url = request.url,
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "memoId" })?.value else {
                return (-1, Data())
            }
            let memo = ["name": "memos/\(id)", "content": content, "createTime": createdAt]
            return (201, (try? JSONSerialization.data(withJSONObject: memo)) ?? Data())
        }
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local",
                StoragePaths.memosTokenEnvironmentKey: "fixture-token",
                StoragePaths.qaEnvironmentKey: "1"
            ],
            memosClient: MemosClient(session: makeMockSession()),
            capturer: StubCapturer(selection: CapturedSelection(text: "Captured after refresh began", bundleIdentifier: "fixture", appName: "Fixture"))
        )

        let refresh = Task { await coordinator.refresh() }
        await gate.waitForRequests(1)
        await coordinator.captureSelection()
        let capturedCard = try #require(coordinator.cards.first)
        #expect(capturedCard.isOfflinePending == !captureSucceeds)
        #expect(coordinator.hotCache.loadCards().contains { $0.id == capturedCard.id })

        let captureBanner = coordinator.bannerMessage
        await gate.release(0, status: refreshFails ? 500 : 200, data: Data("{\"memos\":[]}".utf8))
        await refresh.value
        #expect(coordinator.bannerMessage == captureBanner)

        #expect(coordinator.outbox.loadEntries().contains { $0.clientClipId == capturedCard.id } == !captureSucceeds)
        #expect(coordinator.cards.contains { $0.id == capturedCard.id })
        #expect(coordinator.hotCache.loadCards().contains { $0.id == capturedCard.id })
    }

    @Test
    func hotClipsIncludeLaterPages() async throws {
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let time = MemosWireFormat.formatISO8601UTC(Date())
        let firstPage = try JSONSerialization.data(withJSONObject: [
            "memos": (0..<100).map { ["name": "memos/plain-\($0)", "content": "ordinary memo", "createTime": time] },
            "nextPageToken": "page-two"
        ])
        let secondPage = try JSONSerialization.data(withJSONObject: [
            "memos": [["name": "memos/rewind-on-second-page", "content": "#rewind/ready #source/macos\n\nRecent highlight", "createTime": time]]
        ])
        MockMemosURLProtocol.register(suiteID: suiteID) { request, _ in
            let token = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "pageToken" }?.value
            return (200, token == "page-two" ? secondPage : firstPage)
        }
        let cards = try await MemosClient(session: makeMockSession()).listHotClips(baseURL: URL(string: "https://\(suiteID).mock.memos.local")!, token: "fixture-token")
        let requests = MockMemosURLProtocol.recordedRequests(suiteID: suiteID)
        #expect(cards.map(\.id) == ["rewind-on-second-page"])
        #expect(cards.first?.verbatimText == "Recent highlight")
        #expect(requests.count == 2)
    }

    @Test("An unconfigured refresh retains the current cards when the cache has changed")
    @MainActor
    func unconfiguredRefreshPreservesCurrentCards() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let card = try #require(MemosWireFormat.parseMemo(id: "current", rawContent: "#rewind/ready #source/macos\n\nCurrent card", createdAt: Date()))
        let cache = HotCache(fileURL: paths.hotCacheFileURL)
        try cache.saveCards([card])
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        try cache.saveCards([])
        await coordinator.refresh()
        #expect(coordinator.cards.map(\.id) == [card.id])
    }

    @Test("Only the latest started refresh publishes cards, cache and errors", arguments: [false, true], [false, true])
    @MainActor
    func latestRefreshOwnsPublication(olderFails: Bool, latestFails: Bool) async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let gate = MemosResponseGate()
        MockMemosURLProtocol.register(suiteID: suiteID) { _, _ in await gate.response() }
        let now = Date()
        let initial = try #require(MemosWireFormat.parseMemo(id: "initial", rawContent: "#rewind/ready #source/macos\n\nInitial card", createdAt: now))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([initial])
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local", StoragePaths.memosTokenEnvironmentKey: "fixture-token", StoragePaths.qaEnvironmentKey: "1"], memosClient: MemosClient(session: makeMockSession()), capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        try coordinator.hotCache.saveCards([])
        func response(_ id: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["memos": [["name": "memos/\(id)", "content": "#rewind/ready #source/macos\n\n\(id)", "createTime": MemosWireFormat.formatISO8601UTC(now)]]])
        }
        let older = Task { await coordinator.refresh() }
        await gate.waitForRequests(1)
        let latest = Task { await coordinator.refresh() }
        await gate.waitForRequests(2)
        await gate.release(1, status: latestFails ? 500 : 200, data: try response("latest"))
        await latest.value
        let latestCards = coordinator.cards
        let latestCache = coordinator.hotCache.loadCards()
        let latestBanner = coordinator.bannerMessage
        #expect(latestCards.map(\.id) == [latestFails ? "initial" : "latest"])
        #expect(coordinator.isErrorBanner == latestFails)
        await gate.release(0, status: olderFails ? 500 : 200, data: try response("older"))
        await older.value
        #expect(coordinator.cards == latestCards)
        #expect(coordinator.hotCache.loadCards() == latestCache)
        #expect(coordinator.bannerMessage == latestBanner)
        #expect(coordinator.isErrorBanner == latestFails)
    }

    @Test("A refresh started during capture cannot remove its provisional card")
    @MainActor
    func refreshStartedDuringCapturePreservesCard() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let gate = MemosResponseGate()
        MockMemosURLProtocol.register(suiteID: suiteID) { request, _ in
            if request.httpMethod == "POST" { return await gate.response() }
            return (200, Data("{\"memos\":[]}".utf8))
        }
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local", StoragePaths.memosTokenEnvironmentKey: "fixture-token", StoragePaths.qaEnvironmentKey: "1"], memosClient: MemosClient(session: makeMockSession()), capturer: StubCapturer(selection: CapturedSelection(text: "Capture in progress", bundleIdentifier: "fixture", appName: "Fixture")))
        let capture = Task { await coordinator.captureSelection() }
        await gate.waitForRequests(1)
        let captured = try #require(coordinator.cards.first)
        await coordinator.refresh()
        #expect(coordinator.cards == [captured])
        await gate.release(0, status: 500)
        await capture.value
        #expect(coordinator.cards == [captured])
        #expect(coordinator.hotCache.loadCards().map(\.id) == [captured.id])
        #expect(coordinator.outbox.loadEntries().map(\.clientClipId) == [captured.id])
    }

    @Test("Refresh commits the current outbox into both cards and cache")
    @MainActor
    func refreshReadsCurrentOutboxAtCommit() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let gate = MemosResponseGate()
        MockMemosURLProtocol.register(suiteID: suiteID) { _, _ in await gate.response() }
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local", StoragePaths.memosTokenEnvironmentKey: "fixture-token", StoragePaths.qaEnvironmentKey: "1"], memosClient: MemosClient(session: makeMockSession()), capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        let refresh = Task { await coordinator.refresh() }
        await gate.waitForRequests(1)
        try coordinator.outbox.enqueue(OutboxEntry(clientClipId: "new-outbox", memoContent: "#rewind/pending #source/macos\n\nQueued during refresh", commentContent: nil))
        await gate.release(0, status: 200, data: Data("{\"memos\":[]}".utf8))
        await refresh.value
        #expect(coordinator.cards.map(\.id) == ["new-outbox"])
        #expect(coordinator.hotCache.loadCards() == coordinator.cards)
    }

    @Test("Failure on a later memo page rejects the whole remote list")
    func hotClipsRejectIncompletePagination() async throws {
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        let firstPage = try JSONSerialization.data(withJSONObject: ["memos": [["name": "memos/first", "content": "#rewind/ready #source/macos\n\nFirst page", "createTime": MemosWireFormat.formatISO8601UTC(Date())]], "nextPageToken": "page + /?two"])
        MockMemosURLProtocol.register(suiteID: suiteID) { request, _ in
            let token = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "pageToken" }?.value
            return token == nil ? (200, firstPage) : (503, Data())
        }
        await #expect(throws: RewindError.self) {
            try await MemosClient(session: makeMockSession()).listHotClips(baseURL: URL(string: "https://\(suiteID).mock.memos.local")!, token: "fixture-token")
        }
        let requests = MockMemosURLProtocol.recordedRequests(suiteID: suiteID)
        #expect(requests.count == 2)
        #expect(URLComponents(url: requests.last!.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value == "page + /?two")
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
        #expect(paths.dataDirectoryURL.path == dataDir.standardizedFileURL.path)

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

    @Test("An Antigravity selection without verified ownership never borrows another conversation")
    @MainActor
    func unverifiedAntigravitySelectionDoesNotBorrowContext() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let selection = CapturedSelection(
            text: "Reply from conversation A",
            bundleIdentifier: CapturedSelection.antigravityBundleIdentifier,
            appName: "Antigravity",
            documentURL: "http://127.0.0.1:49807/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: StubCapturer(selection: selection))
        try AtomicFile.writeUTF8(
            """
            {"conversationId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","lastUserInput":"Question from conversation B","observedAt":"\(Date().ISO8601Format())","recentTurns":[]}
            """,
            to: dir.appendingPathComponent("active_turn.json")
        )

        await coordinator.captureSelection()

        let entry = try #require(coordinator.outbox.loadEntries().first)
        #expect(entry.commentContent == nil)
        let card = try #require(coordinator.cards.first)
        #expect(card.sourceURL == nil)
        #expect(card.verbatimText == selection.text)
    }

    @Test("The context comment preserves all messages in four user-led rounds")
    func contextCommentPreservesFourRounds() {
        let messages = (1...4).flatMap { round in
            [
                ConversationTurn(role: "User", text: "Question \(round)"),
                ConversationTurn(role: "Assistant", text: "Answer \(round)"),
                ConversationTurn(role: "Assistant", text: "Follow-up \(round)")
            ]
        }
        let comment = CaptureContext(sessionTitle: "Antigravity", prompt: "Question 4", recentTurns: messages)
            .formattedCommentMarkdown()
        let expected = messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        #expect(comment.hasSuffix(expected))
    }

    @Test("Verified Antigravity capture anchors to the selected message and keeps four user-led rounds")
    @MainActor
    func verifiedAntigravityCaptureUsesSelectedConversation() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let url = try #require(URL(string: "http://127.0.0.1:49807/c/\(id)?project=fixture"))
        let conversation = try #require(AntigravityConversationID(webAreaURL: url))
        let otherID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let selectionText = "selected code:\r\n  return value"
        let longAnswer = String(repeating: "x", count: 810) + "\nselected code:\n  return value"
        let messages: [(String, String)] = [
            ("USER_INPUT", "Question 1"),
            ("PLANNER_RESPONSE", "Answer 1"),
            ("USER_INPUT", "Question 2"),
            ("PLANNER_RESPONSE", "Answer 2"),
            ("USER_INPUT", "Question 3"),
            ("PLANNER_RESPONSE", "Answer 3a"),
            ("MODEL_OUTPUT", "Answer 3b"),
            ("USER_INPUT", "Question 4"),
            ("PLANNER_RESPONSE", "Answer 4"),
            ("USER_INPUT", "Question 5"),
            ("PLANNER_RESPONSE", "Answer 5a"),
            ("PLANNER_RESPONSE", longAnswer),
            ("PLANNER_RESPONSE", "Later answer block"),
            ("USER_INPUT", "Later question")
        ]
        let toolOnly: [String: Any] = ["type": "PLANNER_RESPONSE", "tool_calls": [["name": "tool"]]]
        let systemInput: [String: Any] = ["type": "USER_INPUT", "source": "SYSTEM", "content": "System text"]
        let records = messages.map { type, text in
            ["type": type, "source": type == "USER_INPUT" ? "USER_EXPLICIT" : "MODEL", "content": text]
        } + [toolOnly, systemInput]
        try writeTranscript(records, conversationID: id, home: dir)
        try writeTranscript([
            ["type": "USER_INPUT", "content": "Question from conversation B"],
            ["type": "PLANNER_RESPONSE", "content": selectionText]
        ], conversationID: otherID, home: dir)

        let selection = CapturedSelection(
            text: selectionText, bundleIdentifier: CapturedSelection.antigravityBundleIdentifier,
            appName: "Antigravity", windowTitle: "Conversation A", antigravityConversationID: conversation
        )
        let coordinator = try AppCoordinator(
            paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: StubCapturer(selection: selection), antigravityContext: AntigravityCaptureContext(homeDirectory: dir)
        )
        await coordinator.captureSelection()

        let entry = try #require(coordinator.outbox.loadEntries().first)
        let comment = try #require(entry.commentContent)
        #expect(entry.memoContent.hasSuffix(selectionText))
        #expect(entry.memoContent.contains("#rewind/has-ctx"))
        #expect(coordinator.cards.first?.sourceURL == "conversation://\(id)")
        #expect(comment == """
        <!-- rewind-context-v1 -->
        Session Title: Conversation A
        Prompt: Question 5

        ### Recent Turns
        User: Question 2
        Assistant: Answer 2
        User: Question 3
        Assistant: Answer 3a
        Assistant: Answer 3b
        User: Question 4
        Assistant: Answer 4
        User: Question 5
        Assistant: Answer 5a
        Assistant: \(String(repeating: "x", count: 800))…
        """)
    }

    @Test("User selection has no prompt and repeated or unmatched text has no context")
    func nativeCaptureAnchorBoundaries() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let url = try #require(URL(string: "http://127.0.0.1:49807/c/\(id)"))
        let conversation = try #require(AntigravityConversationID(webAreaURL: url))
        try writeTranscript([
            ["type": "USER_INPUT", "content": "First question"],
            ["type": "PLANNER_RESPONSE", "content": "Repeated answer"],
            ["type": "USER_INPUT", "content": "Selected question"],
            ["type": "PLANNER_RESPONSE", "content": "Repeated answer"],
            ["type": "PLANNER_RESPONSE", "content": "One  two", "truncated_fields": ["content"]]
        ], conversationID: id, home: dir)
        let resolver = AntigravityCaptureContext(homeDirectory: dir)
        let selectedUser = try #require(await resolver.resolve(conversationID: conversation, selectedText: "Selected question", sessionTitle: "Fixture"))
        #expect(selectedUser.prompt.isEmpty)
        #expect(selectedUser.recentTurns.map(\.text) == ["First question", "Repeated answer", "Selected question"])
        let truncated = try #require(await resolver.resolve(conversationID: conversation, selectedText: "One  two", sessionTitle: "Fixture"))
        #expect(truncated.recentTurns.last?.text == "One  two…")
        #expect(await resolver.resolve(conversationID: conversation, selectedText: "Repeated answer", sessionTitle: "Fixture") == nil)
        #expect(await resolver.resolve(conversationID: conversation, selectedText: "One two", sessionTitle: "Fixture") == nil)
    }

    @Test("Verified conversation backlink survives an unmatched selection")
    @MainActor
    func unmatchedAntigravitySelectionKeepsBacklink() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let url = try #require(URL(string: "http://127.0.0.1:49807/c/\(id)"))
        let conversation = try #require(AntigravityConversationID(webAreaURL: url))
        try writeTranscript([
            ["type": "USER_INPUT", "content": "A logged question"],
            ["type": "PLANNER_RESPONSE", "content": "A logged reply"]
        ], conversationID: id, home: dir)
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let selection = CapturedSelection(
            text: "Selected rendered text", bundleIdentifier: CapturedSelection.antigravityBundleIdentifier,
            appName: "Antigravity", antigravityConversationID: conversation
        )
        let coordinator = try AppCoordinator(
            paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: StubCapturer(selection: selection), antigravityContext: AntigravityCaptureContext(homeDirectory: dir)
        )
        await coordinator.captureSelection()

        let entry = try #require(coordinator.outbox.loadEntries().first)
        #expect(entry.commentContent == nil)
        #expect(!entry.memoContent.contains("#rewind/has-ctx"))
        let card = try #require(coordinator.cards.first)
        #expect(card.sourceURL == "conversation://\(id)")
        #expect(card.verbatimText == selection.text)
    }

    private func writeTranscript(_ records: [[String: Any]], conversationID: String, home: URL) throws {
        let file = home.appendingPathComponent(".gemini/antigravity/brain/\(conversationID)/.system_generated/logs/transcript.jsonl")
        let lines = try records.map { record in
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        try AtomicFile.writeUTF8(lines.joined(separator: "\n") + "\n", to: file)
    }

    @Test("Plugin repair retires generated capture hooks and preserves unrelated hooks and local data", arguments: ["environment", "quoted", "bare"])
    func officialPluginInstallerRetiresCaptureHooks(commandStyle: String) throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeBuildDir = dir.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBuildDir, withIntermediateDirectories: true)
        let fakeSidecarSrc = fakeBuildDir.appendingPathComponent("coding-rewind-sidecar")
        let fakeBridgeSrc = dir.appendingPathComponent("memos-mcp-bridge.sh")
        try AtomicFile.writeUTF8("#!/bin/sh\necho '{}'\n", to: fakeSidecarSrc, permissions: 0o755)
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: fakeBridgeSrc, permissions: 0o755)

        let dataDir = dir.appendingPathComponent(commandStyle == "bare" ? "CodingRewind" : "Application Support/CodingRewind", isDirectory: true)
        let configDir = dir.appendingPathComponent("gemini-config", isDirectory: true)

        let hooksURL = configDir.appendingPathComponent("plugins/coding-rewind/hooks.json")
        let installedLegacyHook = dataDir.appendingPathComponent("bin/coding-rewind-hook")
        let oldSnapshot = dataDir.appendingPathComponent("active_turn.json")
        try AtomicFile.writeUTF8("old user snapshot", to: oldSnapshot)
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: installedLegacyHook, permissions: 0o755)
        let command: String
        switch commandStyle {
        case "bare": command = installedLegacyHook.path
        case "quoted": command = "'\(installedLegacyHook.path)'"
        default: command = "/usr/bin/env 'CODING_REWIND_DATA_DIR=\(dataDir.path)' '\(installedLegacyHook.path)'"
        }
        let obsolete: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5
        ]
        let unrelated = ["type": "command", "command": "echo unrelated"]
        let previous: [String: Any] = [
            "coding-rewind": ["PostInvocation": [obsolete, unrelated], "Stop": [obsolete]],
            "other-plugin": ["Stop": [unrelated]]
        ]
        try AtomicFile.writeData(JSONSerialization.data(withJSONObject: previous), to: hooksURL)
        let pluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: dataDir,
            configDirectoryURL: configDir,
            sourceMCPBridgeURL: fakeBridgeSrc,
            sourceSidecarBinaryURL: fakeSidecarSrc
        )

        let status = AntigravityIntegration.verify(dataDirectoryURL: dataDir, configDirectoryURL: configDir)
        guard case .installed = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        let installedSidecar = AntigravityIntegration.stableSidecarBinaryURL(in: dataDir)
        #expect(!installedSidecar.path.contains("/.build/"))
        #expect(FileManager.default.isExecutableFile(atPath: installedSidecar.path))
        #expect(FileManager.default.isExecutableFile(atPath: installedLegacyHook.path))
        #expect(try String(contentsOf: oldSnapshot, encoding: .utf8) == "old user snapshot")
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
        #expect(hooksJSON["coding-rewind"] as? [String: [[String: String]]] == ["PostInvocation": [unrelated]])
        #expect(hooksJSON["other-plugin"] as? [String: [[String: String]]] == ["Stop": [unrelated]])
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
        var coord = try AppCoordinator(
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
        #expect(initialSnap.headerTitle == "Coding Rewind · 0 条片段")
        #expect(initialSnap.headerSubtitle == "Memos 尚未设置，可先保存到本机 · 插件需要安装或修复")
        #expect(initialSnap.toggleHUDTitle == "显示片段浮窗")
        #expect(initialSnap.launchTitle == "在所选应用中开始对话")

        await coord.captureSelection()
        let pendingSnap = coord.menuStatusSnapshot(isHUDVisible: true, isAccessibilityTrusted: true)
        #expect(pendingSnap.hotCardCount == 1)
        #expect(pendingSnap.checkedCardCount == 1)
        #expect(pendingSnap.pendingOutboxCount == 1)
        #expect(pendingSnap.isAccessibilityTrusted == true)
        #expect(pendingSnap.headerTitle == "Coding Rewind · 1 条片段（待同步 1 条）")
        #expect(pendingSnap.toggleHUDTitle == "隐藏片段浮窗")
        #expect(pendingSnap.launchTitle == "在所选应用中开始对话（已选 1 条）")
        #expect(pendingSnap.recentCards.count == 1)
        #expect(pendingSnap.recentCards[0].sourcePlatform == "gemini")
        #expect(pendingSnap.recentCards[0].isChecked == true)
        #expect(pendingSnap.recentCards[0].titlePreview == "First line Second line with extra sp…")

        try paths.saveMemosURLString("https://memos.example.com:443/api/memos/")
        let defaultPortSnap = coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: true)
        #expect(
            defaultPortSnap.connection == .configured(
                hostSummary: "memos.example.com",
                baseURL: try #require(URL(string: "https://memos.example.com:443"))
            )
        )

        try paths.saveMemosURLString("http://localhost:5230")
        let fakeSidecar = dir.appendingPathComponent("coding-rewind-sidecar")
        try AtomicFile.writeUTF8("#!/bin/sh\necho '{}'\n", to: fakeSidecar, permissions: 0o755)
        coord.installOrRepairPlugin(sourceBridgeURL: nil, sourceSidecarURL: fakeSidecar)

        let now = Date()
        coord.checkedCardIDs.removeAll()
        let menuCards = (1...6).map { idx in
            RewindCard(
                id: "c-\(idx)",
                rawContent: "#rewind/ready #source/claude\n\n> **Title:** \(idx == 1 ? "Multi line Card One" : "Card \(idx)")\n> **Source:** [Claude](https://claude.ai)\n\nBody \(idx)",
                status: .ready,
                sourcePlatform: "claude",
                title: idx == 1 ? "  Multi\n  line\tCard One  " : "Card \(idx)",
                sourceTitle: "Claude",
                verbatimText: "Body \(idx)",
                createdAt: now.addingTimeInterval(Double(-idx))
            )
        }
        try coord.hotCache.saveCards(menuCards)
        try FileManager.default.removeItem(at: paths.outboxFileURL)
        coord = try AppCoordinator(paths: paths, environment: coord.environment, memosClient: coord.memosClient, capturer: coord.capturer)
        coord.focusAndCheckCard(id: "nonexistent-id")
        #expect(coord.checkedCardIDs.isEmpty)

        coord.focusAndCheckCard(id: "c-3")
        #expect(coord.focusedCardID == "c-3")
        #expect(coord.checkedCardIDs == Set(["c-3"]))

        let customPortSnap = coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: true)
        #expect(
            customPortSnap.connection == .configured(
                hostSummary: "localhost:5230",
                baseURL: try #require(URL(string: "http://localhost:5230"))
            )
        )
        #expect(customPortSnap.isPluginReady == true)
        #expect(customPortSnap.headerSubtitle == "Memos 已配置 localhost:5230 · 插件已安装")
        #expect(customPortSnap.recentCards.count == 5)
        #expect(customPortSnap.recentCards[0].titlePreview == "Multi line Card One")
        #expect(customPortSnap.recentCards[2].id == "c-3")
        #expect(customPortSnap.recentCards[2].isChecked == true)
        #expect(customPortSnap.launchTitle == "在所选应用中开始对话（已选 1 条）")
    }
    @Test("Sidecar installation preserves host project assignment and refuses unknown config shapes")
    func sidecarInstallationConfigBoundaries() throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("helper")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: source, permissions: 0o755)
        let data = dir.appendingPathComponent("Data", isDirectory: true)
        let config = dir.appendingPathComponent("Config", isDirectory: true)
        let plugin = try AntigravityIntegration.installOrRepair(dataDirectoryURL: data, configDirectoryURL: config, sourceSidecarBinaryURL: source)
        let configURL = config.appendingPathComponent("config.json")
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let sidecars = try #require(root["sidecars"] as? [String: Any])
        #expect((sidecars["coding-rewind/launcher"] as? [String: Bool]) == ["enabled": true])
        let sidecar = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: plugin.appendingPathComponent("sidecars/launcher/sidecar.json"))) as? [String: Any])
        #expect(sidecar["command"] as? String == AntigravityIntegration.stableSidecarBinaryURL(in: data).path)
        #expect(sidecar["args"] as? [String] == ["--data-dir", data.path])
        #expect(sidecar["restart_policy"] as? String == "always")
        root["sidecars"] = ["coding-rewind/launcher": ["enabled": false, "projectId": "host-project", "schemaVersion": 1], "other/worker": ["enabled": true]]
        root["unrelated"] = "preserve me"
        try AtomicFile.writeData(JSONSerialization.data(withJSONObject: root), to: configURL)
        try AntigravityIntegration.installOrRepair(dataDirectoryURL: data, configDirectoryURL: config)
        let repaired = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let repairedSidecars = try #require(repaired["sidecars"] as? [String: Any])
        let launcher = try #require(repairedSidecars["coding-rewind/launcher"] as? [String: Any])
        #expect(launcher["enabled"] as? Bool == true)
        #expect(launcher["projectId"] as? String == "host-project")
        #expect(launcher["schemaVersion"] as? Int == 1)
        #expect(repairedSidecars["other/worker"] != nil)
        #expect(repaired["unrelated"] as? String == "preserve me")
        for invalid in ["[]", "{\"sidecars\":[]}", "{\"sidecars\":{\"coding-rewind/launcher\":[]}}"] {
            try AtomicFile.writeUTF8(invalid, to: configURL)
            #expect(throws: RewindError.self) { try AntigravityIntegration.installOrRepair(dataDirectoryURL: data, configDirectoryURL: config) }
            #expect(try String(contentsOf: configURL, encoding: .utf8) == invalid)
        }
    }

    @Test("HUD resumes an uncertain request, never resends it, and requires explicit acknowledgment")
    @MainActor
    func uncertainConversationRecovery() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let store = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL)
        let current = try store.submit(prompt: "private prompt", cardIDs: ["memo"], markSynthesized: false)
        let capturer = StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture"))
        let coordinator = try AppCoordinator(paths: paths, environment: [:], capturer: capturer)
        #expect(coordinator.checkedCardIDs == ["memo"])
        coordinator.markSynthesizedOnLaunch = true
        #expect(await coordinator.launchChecked(in: .antigravity, waitSeconds: 0) == .failed(state: .unknown))
        coordinator.endUnconfirmedConversation()
        #expect(try store.current()?.markSynthesized == false)
        #expect(try store.current()?.requestId == current.requestId)
        #expect(try store.pendingRequests().count == 1)
        try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .unknown))
        try store.removeRequest(current.requestId)
        #expect(await coordinator.launchChecked(in: .antigravity, waitSeconds: 0) == .failed(state: .unknown))
        #expect(coordinator.canEndUnconfirmedConversation)
        coordinator.endUnconfirmedConversation()
        #expect(try store.current() == nil)
        #expect(coordinator.checkedCardIDs.isEmpty)
        #expect(await coordinator.launchChecked(in: .antigravity, waitSeconds: 0) == nil)
        #expect(try store.pendingRequests().isEmpty)
    }

    @Test("Changing the selected host cannot replace an existing request or its archive intent", arguments: ConversationHost.allCases)
    @MainActor
    func persistedConversationWins(host: ConversationHost) async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let store = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: host)
        let current = try store.submit(prompt: "original prompt", cardIDs: ["original-card"], markSynthesized: true)
        try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .unknown))
        try store.removeRequest(current.requestId)
        let coordinator = try AppCoordinator(paths: paths, environment: [:], capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")), codexDelivery: { _ in
            Issue.record("An unknown request must never be dispatched again")
            return (.unknown, nil)
        })
        let other: ConversationHost = host == .codex ? .antigravity : .codex
        coordinator.conversationHost = other
        coordinator.markSynthesizedOnLaunch = false
        coordinator.checkedCardIDs = ["changed-card"]
        #expect(await coordinator.launchChecked(in: other, waitSeconds: 0) == .failed(state: .unknown))
        #expect(coordinator.effectiveConversationHost == host)
        #expect(try store.current() == current)
        let otherStore = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: other)
        #expect(try otherStore.current() == nil)
        #expect(try store.pendingRequests().isEmpty)
        let restored = try AppCoordinator(paths: paths, environment: [:], capturer: coordinator.capturer)
        #expect(restored.conversationHost == other)
        #expect(restored.effectiveConversationHost == host)
        #expect(restored.canEndUnconfirmedConversation)
    }

    @Test("A failed Codex navigation retries the confirmed thread without sending again")
    @MainActor
    func confirmedCodexNavigationRetry() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let store = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .codex)
        let current = try store.submit(prompt: "already sent", cardIDs: ["memo"], markSynthesized: false)
        let threadID = UUID().uuidString
        let reference = ConversationReference(host: .codex, id: threadID)
        try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .succeeded, conversationId: threadID))
        try store.removeRequest(current.requestId)
        var opened: [ConversationReference] = []
        var coordinator = try AppCoordinator(paths: paths, environment: [:], capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")), codexDelivery: { _ in
            Issue.record("Opening a confirmed thread must not send another message")
            return (.unknown, nil)
        })
        coordinator.onOpenConversation = { opened.append($0); return false }
        #expect(await coordinator.launchChecked(waitSeconds: 0) == .succeeded(reference))
        #expect(coordinator.isErrorBanner)
        #expect(try store.current()?.requestId == current.requestId)
        coordinator = try AppCoordinator(paths: paths, environment: [:], capturer: coordinator.capturer)
        coordinator.onOpenConversation = { opened.append($0); return true }
        coordinator.reopenConfirmedConversation()
        #expect(!coordinator.isErrorBanner)
        #expect(coordinator.activeConversationHost == nil)
        #expect(opened == [reference, reference])
        #expect(try store.current() == nil)
    }

    @Test("Codex delivery receives the complete shared prompt and unknown results retain every card")
    @MainActor
    func codexSubmissionAndUnknown() async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let card = try #require(MemosWireFormat.parseMemo(id: "memo", rawContent: "#rewind/ready #source/chatgpt\n\n> Title: 测试\n> Context: 上下文\n> Source: [出处](https://chatgpt.com/c/example)\n\n汉字 e\u{301}\n```swift\nlet x = 1\n\nprint(x)\n```", createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card])
        let deliveries = CodexDeliveryRecorder()
        let coordinator = try AppCoordinator(paths: paths, environment: [:], capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")), codexDelivery: { prompt in
            deliveries.record(prompt.prompt)
            return (.unknown, nil)
        })
        coordinator.conversationHost = .codex
        coordinator.checkedCardIDs = [card.id]
        coordinator.markSynthesizedOnLaunch = true
        #expect(await coordinator.launchChecked(waitSeconds: 0) == .failed(state: .unknown))
        coordinator.conversationHost = .antigravity
        #expect(await coordinator.launchChecked(waitSeconds: 0) == .failed(state: .unknown))
        #expect(deliveries.prompts == [ConversationPrompt.buildPrompt(for: [card])])
        #expect(coordinator.cards == [card])
        #expect(coordinator.checkedCardIDs == [card.id])
        #expect(try coordinator.codexHandoff.current()?.archiveCardIDs == [card.id])
        #expect(try coordinator.handoff.current() == nil)
        #expect(coordinator.confirmedConversation == nil)
    }

    @Test("A confirmed conversation archives only successfully patched cards and retries archiving without another conversation", arguments: ConversationHost.allCases)
    @MainActor
    func conversationArchiveFailureAndRetry(host: ConversationHost) async throws {
        let dir = try makeIsolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { MockMemosURLProtocol.unregister(suiteID: suiteID) }
        MockMemosURLProtocol.register(suiteID: suiteID) { _, _ in (500, Data()) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let card = try #require(MemosWireFormat.parseMemo(id: "memo", rawContent: "#rewind/ready #source/macos\n\noriginal", createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card])
        var coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).mock.memos.local", StoragePaths.memosTokenEnvironmentKey: "fixture-token", StoragePaths.qaEnvironmentKey: "1"], memosClient: MemosClient(session: makeMockSession()), capturer: StubCapturer(selection: CapturedSelection(text: "", bundleIdentifier: "fixture", appName: "Fixture")))
        let store = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: host)
        coordinator.onOpenConversation = { _ in true }
        coordinator.checkedCardIDs = [card.id]
        let current = try store.submit(prompt: ConversationPrompt.buildPrompt(for: [card]), cardIDs: [card.id], markSynthesized: true)
        let conversationID = UUID().uuidString
        try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .succeeded, conversationId: conversationID))
        try store.removeRequest(current.requestId)
        #expect(await coordinator.launchChecked(in: host, waitSeconds: 0) == .succeeded(ConversationReference(host: host, id: conversationID)))
        #expect(coordinator.isErrorBanner)
        #expect(coordinator.checkedCardIDs == [card.id])
        #expect(coordinator.cards == [card])
        #expect(try store.current()?.requestId == current.requestId)
        #expect(try store.pendingRequests().isEmpty)
        MockMemosURLProtocol.register(suiteID: suiteID) { _, _ in (200, Data()) }
        #expect(await coordinator.launchChecked(in: host, waitSeconds: 0) == .succeeded(ConversationReference(host: host, id: conversationID)))
        #expect(coordinator.checkedCardIDs.isEmpty)
        #expect(coordinator.cards.isEmpty)
        #expect(try store.current() == nil)
        #expect(await coordinator.launchChecked(in: host, waitSeconds: 0) == nil)
        #expect(try store.pendingRequests().isEmpty)
        try coordinator.hotCache.saveCards([card])
        coordinator = try AppCoordinator(paths: paths, environment: coordinator.environment, memosClient: coordinator.memosClient, capturer: coordinator.capturer)
        coordinator.onOpenConversation = { _ in true }
        coordinator.checkedCardIDs = [card.id, "missing-old-card"]
        let partial = try store.submit(prompt: "another confirmed conversation", cardIDs: [card.id, "missing-old-card"], markSynthesized: true)
        try store.saveReceipt(ConversationReceipt(requestId: partial.requestId, state: .succeeded, conversationId: conversationID))
        try store.removeRequest(partial.requestId)
        _ = await coordinator.launchChecked(in: host, waitSeconds: 0)
        #expect(coordinator.isErrorBanner)
        #expect(coordinator.canEndUnarchivedConversation)
        #expect(try store.current()?.archiveCardIDs == ["missing-old-card"])
        #expect(coordinator.checkedCardIDs == ["missing-old-card"])
        _ = await coordinator.launchChecked(in: host, waitSeconds: 0)
        #expect(try store.current()?.archiveCardIDs == ["missing-old-card"])
        #expect(coordinator.isErrorBanner)
        coordinator.endUnarchivedConversation()
        #expect(try store.current() == nil)
        #expect(coordinator.checkedCardIDs.isEmpty)
        #expect(try store.pendingRequests().isEmpty)
    }

}

private final class CodexDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var prompts: [String] { lock.withLock { values } }
    func record(_ prompt: String) { lock.withLock { values.append(prompt) } }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import os
import Testing

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

private final class ConcurrencyMockURLProtocol: URLProtocol {
    typealias AsyncHandler = @Sendable (URLRequest, Data) async throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock<[String: AsyncHandler]>(initialState: [:])

    static func register(suiteID: String, handler: @escaping AsyncHandler) {
        handlers.withLock { $0[suiteID] = handler }
    }

    static func unregister(suiteID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".concurrency.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".concurrency.mock.local", with: "")
        guard let handler = Self.handlers.withLock({ $0[suiteID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let req = request
        let bodyData = Self.readBody(from: req)
        let protoBox = UncheckedBox(value: self)
        Task.detached {
            let proto = protoBox.value
            do {
                let (statusCode, data) = try await handler(req, bodyData)
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ) else {
                    proto.client?.urlProtocol(proto, didFailWithError: URLError(.badServerResponse))
                    return
                }
                proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                proto.client?.urlProtocol(proto, didLoad: data)
                proto.client?.urlProtocolDidFinishLoading(proto)
            } catch {
                proto.client?.urlProtocol(proto, didFailWithError: error)
            }
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

private struct ConcurrencyFixedCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

private actor PatchConcurrencyGate {
    private var patchCount = 0
    private var getCountAfterFirstPatch = 0
    private var firstPatchEntered = false
    private var firstPatchReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondGetWaiters: [CheckedContinuation<Bool, Never>] = []

    func recordGet() {
        guard firstPatchEntered && !firstPatchReleased else { return }
        getCountAfterFirstPatch += 1
        let waiters = secondGetWaiters
        secondGetWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    func suspendIfFirstPatch() async {
        patchCount += 1
        guard patchCount == 1 else { return }
        firstPatchEntered = true
        let entered = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in entered {
            waiter.resume()
        }
        if !firstPatchReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilFirstPatchEntered() async {
        if firstPatchEntered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitBrieflyForConcurrentGet(milliseconds: Int = 80) async -> Bool {
        if getCountAfterFirstPatch > 0 { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForConcurrentGet()
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            self.cancelPendingSecondGetWaiters()
            return result
        }
    }

    private func waitForConcurrentGet() async -> Bool {
        if getCountAfterFirstPatch > 0 { return true }
        return await withCheckedContinuation { continuation in
            secondGetWaiters.append(continuation)
        }
    }

    private func cancelPendingSecondGetWaiters() {
        let waiters = secondGetWaiters
        secondGetWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }

    func releaseFirstPatch() {
        firstPatchReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ListSuspensionGate {
    private var armed = false
    private var enteredCount = 0
    private var released = false
    private var targetCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(expectedCalls: Int) {
        armed = true
        enteredCount = 0
        released = false
        targetCount = expectedCalls
    }

    func suspendIfArmed() async {
        guard armed else { return }
        enteredCount += 1
        if enteredCount >= targetCount {
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        if enteredCount >= targetCount { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        armed = false
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor MockMemoStore {
    var memos: [String: MemoWireDTO]

    init(memos: [String: MemoWireDTO]) {
        self.memos = memos
    }

    func allMemos() -> [MemoWireDTO] {
        Array(memos.values)
    }

    func memo(id: String) -> MemoWireDTO? {
        memos[id]
    }

    func create(id: String, content: String, createTime: String) -> MemoWireDTO {
        let dto = MemoWireDTO(name: "memos/\(id)", content: content, createTime: createTime)
        memos[id] = dto
        return dto
    }

    func update(id: String, content: String) -> MemoWireDTO? {
        guard let existing = memos[id] else { return nil }
        let updated = MemoWireDTO(name: existing.name, content: content, createTime: existing.createTime)
        memos[id] = updated
        return updated
    }

    func delete(id: String) -> Bool {
        memos.removeValue(forKey: id) != nil
    }
}

@Suite("Library Concurrency and Unbounded Aggregate")
struct LibraryConcurrencyAndBoundsTests {
    private func makeTestDir() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-concurrency-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeClient() -> MemosClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrencyMockURLProtocol.self]
        return MemosClient(session: URLSession(configuration: config))
    }

    @MainActor
    private func makeCoordinator(dir: URL, suiteID: String) throws -> AppCoordinator {
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        return try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).concurrency.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "qa-concurrency-token"
            ],
            memosClient: makeClient(),
            capturer: ConcurrencyFixedCapturer(
                selection: CapturedSelection(text: "x", bundleIdentifier: "com.apple.Notes", appName: "Notes")
            ),
            language: .en
        )
    }

    @Test("refreshPlaceLibrary loads all 501 snippets without 500-item truncation so older unplaced clips are counted")
    @MainActor
    func unboundedPlaceLibraryIncludesOlderClipBeyond500() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ConcurrencyMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date(timeIntervalSince1970: 1_763_900_000)
        let alphaRef = try #require(PlaceRef(tag: "project/alpha"))
        let alphaPlace = PlaceRecord(ref: alphaRef, title: "Alpha", aliases: ["alpha"])

        var memos: [String: MemoWireDTO] = [
            alphaRef.memoID: MemoWireDTO(
                name: "memos/\(alphaRef.memoID)",
                content: MemosWireFormat.formatPlaceMemo(alphaPlace),
                createTime: MemosWireFormat.formatISO8601UTC(now)
            )
        ]

        for index in 1...500 {
            let clipID = String(format: "clip-placed-%03d", index)
            let ts = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-Double(index)))
            let content = "#rewind/ready #source/chatgpt #project/alpha\n\n> **Title:** Placed \(index)\n> **Source:** [Chat](https://chatgpt.com/c/p-\(index)) · \(ts)\n\nBody \(index)."
            memos[clipID] = MemoWireDTO(name: "memos/\(clipID)", content: content, createTime: ts)
        }

        let olderTS = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-1000))
        let olderContent = "#rewind/ready #source/chatgpt\n\n> **Title:** Older Unplaced 501\n> **Source:** [Chat](https://chatgpt.com/c/old-501) · \(olderTS)\n\nUnplaced clip beyond 500."
        memos["clip-unplaced-501"] = MemoWireDTO(name: "memos/clip-unplaced-501", content: olderContent, createTime: olderTS)

        let store = MockMemoStore(memos: memos)
        ConcurrencyMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            if method == "GET" && path == "/api/memos" {
                let list = await store.allMemos()
                let enc = JSONEncoder()
                enc.outputFormatting = [.withoutEscapingSlashes]
                return (200, (try? enc.encode(["memos": list])) ?? Data())
            }
            return (404, Data())
        }

        let coord = try makeCoordinator(dir: dir, suiteID: suiteID)
        await coord.refreshPlaceLibrary()

        #expect(coord.libraryRecords?.count == 501)
        #expect(coord.unplacedCount == 1)
        #expect(coord.libraryRecords?.contains(where: { $0.id == "clip-unplaced-501" }) == true)
        #expect(coord.placeClipCounts[alphaRef] == 500)
    }

    @Test("Concurrent removePlace calls on the same snippet serialize so neither removal is overwritten")
    @MainActor
    func concurrentDualPlaceRemovalPreservesBothRemovals() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ConcurrencyMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let alphaRef = try #require(PlaceRef(tag: "project/alpha"))
        let betaRef = try #require(PlaceRef(tag: "topic/beta"))
        let alphaPlace = PlaceRecord(ref: alphaRef, title: "Alpha")
        let betaPlace = PlaceRecord(ref: betaRef, title: "Beta")

        let dualContent = "#rewind/ready #source/chatgpt #project/alpha #topic/beta\n\n> **Title:** Dual Placed Clip\n> **Source:** [Chat](https://chatgpt.com/c/dual-1) · \(nowISO)\n\nVerbatim dual clip."
        let store = MockMemoStore(memos: [
            alphaRef.memoID: MemoWireDTO(name: "memos/\(alphaRef.memoID)", content: MemosWireFormat.formatPlaceMemo(alphaPlace), createTime: nowISO),
            betaRef.memoID: MemoWireDTO(name: "memos/\(betaRef.memoID)", content: MemosWireFormat.formatPlaceMemo(betaPlace), createTime: nowISO),
            "clip-dual": MemoWireDTO(name: "memos/clip-dual", content: dualContent, createTime: nowISO)
        ])
        let gate = PatchConcurrencyGate()

        ConcurrencyMockURLProtocol.register(suiteID: suiteID) { req, body in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            if method == "GET" && path == "/api/memos" {
                let list = await store.allMemos()
                return (200, (try? enc.encode(["memos": list])) ?? Data())
            }
            if path == "/api/memos/clip-dual" {
                if method == "GET" {
                    await gate.recordGet()
                    if let dto = await store.memo(id: "clip-dual") {
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                }
                if method == "PATCH",
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let content = obj["content"] as? String {
                    await gate.suspendIfFirstPatch()
                    if let updated = await store.update(id: "clip-dual", content: content) {
                        return (200, (try? enc.encode(updated)) ?? Data())
                    }
                }
            }
            return (404, Data())
        }

        let coord = try makeCoordinator(dir: dir, suiteID: suiteID)
        await coord.refreshPlaceLibrary()
        #expect(coord.libraryRecords?.first(where: { $0.id == "clip-dual" })?.places == [alphaRef, betaRef])

        let firstRemoval = Task { @MainActor in
            await coord.removePlace(alphaRef, from: "clip-dual")
        }
        await gate.waitUntilFirstPatchEntered()

        let secondRemoval = Task { @MainActor in
            await coord.removePlace(betaRef, from: "clip-dual")
        }
        _ = await gate.waitBrieflyForConcurrentGet(milliseconds: 80)
        await gate.releaseFirstPatch()

        await firstRemoval.value
        await secondRemoval.value

        let finalServerMemo = try #require(await store.memo(id: "clip-dual"))
        let parsedServer = try #require(
            MemosWireFormat.parseSnippetRecord(
                id: finalServerMemo.name,
                rawContent: finalServerMemo.content,
                createdAt: now,
                dataOrigin: .remote
            )
        )
        #expect(parsedServer.places.isEmpty)
        #expect(coord.libraryRecords?.first(where: { $0.id == "clip-dual" })?.places.isEmpty == true)
    }

    @Test("In-flight refreshPlaceLibrary does not resurrect locally deleted or archived clips")
    @MainActor
    func inFlightRefreshPlaceLibraryDoesNotResurrectDeletedOrArchivedClip() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ConcurrencyMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let keepContent = "#rewind/ready #source/chatgpt\n\n> **Title:** Keep Clip\n> **Source:** [Chat](https://chatgpt.com/c/keep) · \(nowISO)\n\nKeep me."
        let deleteContent = "#rewind/ready #source/chatgpt\n\n> **Title:** Delete Clip\n> **Source:** [Chat](https://chatgpt.com/c/del) · \(nowISO)\n\nDelete me."
        let archiveContent = "#rewind/ready #source/chatgpt\n\n> **Title:** Archive Clip\n> **Source:** [Chat](https://chatgpt.com/c/arch) · \(nowISO)\n\nArchive me."

        let store = MockMemoStore(memos: [
            "clip-keep": MemoWireDTO(name: "memos/clip-keep", content: keepContent, createTime: nowISO),
            "clip-delete": MemoWireDTO(name: "memos/clip-delete", content: deleteContent, createTime: nowISO),
            "clip-archive": MemoWireDTO(name: "memos/clip-archive", content: archiveContent, createTime: nowISO)
        ])
        let gate = ListSuspensionGate()

        ConcurrencyMockURLProtocol.register(suiteID: suiteID) { req, body in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            if method == "GET" && path == "/api/memos" {
                let staleSnapshot = await store.allMemos()
                await gate.suspendIfArmed()
                return (200, (try? enc.encode(["memos": staleSnapshot])) ?? Data())
            }
            if path.hasPrefix("/api/memos/") {
                let mid = String(path.dropFirst("/api/memos/".count))
                if method == "DELETE" {
                    let existed = await store.delete(id: mid)
                    return (existed ? 200 : 404, Data("{}".utf8))
                }
                if method == "GET", let dto = await store.memo(id: mid) {
                    return (200, (try? enc.encode(dto)) ?? Data())
                }
                if method == "PATCH",
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let content = obj["content"] as? String,
                   let updated = await store.update(id: mid, content: content) {
                    return (200, (try? enc.encode(updated)) ?? Data())
                }
            }
            return (404, Data())
        }

        let coord = try makeCoordinator(dir: dir, suiteID: suiteID)
        await coord.refresh()
        #expect(coord.libraryRecords == nil)
        #expect(coord.cards.contains(where: { $0.id == "clip-delete" }))

        await gate.arm(expectedCalls: 2)
        let firstRefresh = Task { @MainActor in
            await coord.refreshPlaceLibrary()
        }
        await gate.waitUntilEntered()

        await coord.requestDeleteCards(ids: ["clip-delete"], bypassConfirmation: true)
        #expect(!coord.cards.contains(where: { $0.id == "clip-delete" }))

        await gate.release()
        await firstRefresh.value

        #expect(coord.libraryRecords?.contains(where: { $0.id == "clip-delete" }) != true)
        #expect(!coord.libraryProjection.visibleItems.contains(where: { $0.id == "clip-delete" }))

        await coord.refreshPlaceLibrary()
        #expect(coord.libraryRecords?.first(where: { $0.id == "clip-archive" })?.status == .ready)

        await gate.arm(expectedCalls: 2)
        let secondRefresh = Task { @MainActor in
            await coord.refreshPlaceLibrary()
        }
        await gate.waitUntilEntered()

        await coord.archiveCards(ids: ["clip-archive"])
        #expect(coord.libraryRecords?.first(where: { $0.id == "clip-archive" })?.status == .synthesized)

        await gate.release()
        await secondRefresh.value

        #expect(coord.libraryRecords?.first(where: { $0.id == "clip-archive" })?.status == .synthesized)
    }

    @Test("Queued place patch follows server ID remap produced by an earlier in-flight place patch")
    @MainActor
    func serializedPlacePatchesFollowRemappedServerID() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ConcurrencyMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let alphaRef = try #require(PlaceRef(tag: "project/alpha"))
        let betaRef = try #require(PlaceRef(tag: "topic/beta"))
        let localID = "rw-local-remap-1"
        let serverID = "srv-remap-1"
        let rawLocal = "#rewind/ready #source/chatgpt\n\n> **Title:** Offline Remapped Clip\n> **Source:** [Chat](https://chatgpt.com/c/remap) · \(nowISO)\n\nRemapped verbatim."

        let store = MockMemoStore(memos: [:])
        let gate = PatchConcurrencyGate()

        ConcurrencyMockURLProtocol.register(suiteID: suiteID) { req, body in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            if method == "POST" && path == "/api/memos",
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let content = obj["content"] as? String {
                let created = await store.create(id: serverID, content: content, createTime: nowISO)
                return (200, (try? enc.encode(created)) ?? Data())
            }
            if path == "/api/memos/\(serverID)" {
                if method == "GET", let dto = await store.memo(id: serverID) {
                    return (200, (try? enc.encode(dto)) ?? Data())
                }
                if method == "PATCH",
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let content = obj["content"] as? String {
                    await gate.suspendIfFirstPatch()
                    if let updated = await store.update(id: serverID, content: content) {
                        return (200, (try? enc.encode(updated)) ?? Data())
                    }
                }
            }
            return (404, Data())
        }

        let coord = try makeCoordinator(dir: dir, suiteID: suiteID)
        try coord.outbox.enqueue(
            OutboxEntry(
                clientClipId: localID,
                memoContent: rawLocal,
                commentContent: nil,
                createdAt: now
            )
        )
        let localRecord = try #require(
            MemosWireFormat.parseSnippetRecord(
                id: localID,
                rawContent: rawLocal,
                createdAt: now,
                dataOrigin: .offlinePending
            )
        )
        coord.libraryRecords = [localRecord]

        let firstPatch = Task { @MainActor in
            await coord.addPlace(alphaRef, to: localID)
        }
        await gate.waitUntilFirstPatchEntered()

        let secondPatch = Task { @MainActor in
            await coord.addPlace(betaRef, to: localID)
        }
        await Task.yield()
        await gate.releaseFirstPatch()

        await firstPatch.value
        await secondPatch.value

        let finalServerMemo = try #require(await store.memo(id: serverID))
        let parsedServer = try #require(
            MemosWireFormat.parseSnippetRecord(
                id: finalServerMemo.name,
                rawContent: finalServerMemo.content,
                createdAt: now,
                dataOrigin: .remote
            )
        )
        #expect(parsedServer.places == [alphaRef, betaRef])
        #expect(coord.libraryRecords?.map(\.id) == [serverID])
        #expect(coord.libraryRecords?.first?.places == [alphaRef, betaRef])
        #expect(coord.pendingPlacePatchTasks.isEmpty)
        #expect(coord.remappedSnippetIDs[localID] == serverID)
    }

    @Test("refreshPlaceLibrary and loadPlaceRecords filter deletedClipIDs even when server still returns a locally deleted clip")
    @MainActor
    func placeLibraryAndPlaceRecordsFilterDeletedClipIDsWhenServerStillReturnsClip() async throws {
        let dir = try makeTestDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteID = UUID().uuidString.lowercased()
        defer { ConcurrencyMockURLProtocol.unregister(suiteID: suiteID) }

        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let alphaRef = try #require(PlaceRef(tag: "project/alpha"))
        let alphaPlace = PlaceRecord(ref: alphaRef, title: "Alpha")
        let keepContent = "#rewind/ready #source/chatgpt #project/alpha\n\n> **Title:** Keep Clip\n> **Source:** [Chat](https://chatgpt.com/c/keep) · \(nowISO)\n\nKeep body."
        let deletedContent = "#rewind/ready #source/chatgpt #project/alpha\n\n> **Title:** Deleted Pending Clip\n> **Source:** [Chat](https://chatgpt.com/c/del-pending) · \(nowISO)\n\nDeleted body."

        let store = MockMemoStore(memos: [
            alphaRef.memoID: MemoWireDTO(
                name: "memos/\(alphaRef.memoID)",
                content: MemosWireFormat.formatPlaceMemo(alphaPlace),
                createTime: nowISO
            ),
            "clip-keep": MemoWireDTO(name: "memos/clip-keep", content: keepContent, createTime: nowISO),
            "clip-deleted": MemoWireDTO(name: "memos/clip-deleted", content: deletedContent, createTime: nowISO)
        ])

        ConcurrencyMockURLProtocol.register(suiteID: suiteID) { req, _ in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            if method == "GET" && path == "/api/memos" {
                let list = await store.allMemos()
                return (200, (try? enc.encode(["memos": list])) ?? Data())
            }
            if method == "DELETE" && path == "/api/memos/clip-deleted" {
                throw URLError(.networkConnectionLost)
            }
            return (404, Data())
        }

        let seedCoord = try makeCoordinator(dir: dir, suiteID: suiteID)
        try seedCoord.outbox.enqueue(
            OutboxEntry(
                clientClipId: "clip-deleted",
                memoContent: deletedContent,
                commentContent: nil,
                createdAt: now
            )
        )
        let coord = try makeCoordinator(dir: dir, suiteID: suiteID)
        #expect(coord.cards.contains(where: { $0.id == "clip-deleted" }))

        await coord.requestDeleteCards(ids: ["clip-deleted"], bypassConfirmation: true)
        #expect(coord.deletedClipIDs.contains("clip-deleted"))
        #expect(!coord.cards.contains(where: { $0.id == "clip-deleted" }))

        coord.hudSection = .place(alphaRef)
        await coord.refreshPlaceLibrary()

        #expect(coord.libraryRecords?.map(\.id) == ["clip-keep"])
        #expect(coord.placeRecords.map(\.id) == ["clip-keep"])
        #expect(coord.browseRecords.map(\.id) == ["clip-keep"])

        await coord.loadPlaceRecords(alphaRef)
        #expect(coord.placeRecords.map(\.id) == ["clip-keep"])
        #expect(!coord.placeRecords.contains(where: { $0.id == "clip-deleted" }))
    }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import Testing

private struct AIWriteProtocolBox<T>: @unchecked Sendable {
    let value: T
}

private final class AIWriteRepoURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest, Data) async -> (Int, Data)] = [:]

    static func register(suiteID: String, handler: @escaping @Sendable (URLRequest, Data) async -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handlers[suiteID] = handler
    }

    static func unregister(suiteID: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: suiteID)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".aiwrite-repo.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".aiwrite-repo.mock.local", with: "")
        let bodyData = Self.readBody(from: request)
        Self.lock.lock()
        let handler = Self.handlers[suiteID]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let req = request
        let protoBox = AIWriteProtocolBox(value: self)
        Task.detached {
            let (status, respData) = await handler(req, bodyData)
            let proto = protoBox.value
            if status < 0 {
                proto.client?.urlProtocol(proto, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            proto.client?.urlProtocol(proto, didReceive: http, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocol(proto, didLoad: respData)
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buf, maxLength: buf.count)
            if count <= 0 { break }
            out.append(buf, count: count)
        }
        return out
    }
}

@Suite("AI Write Surface SnippetRepository Suite")
struct AIWriteRepositoryTests {
    private func makeClient() -> MemosClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AIWriteRepoURLProtocol.self]
        return MemosClient(session: URLSession(configuration: cfg))
    }

    @Test("SnippetRepository supports create, metadata update, and note append across online, outage fallback, localOnly, and QA isolation")
    func repositoryCreateUpdateAndAppendNoteOnlineAndLocal() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-aiwrite-repo-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_763_300_000)

        let localPaths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("LocalData", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("LocalConfig", isDirectory: true)
        )
        let localRepo = SnippetRepository(paths: localPaths, environment: [StoragePaths.qaEnvironmentKey: "1"], client: makeClient())

        let localCreated = try await localRepo.createSnippet(
            SnippetCreateInput(text: "Local draft\n```swift\nlet ok = true\n```", title: "Local Draft", tags: ["thesis"]),
            now: now
        )
        #expect(localCreated.status == .ready)
        #expect(localCreated.sourcePlatform == "agent")
        #expect(localCreated.dataOrigin == .offlinePending)
        #expect(localCreated.tags == ["thesis"])
        #expect(HotCache(fileURL: localPaths.hotCacheFileURL).loadCards(now: now).map(\.id) == [localCreated.id])

        let localNoted = try await localRepo.appendSnippetNote(
            id: localCreated.id,
            input: SnippetNoteInput(note: "Stored in local_notes.json", author: "Claude"),
            now: now.addingTimeInterval(10)
        )
        #expect(localNoted.notes.count == 1)
        #expect(localNoted.notes[0].author == "Claude")
        #expect(localNoted.notes[0].content == "Stored in local_notes.json")
        #expect(FileManager.default.fileExists(atPath: localPaths.localNotesFileURL.path))

        let localArchived = try await localRepo.updateSnippetMetadata(
            id: localCreated.id,
            patch: SnippetMetadataPatch(title: "Local Draft v2", addTags: ["final"], archived: true),
            now: now.addingTimeInterval(20)
        )
        #expect(localArchived.status == .synthesized)
        #expect(localArchived.tags == ["thesis", "final"])
        #expect(localArchived.verbatimText == localCreated.verbatimText)
        #expect(HotCache(fileURL: localPaths.hotCacheFileURL).loadCards(now: now).isEmpty)

        let localUnarchived = try await localRepo.updateSnippetMetadata(
            id: localCreated.id,
            patch: SnippetMetadataPatch(archived: false),
            now: now.addingTimeInterval(30)
        )
        #expect(localUnarchived.status == .ready)
        #expect(HotCache(fileURL: localPaths.hotCacheFileURL).loadCards(now: now).map(\.id) == [localCreated.id])

        let suiteID = UUID().uuidString.lowercased()
        defer { AIWriteRepoURLProtocol.unregister(suiteID: suiteID) }

        final class MockState: @unchecked Sendable {
            private let lock = NSLock()
            var failNetwork = false
            var memos: [String: MemoWireDTO] = [:]
            var comments: [String: [MemoWireDTO]] = [:]

            func setFailNetwork(_ v: Bool) { lock.lock(); failNetwork = v; lock.unlock() }

            func handle(_ req: URLRequest, _ body: Data, _ isoNow: String) -> (Int, Data) {
                lock.lock(); defer { lock.unlock() }
                if failNetwork { return (-1, Data()) }
                guard req.value(forHTTPHeaderField: "Authorization") == "Bearer qa-write-token",
                      let url = req.url,
                      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    return (401, Data())
                }
                let method = req.httpMethod ?? "GET"
                let path = comps.path
                let enc = JSONEncoder()
                enc.outputFormatting = [.withoutEscapingSlashes]

                if method == "POST" && path == "/api/memos" {
                    let mid = comps.queryItems?.first(where: { $0.name == "memoId" })?.value ?? "rw-gen"
                    let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                    let dto = MemoWireDTO(name: "memos/\(mid)", content: obj["content"] as? String ?? "", createTime: isoNow)
                    memos[mid] = dto
                    return (200, (try? enc.encode(dto)) ?? Data())
                }
                if path.hasPrefix("/api/memos/") && path.hasSuffix("/comments") {
                    let mid = path.replacingOccurrences(of: "/api/memos/", with: "").replacingOccurrences(of: "/comments", with: "")
                    if method == "POST" {
                        let cid = comps.queryItems?.first(where: { $0.name == "commentId" })?.value ?? "rw-note"
                        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                        let dto = MemoWireDTO(name: "memos/\(cid)", content: obj["content"] as? String ?? "", createTime: isoNow)
                        comments[mid, default: []].append(dto)
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                    let items = (comments[mid] ?? []).map { ["name": $0.name, "content": $0.content, "createTime": $0.createTime ?? isoNow] }
                    return (200, (try? JSONSerialization.data(withJSONObject: ["memos": items, "nextPageToken": ""])) ?? Data())
                }
                if path.hasPrefix("/api/memos/") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    if method == "GET", let dto = memos[mid] { return (200, (try? enc.encode(dto)) ?? Data()) }
                    if method == "PATCH", let existing = memos[mid],
                       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let content = obj["content"] as? String {
                        let dto = MemoWireDTO(name: existing.name, content: content, createTime: existing.createTime)
                        memos[mid] = dto
                        return (200, (try? enc.encode(dto)) ?? Data())
                    }
                }
                return (404, Data())
            }
        }

        let state = MockState()
        let isoNow = MemosWireFormat.formatISO8601UTC(now)
        AIWriteRepoURLProtocol.register(suiteID: suiteID) { req, body in state.handle(req, body, isoNow) }

        let onlinePaths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("OnlineData", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("OnlineConfig", isDirectory: true)
        )
        let baseURLString = "https://\(suiteID).aiwrite-repo.mock.local"

        let missingTokenRepo = SnippetRepository(
            paths: onlinePaths,
            environment: [
                StoragePaths.memosURLEnvironmentKey: baseURLString,
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            client: makeClient()
        )
        await #expect(throws: RewindError.missingCredentials) {
            _ = try await missingTokenRepo.createSnippet(SnippetCreateInput(text: "Must fail in QA"), now: now)
        }

        let onlineRepo = SnippetRepository(
            paths: onlinePaths,
            environment: [
                StoragePaths.memosURLEnvironmentKey: baseURLString,
                StoragePaths.memosTokenEnvironmentKey: "qa-write-token",
                StoragePaths.qaEnvironmentKey: "1"
            ],
            client: makeClient()
        )

        let createdOnline = try await onlineRepo.createSnippet(
            SnippetCreateInput(text: "Exact synthesis body\nline 2", title: "Online Synthesis", tags: ["loop"]),
            now: now
        )
        #expect(createdOnline.dataOrigin == .remote && createdOnline.status == .ready && createdOnline.tags == ["loop"])

        let ctx = CaptureContext(sessionTitle: "Source Chat", prompt: "Prompt", recentTurns: [ConversationTurn(role: "user", text: "Turn 1")])
        _ = try await onlineRepo.client.postMemoComment(
            memoID: createdOnline.id,
            commentID: "\(createdOnline.id)-ctx",
            content: ctx.formattedCommentMarkdown(),
            baseURL: URL(string: baseURLString)!,
            token: "qa-write-token"
        )

        let afterNote = try await onlineRepo.appendSnippetNote(
            id: "memos/\(createdOnline.id)",
            input: SnippetNoteInput(note: "Attached conclusion.", author: "Antigravity"),
            now: now.addingTimeInterval(5)
        )
        #expect(afterNote.conversationContext == ctx)
        #expect(afterNote.notes.count == 1)
        #expect(afterNote.notes[0].author == "Antigravity")
        #expect(afterNote.notes[0].content == "Attached conclusion.")

        state.setFailNetwork(true)
        let queued = try await onlineRepo.createSnippet(SnippetCreateInput(text: "Outage clip"), now: now.addingTimeInterval(15))
        #expect(queued.dataOrigin == .offlinePending && queued.status == .pending)

        state.setFailNetwork(false)
        let flushed = try await onlineRepo.updateSnippetMetadata(
            id: queued.id,
            patch: SnippetMetadataPatch(title: "Flushed", addTags: ["synced"]),
            now: now.addingTimeInterval(25)
        )
        #expect(flushed.dataOrigin == .remote && flushed.status == .ready && flushed.tags == ["synced"])
        #expect(flushed.verbatimText == "Outage clip")
    }
}

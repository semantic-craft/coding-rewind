// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation
import os
import Testing

private struct DSHTestSelectionCapturer: SelectionCapturing {
    let selection: CapturedSelection

    func captureFrontmostSelection() async throws -> CapturedSelection {
        selection
    }
}

private final class DSHCaptureMockURLProtocol: URLProtocol {
    struct State {
        var createdMemoContent: String?
        var createdCommentContent: String?
        var serverID: String = "rw-dsh-server-1"
    }
    static let state = OSAllocatedUnfairLock(initialState: State())

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "dsh-capture.mock.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let bodyData = readBody()
        let nowISO = ISO8601DateFormatter().string(from: Date())

        if method == "POST", url.path == "/api/memos" {
            let decoded = bodyData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            let content = decoded?["content"] ?? ""
            let serverID = Self.state.withLock { s -> String in
                s.createdMemoContent = content
                return s.serverID
            }
            let payload: [String: String] = [
                "name": "memos/\(serverID)",
                "content": content,
                "createTime": nowISO
            ]
            respond(statusCode: 200, data: (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8))
            return
        }

        if method == "POST", url.path.hasSuffix("/comments") {
            let decoded = bodyData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            let content = decoded?["content"] ?? ""
            Self.state.withLock { $0.createdCommentContent = content }
            let payload: [String: String] = [
                "name": "memos/comment-1",
                "content": content,
                "createTime": nowISO
            ]
            respond(statusCode: 200, data: (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8))
            return
        }

        respond(statusCode: 200, data: Data("{\"memos\":[]}".utf8))
    }

    override func stopLoading() {}

    private func readBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n > 0 { data.append(buffer, count: n) } else { break }
        }
        return data
    }

    private func respond(statusCode: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://dsh-capture.mock.local")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("DSH capture context, action handoff, capture bridge, and legacy host migration")
struct DSHCaptureAndActionTests {
    private func makeTestDir(_ prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("DSHCaptureContext attaches Session Opening and up to 4 turns on unique match, omits context on ambiguity, and enforces 0600 no-symlink safety")
    func dshActiveSessionResolution() throws {
        let root = try makeTestDir("dsh-context")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let snapshot = DSHActiveSessionSnapshot(
            version: 1,
            sessionId: "sess-dsh-001",
            sessionTitle: "Swift 6 Concurrency Review",
            updatedAtMs: nowMs - 30_000,
            messages: [
                DSHSnapshotMessage(role: "user", text: "Opening topic: explain actor isolation boundaries."),
                DSHSnapshotMessage(role: "assistant", text: "Turn 1 answer with repeated phrase."),
                DSHSnapshotMessage(role: "user", text: "Turn 2 follow-up."),
                DSHSnapshotMessage(role: "assistant", text: "Turn 2 answer with repeated phrase."),
                DSHSnapshotMessage(role: "user", text: "Turn 3 question."),
                DSHSnapshotMessage(role: "assistant", text: "Turn 3 response."),
                DSHSnapshotMessage(role: "user", text: "Turn 4 question."),
                DSHSnapshotMessage(role: "assistant", text: "Turn 4 response."),
                DSHSnapshotMessage(role: "user", text: "Turn 5 final prompt."),
                DSHSnapshotMessage(role: "assistant", text: "Unique excerpt: use Sendable closures across actor hops.")
            ]
        )
        let snapshotURL = root.appendingPathComponent("dsh-active-session.json")
        try AtomicFile.writeData(JSONEncoder().encode(snapshot), to: snapshotURL, permissions: 0o600)

        let matched = DSHCaptureContext.resolve(
            selectedText: "use Sendable closures across actor hops.",
            fallbackTitle: "DeepSeek Harness",
            dataDirectoryURL: root,
            now: now
        )
        #expect(matched.sessionID == "sess-dsh-001")
        #expect(matched.sourceTitle == "Swift 6 Concurrency Review")
        let ctx = try #require(matched.context)
        #expect(ctx.sessionID == "sess-dsh-001")
        #expect(ctx.sessionOpening == "Opening topic: explain actor isolation boundaries.")
        #expect(ctx.prompt == "Turn 5 final prompt.")
        #expect(ctx.recentTurns.count == 8)
        #expect(ctx.recentTurns.first?.text == "Turn 2 follow-up.")

        let ambiguous = DSHCaptureContext.resolve(
            selectedText: "repeated phrase",
            fallbackTitle: "DeepSeek Harness",
            dataDirectoryURL: root,
            now: now
        )
        #expect(ambiguous.sessionID == "sess-dsh-001")
        #expect(ambiguous.sourceTitle == "Swift 6 Concurrency Review")
        #expect(ambiguous.context == nil)

        let staleTime = now.addingTimeInterval(20 * 60)
        let staleUnmatched = DSHCaptureContext.resolve(
            selectedText: "not in snapshot at all",
            fallbackTitle: "DeepSeek Harness",
            dataDirectoryURL: root,
            now: staleTime
        )
        #expect(staleUnmatched.sessionID == nil)
        #expect(staleUnmatched.sourceTitle == "DeepSeek Harness")
        #expect(staleUnmatched.context == nil)

        _ = chmod(snapshotURL.path, 0o644)
        let insecure = DSHCaptureContext.resolve(
            selectedText: "use Sendable closures across actor hops.",
            fallbackTitle: "DeepSeek Harness",
            dataDirectoryURL: root,
            now: now
        )
        #expect(insecure.sessionID == nil)
        #expect(insecure.context == nil)

        try FileManager.default.removeItem(at: snapshotURL)
        let externalFile = root.appendingPathComponent("external.json")
        try AtomicFile.writeData(JSONEncoder().encode(snapshot), to: externalFile, permissions: 0o600)
        try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: externalFile)
        let symlinked = DSHCaptureContext.resolve(
            selectedText: "use Sendable closures across actor hops.",
            fallbackTitle: "DeepSeek Harness",
            dataDirectoryURL: root,
            now: now
        )
        #expect(symlinked.sessionID == nil)
        #expect(symlinked.context == nil)
    }

    @Test("SourceLocator and MemosWireFormat preserve dsh-session:// links across formatting, parsing, and prompt building")
    func dshSessionSourceLocatorRoundTrip() throws {
        let locator = SourceLocator.parse(sourceURL: "dsh-session://sess-abc-42")
        #expect(locator == .dshSession(sessionID: "sess-abc-42"))
        #expect(locator?.sessionID == "sess-abc-42")
        #expect(SourceLocator.parse(sourceURL: "dsh-session://") == nil)

        let raw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Captured from DSH",
            sourcePlatform: "dsh",
            sourceTitle: "Architecture Thread",
            sourceURL: "dsh-session://sess-abc-42",
            capturedAt: Date(),
            hasContext: false
        )
        #expect(raw.contains("#source/dsh"))
        #expect(raw.contains("dsh-session://sess-abc-42"))

        let card = try #require(MemosWireFormat.parseMemo(id: "rw-dsh-1", rawContent: raw, createdAt: Date()))
        #expect(card.sourcePlatform == "dsh")
        #expect(card.sourceURL == "dsh-session://sess-abc-42")
        #expect(card.sourceLocator == .dshSession(sessionID: "sess-abc-42"))

        let prompt = ConversationPrompt.buildPrompt(for: [card], language: .en)
        #expect(prompt.contains("dsh-session://sess-abc-42"))
    }

    @Test("DSHActionStore opens session on succeeded receipt and AppCoordinator falls back to copying session ID on failure")
    @MainActor
    func dshActionStoreAndCoordinatorSourceReopen() async throws {
        let root = try makeTestDir("dsh-actions")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try DSHActionStore(dataDirectoryURL: root)
        let responder = Task.detached {
            for _ in 0..<40 {
                let files = (try? FileManager.default.contentsOfDirectory(at: store.requestsDirectory, includingPropertiesForKeys: nil)) ?? []
                if let reqURL = files.first(where: { $0.pathExtension == "json" }),
                   let data = try? Data(contentsOf: reqURL),
                   let req = try? JSONDecoder().decode(DSHActionRequest.self, from: data) {
                    #expect(req.action == "openSession")
                    #expect(req.sessionId == "sess-live-99")
                    try? store.saveReceipt(DSHActionReceipt(
                        requestId: req.requestId,
                        state: .succeeded,
                        sessionId: req.sessionId,
                        updatedAtMs: Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
                    ))
                    return
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
        let ok = await store.openSession(sessionID: "sess-live-99", timeout: 2.0, pollInterval: .milliseconds(20))
        await responder.value
        #expect(ok)

        let timeoutOk = await store.openSession(sessionID: "sess-missing", timeout: 0.12, pollInterval: .milliseconds(20))
        #expect(!timeoutOk)

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true),
            dshHomeDirectoryURL: root.appendingPathComponent("DSHHome", isDirectory: true)
        )
        let shouldSucceed = OSAllocatedUnfairLock<Bool>(initialState: true)
        var activatedHosts: [ConversationHost] = []
        var copiedTexts: [String] = []
        let coord = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: DSHTestSelectionCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "test", appName: "Test")),
            dshActionRunner: { _ in shouldSucceed.withLock { $0 } }
        )
        coord.onActivateHostApp = { host in
            activatedHosts.append(host)
            return true
        }
        coord.onCopyText = { copiedTexts.append($0) }

        let dshCard = RewindCard(
            id: "rw-dsh-open",
            rawContent: "#rewind/ready #source/dsh\n\n> **Source:** [DSH](dsh-session://sess-jump-7) · 2026-11-19T00:00:00Z\n\nBody",
            status: .ready,
            sourcePlatform: "dsh",
            sourceTitle: "DSH",
            sourceURL: "dsh-session://sess-jump-7",
            verbatimText: "Body",
            createdAt: Date()
        )

        #expect(await coord.openSource(for: dshCard))
        #expect(activatedHosts == [.dsh])
        #expect(copiedTexts.isEmpty)
        #expect(coord.bannerMessage == L10n.banner(.openedDSHConversation, in: .zhHans))

        shouldSucceed.withLock { $0 = false }
        #expect(await coord.openSource(for: dshCard) == false)
        #expect(copiedTexts == ["sess-jump-7"])
        #expect(coord.bannerMessage == L10n.banner(.copiedDSHSessionFallback("sess-jump-7"), in: .zhHans))
    }

    @Test("DSHCaptureBridgeStore and AppCoordinator.captureExternalDSHRequest handle online sync, offline queue, and expired rejection")
    @MainActor
    func dshCaptureBridgeOnlineOfflineAndExpiry() async throws {
        let root = try makeTestDir("dsh-bridge")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true),
            dshHomeDirectoryURL: root.appendingPathComponent("DSHHome", isDirectory: true)
        )
        let store = try DSHCaptureBridgeStore(dataDirectoryURL: paths.dataDirectoryURL)
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())

        let expiredReq = DSHCaptureBridgeRequest(
            captureId: UUID().uuidString,
            text: "expired clip",
            sessionId: "sess-1",
            sessionTitle: "Expired",
            createdAtMs: nowMs - 60_000,
            expiresAtMs: nowMs - 1_000
        )
        try store.submit(expiredReq)
        #expect(try store.pendingRequests().isEmpty)
        #expect(try store.receipt(for: expiredReq.captureId)?.state == .failed)

        let offlineCoord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            capturer: DSHTestSelectionCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "test", appName: "Test"))
        )
        let offlineReq = DSHCaptureBridgeRequest(
            captureId: UUID().uuidString,
            text: "Offline pill excerpt from DSH",
            sessionId: "sess-offline-1",
            sessionTitle: "Offline Session",
            messages: [
                DSHSnapshotMessage(role: "user", text: "How does offline queue work?"),
                DSHSnapshotMessage(role: "assistant", text: "Offline pill excerpt from DSH is enqueued.")
            ],
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 30_000
        )
        try store.submit(offlineReq)
        let pendingOffline = try store.pendingRequests()
        #expect(pendingOffline.count == 1)
        let offlineReceipt = await offlineCoord.captureExternalDSHRequest(pendingOffline[0])
        try store.consumeAndRecordReceipt(offlineReceipt)
        #expect(offlineReceipt.state == .queuedOffline)
        #expect(offlineReceipt.clipId != nil)
        #expect(try store.receipt(for: offlineReq.captureId)?.state == .queuedOffline)
        #expect(try store.pendingRequests().isEmpty)
        #expect(offlineCoord.cards.first?.sourcePlatform == "dsh")
        #expect(offlineCoord.cards.first?.sourceURL == "dsh-session://sess-offline-1")
        #expect(offlineCoord.outbox.loadEntries().first?.commentContent?.contains("How does offline queue work?") == true)

        DSHCaptureMockURLProtocol.state.withLock { $0 = .init() }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DSHCaptureMockURLProtocol.self]
        let onlinePaths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("OnlineData", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("OnlineConfig", isDirectory: true),
            dshHomeDirectoryURL: root.appendingPathComponent("OnlineDSHHome", isDirectory: true)
        )
        let onlineCoord = try AppCoordinator(
            paths: onlinePaths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://dsh-capture.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "tok-dsh"
            ],
            memosClient: MemosClient(session: URLSession(configuration: sessionConfig)),
            capturer: DSHTestSelectionCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "test", appName: "Test"))
        )
        let onlineReq = DSHCaptureBridgeRequest(
            captureId: UUID().uuidString,
            text: "Online synced snippet",
            sessionId: "sess-online-2",
            sessionTitle: "Online Session",
            messages: [
                DSHSnapshotMessage(role: "user", text: "Explain the online sync contract."),
                DSHSnapshotMessage(role: "assistant", text: "Online synced snippet goes to Memos.")
            ],
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 30_000
        )
        let onlineReceipt = await onlineCoord.captureExternalDSHRequest(onlineReq)
        #expect(onlineReceipt.state == .saved)
        #expect(onlineReceipt.clipId == "rw-dsh-server-1")
        let capturedMemo = DSHCaptureMockURLProtocol.state.withLock { $0.createdMemoContent }
        let capturedComment = DSHCaptureMockURLProtocol.state.withLock { $0.createdCommentContent }
        #expect(capturedMemo?.contains("#source/dsh") == true)
        #expect(capturedMemo?.contains("dsh-session://sess-online-2") == true)
        #expect(capturedComment?.contains("Explain the online sync contract.") == true)
    }

    @Test("Legacy conversation-host.json storing 'codex' migrates to .dsh on startup and persists 'dsh'")
    @MainActor
    func legacyCodexHostMigratesToDSHOnStartup() throws {
        let root = try makeTestDir("dsh-migrate")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let hostURL = paths.dataDirectoryURL.appendingPathComponent("conversation-host.json")
        try AtomicFile.writeUTF8("\"codex\"", to: hostURL, permissions: 0o600)

        let decodedDirectly = try JSONDecoder().decode(ConversationHost.self, from: Data("\"codex\"".utf8))
        #expect(decodedDirectly == .dsh)

        let coord = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: DSHTestSelectionCapturer(selection: CapturedSelection(text: "x", bundleIdentifier: "test", appName: "Test"))
        )
        #expect(coord.conversationHost == .dsh)
        let migratedRaw = try String(contentsOf: hostURL, encoding: .utf8)
        #expect(migratedRaw == "\"dsh\"")
    }

    @Test("Hotkey captureSelection from com.deepseek.dsh enriches #source/dsh via dsh-active-session.json")
    @MainActor
    func hotkeyCaptureFromDSHUsesActiveSessionSnapshot() async throws {
        let root = try makeTestDir("dsh-hotkey")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let now = Date()
        let snapshot = DSHActiveSessionSnapshot(
            version: 1,
            sessionId: "sess-hotkey-42",
            sessionTitle: "DSH Debugging Session",
            updatedAtMs: Int64((now.timeIntervalSince1970 * 1000.0).rounded()),
            messages: [
                DSHSnapshotMessage(role: "user", text: "Why does Electron AX return empty?"),
                DSHSnapshotMessage(role: "assistant", text: "Fallback to pasteboard-preserving Cmd+C captures cleanly.")
            ]
        )
        try AtomicFile.writeData(
            JSONEncoder().encode(snapshot),
            to: paths.dshActiveSessionFileURL,
            permissions: 0o600
        )

        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            capturer: DSHTestSelectionCapturer(selection: CapturedSelection(
                text: "Fallback to pasteboard-preserving Cmd+C captures cleanly.",
                bundleIdentifier: CapturedSelection.dshBundleIdentifier,
                appName: "DeepSeek Harness",
                windowTitle: "DeepSeek Harness",
                capturedAt: now
            ))
        )

        let outcome = await coord.captureSelection()
        if case .queuedOffline = outcome {} else {
            Issue.record("Expected offline queue outcome")
        }
        let card = try #require(coord.cards.first)
        #expect(card.sourcePlatform == "dsh")
        #expect(card.sourceTitle == "DSH Debugging Session")
        #expect(card.sourceURL == "dsh-session://sess-hotkey-42")
        #expect(card.sourceLocator == .dshSession(sessionID: "sess-hotkey-42"))
        #expect(coord.outbox.loadEntries().first?.commentContent?.contains("Why does Electron AX return empty?") == true)
    }
}

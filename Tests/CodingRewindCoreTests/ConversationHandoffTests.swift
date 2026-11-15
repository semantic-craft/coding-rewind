// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation
import Testing

@Suite("Official sidecar handoff")
struct ConversationHandoffTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/handoff-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A duplicate submission and worker pass dispatch the original prompt exactly once", arguments: ConversationHost.allCases)
    func duplicateAndPrivacy(host: ConversationHost) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root, host: host)
        let prompt = "汉字 e\u{301}\n`literal` $(touch never) \"quote\""
        let current = try store.submit(prompt: prompt, cardIDs: ["memo"], markSynthesized: true)
        #expect(try store.submit(prompt: "different", cardIDs: ["other"], markSynthesized: false) == current)
        #expect(try store.current() == current)
        let worker = try ConversationSidecarWorker(store: store)
        #expect(throws: RewindError.self) { try ConversationSidecarWorker(store: store) }
        var count = 0
        let conversationID = UUID().uuidString
        try worker.processPending { received in
            #expect(received.prompt == prompt)
            #expect((try? store.receipt(for: current.requestId))?.state == .dispatching)
            count += 1
            return (.succeeded, conversationID)
        }
        try worker.processPending { _ in count += 1; return (.unknown, nil) }
        #expect(count == 1)
        #expect(try store.pendingRequests().isEmpty)
        #expect(try store.receipt(for: current.requestId)?.conversationId == conversationID)
        let receiptURL = store.directory.appendingPathComponent("receipts/" + current.requestId.uuidString + ".json")
        let text = try String(contentsOf: receiptURL, encoding: .utf8)
        #expect(!text.contains("prompt"))
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
    }

    @Test("Restart converts dispatching to unknown and never resends", arguments: ConversationHost.allCases)
    func crashRecovery(host: ConversationHost) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root, host: host)
        let current = try store.submit(prompt: "sensitive", cardIDs: ["memo"], markSynthesized: false)
        try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .dispatching))
        let worker = try ConversationSidecarWorker(store: store)
        try worker.processPending { _ in Issue.record("Must not resend after a crash"); return (.succeeded, UUID().uuidString) }
        #expect(try store.receipt(for: current.requestId)?.state == .unknown)
        #expect(try store.pendingRequests().isEmpty)
        #expect(try store.current()?.requestId == current.requestId)
    }

    @Test("The legacy Antigravity worker cannot consume Codex requests")
    func hostIsolation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try ConversationHandoffStore(dataDirectoryURL: root)
        let codex = try ConversationHandoffStore(dataDirectoryURL: root, host: .codex)
        let current = try codex.submit(prompt: "Codex only", cardIDs: ["memo"], markSynthesized: false)
        let worker = try ConversationSidecarWorker(store: legacy)
        try worker.processPending { _ in
            Issue.record("Legacy worker must not claim Codex work")
            return (.unknown, nil)
        }
        #expect(legacy.directory.lastPathComponent == "handoff")
        #expect(try legacy.pendingRequests().isEmpty)
        #expect(try codex.pendingRequests().map(\.requestId) == [current.requestId])
        #expect(try codex.receipt(for: current.requestId) == nil)
    }

    @Test("Expired requests and old receipts discard prompts without dispatch")
    func expirationAndRetention() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root)
        let current = try store.submit(prompt: "expired", cardIDs: ["memo"], markSynthesized: false, now: Date().addingTimeInterval(-121))
        let worker = try ConversationSidecarWorker(store: store)
        try worker.processPending { _ in Issue.record("Expired request must not dispatch"); return (.unknown, nil) }
        #expect(try store.receipt(for: current.requestId)?.state == .expired)
        #expect(try store.pendingRequests().isEmpty)
        try store.clearCurrent()
        let completed = try store.submit(prompt: "completed", cardIDs: ["memo"], markSynthesized: false)
        try store.saveReceipt(ConversationReceipt(requestId: completed.requestId, state: .succeeded, updatedAt: Date().addingTimeInterval(-8 * 86400), conversationId: UUID().uuidString))
        try store.recover()
        #expect(try store.pendingRequests().isEmpty)
        #expect(try store.receipt(for: completed.requestId)?.state == .succeeded)
        try store.clearCurrent()
        try store.recover()
        #expect(try store.receipt(for: completed.requestId) == nil)
    }

    @Test("Request lifetime outlives the 40-second delivery window so a 35-second in-flight request still dispatches")
    func lifetimeCoversDeliveryWindow() async throws {
        #expect(ConversationRequest.lifetime == 45)
        #expect(ConversationRequest.lifetime > 40)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root, host: .codex)
        let submittedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let inFlight = try store.submit(prompt: "35s in-flight prompt", cardIDs: ["memo"], markSynthesized: false, now: submittedAt)
        let worker = try ConversationSidecarWorker(store: store)
        let expectedID = UUID().uuidString
        var dispatchedPrompts: [String] = []
        try await worker.processPending(now: submittedAt.addingTimeInterval(35)) { request in
            await Task.yield()
            #expect((try? store.receipt(for: inFlight.requestId))?.state == .dispatching)
            dispatchedPrompts.append(request.prompt)
            return (.succeeded, expectedID)
        }
        #expect(dispatchedPrompts == ["35s in-flight prompt"])
        #expect(try store.receipt(for: inFlight.requestId)?.state == .succeeded)
        #expect(try store.receipt(for: inFlight.requestId)?.conversationId == expectedID)
        #expect(try store.pendingRequests().isEmpty)

        try store.clearCurrent(requestId: inFlight.requestId)
        let pastLifetime = try store.submit(prompt: "46s expired prompt", cardIDs: ["memo"], markSynthesized: false, now: submittedAt)
        try await worker.processPending(now: submittedAt.addingTimeInterval(46)) { _ in
            await Task.yield()
            Issue.record("Request past 45s lifetime must expire without dispatch")
            return (.unknown, nil)
        }
        #expect(try store.receipt(for: pastLifetime.requestId)?.state == .expired)
        #expect(try store.pendingRequests().isEmpty)
    }

    @Test("A crash between saving current and publishing the request expires without resending")
    func unpublishedCurrentRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root)
        let current = try store.submit(prompt: "unpublished", cardIDs: ["memo"], markSynthesized: false)
        try store.removeRequest(current.requestId)
        let worker = try ConversationSidecarWorker(store: store)
        try worker.processPending(now: current.expiresAt.addingTimeInterval(1)) { _ in
            Issue.record("Unpublished request must not be retried")
            return (.unknown, nil)
        }
        #expect(try store.receipt(for: current.requestId)?.state == .expired)
        #expect(try store.pendingRequests().isEmpty)
    }

    @Test("Symlink requests, symlink directories and oversize prompts cannot cross the private boundary")
    func unsafeFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root)
        #expect(throws: RewindError.self) { try store.submit(prompt: String(repeating: "x", count: ConversationHandoffStore.maximumPromptBytes + 1), cardIDs: [], markSynthesized: false) }
        let victim = root.appendingPathComponent("victim.json")
        try AtomicFile.writeUTF8("sensitive victim", to: victim)
        let linkedRequest = store.directory.appendingPathComponent("requests/" + UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: linkedRequest, withDestinationURL: victim)
        #expect(throws: RewindError.self) { try store.pendingRequests() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "sensitive victim")
        let linkedRoot = root.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        #expect(throws: RewindError.self) { try ConversationHandoffStore(dataDirectoryURL: linkedRoot) }
    }

    @Test("Official CLI receives an unmodified argument and only a structured conversation ID confirms success")
    func processBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentapi")
        let argvURL = root.appendingPathComponent("argv.json")
        let id = UUID().uuidString
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time
        with open(os.environ['ARGV_FILE'], 'w') as stream:
            json.dump(sys.argv[1:], stream)
        if os.environ.get('SLOW'):
            time.sleep(5)
        if os.environ.get('BAD'):
            print('not a receipt')
            sys.exit(1)
        print(json.dumps({'response': {'newConversation': {'prompt': sys.argv[2], 'conversationId': '\(id)'}}}))
        """
        try AtomicFile.writeUTF8(script + "\n", to: binary, permissions: 0o755)
        let prompt = "原文\n$(literal) `literal` \"quote\""
        let environment = ["PATH": root.path + ":/usr/bin:/bin", "ARGV_FILE": argvURL.path]
        let result = SidecarAgentAPI.invoke(prompt: prompt, environment: environment)
        #expect(result.0 == .succeeded)
        #expect(result.1 == id)
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: argvURL)) == ["new-conversation", prompt])
        #expect(SidecarAgentAPI.invoke(prompt: prompt, environment: environment.merging(["BAD": "1"]) { _, new in new }).0 == .unknown)
        #expect(SidecarAgentAPI.invoke(prompt: prompt, environment: environment.merging(["SLOW": "1"]) { _, new in new }, timeout: 0.05).0 == .unknown)
        #expect(SidecarAgentAPI.invoke(prompt: prompt, environment: ["PATH": root.appendingPathComponent("absent").path]).0 == .rejected)
    }

    @Test("acquireIfUnlocked returns nil on contention, throws on symlink worker.lock, and evaluates fresh timestamps per batch item")
    func nonBlockingLockAndFreshBatchTimestamps() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationHandoffStore(dataDirectoryURL: root, host: .codex)

        do {
            let first = try #require(try ConversationSidecarWorker.acquireIfUnlocked(store: store))
            #expect(try ConversationSidecarWorker.acquireIfUnlocked(store: store) == nil)
            _ = first
        }
        #expect(try ConversationSidecarWorker.acquireIfUnlocked(store: store) != nil)

        let symlinkRoot = try directory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let unsafeStore = try ConversationHandoffStore(dataDirectoryURL: symlinkRoot, host: .codex)
        let victim = symlinkRoot.appendingPathComponent("victim-lock")
        try AtomicFile.writeUTF8("x", to: victim)
        try FileManager.default.createSymbolicLink(
            at: unsafeStore.directory.appendingPathComponent("worker.lock"),
            withDestinationURL: victim
        )
        #expect(throws: RewindError.self) {
            _ = try ConversationSidecarWorker.acquireIfUnlocked(store: unsafeStore)
        }

        let batchRoot = try directory()
        defer { try? FileManager.default.removeItem(at: batchRoot) }
        let batchStore = try ConversationHandoffStore(dataDirectoryURL: batchRoot, host: .codex)
        let baseNow = Date()
        let firstCreated = baseNow.addingTimeInterval(-(ConversationRequest.lifetime - 0.20))
        let secondCreated = baseNow.addingTimeInterval(-(ConversationRequest.lifetime - 0.25))
        let firstReq = ConversationRequest(prompt: "first", now: firstCreated)
        let secondReq = ConversationRequest(prompt: "second", now: secondCreated)
        let encoder = JSONEncoder()
        try AtomicFile.writeData(
            encoder.encode(firstReq),
            to: batchStore.directory.appendingPathComponent("requests/\(firstReq.requestId.uuidString).json"),
            permissions: 0o600
        )
        try AtomicFile.writeData(
            encoder.encode(secondReq),
            to: batchStore.directory.appendingPathComponent("requests/\(secondReq.requestId.uuidString).json"),
            permissions: 0o600
        )

        let worker = try ConversationSidecarWorker(store: batchStore)
        var invokedIDs: [UUID] = []
        try await worker.processPending { req in
            invokedIDs.append(req.requestId)
            try? await Task.sleep(for: .milliseconds(350))
            return (.succeeded, UUID().uuidString)
        }
        #expect(invokedIDs == [firstReq.requestId])
        #expect(try batchStore.receipt(for: firstReq.requestId)?.state == .succeeded)
        #expect(try batchStore.receipt(for: secondReq.requestId)?.state == .expired)
    }
}

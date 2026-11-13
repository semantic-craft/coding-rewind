// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation
import Testing

@Suite("Codex receipt verification")
struct CodexConversationClientTests {
    @Test("Only a real matching first user turn confirms delivery", arguments: ["success", "changed-text", "wrong-client", "queue-only", "disconnect-after-queue"])
    func verifyDelivery(mode: String) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("dist/test-data/codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        try Data(#"{"processes":0,"methods":[],"queueCalls":0,"pids":[]}"#.utf8).write(to: stateURL)
        let fixture = repository.appendingPathComponent("Tests/Support/CodexAppServerFixture/main.py")
        let request = ConversationRequest(prompt: "中文 e\u{301}\n```swift\nlet x = 1\n\nprint(x)\n```\n\"quoted\" $(literal)")
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_FIXTURE_STATE"] = stateURL.path
        environment["CODEX_FIXTURE_MODE"] = mode
        let client = CodexConversationClient(binaryURL: fixture, environment: environment, timeout: 2) { _ in
            do {
                guard var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any] else { return false }
                state["woken"] = true
                try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
                return true
            } catch { Issue.record(error); return false }
        }
        let (result, threadID) = client.deliver(request)
        #expect(result == (mode == "success" ? .succeeded : .unknown))
        #expect(threadID == (mode == "success" ? "01a1d60a-b26a-7930-b8c8-e312607a60ea" : nil))
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        #expect(state["queueCalls"] as? Int == 1)
        #expect(state["clientId"] as? String == request.requestId.uuidString.lowercased())
        #expect((state["prompt"] as? String)?.utf8.elementsEqual(request.prompt.utf8) == true)
        let methods = try #require(state["methods"] as? [String])
        #expect(methods.filter { $0 == "thread/start" }.count == 1)
        #expect(!methods.contains("turn/start"))
        #expect(!methods.contains("thread/resume"))
        let pids = try #require(state["pids"] as? [Int32])
        for pid in pids { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("An unavailable executable rejects before creating a thread")
    func missingBinary() {
        let client = CodexConversationClient(binaryURL: URL(fileURLWithPath: "/nonexistent/coding-rewind-codex"), environment: [:]) { _ in
            Issue.record("A missing executable cannot wake a thread")
            return false
        }
        #expect(client.deliver(ConversationRequest(prompt: "private")).0 == .rejected)
    }
}

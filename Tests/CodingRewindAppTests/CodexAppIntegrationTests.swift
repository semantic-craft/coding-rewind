// SPDX-License-Identifier: MIT

import CodingRewindApp
import CodingRewindCore
import Foundation
import Testing

@MainActor
struct CodexAppIntegrationTests {
    @Test("A configured missing CLI does not fall through to a different installation")
    func explicitBinaryIsAuthoritative() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/codex-discovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let appURL = root.appendingPathComponent("Codex.app")
        #expect(CodexAppIntegration.delivery(environment: [:], applicationURL: appURL, homeDirectory: root) != nil)
        #expect(CodexAppIntegration.delivery(environment: ["CODING_REWIND_CODEX_BIN": root.appendingPathComponent("missing").path], applicationURL: appURL, homeDirectory: root) == nil)
        #expect(CodexAppIntegration.delivery(environment: ["CODING_REWIND_CODEX_BIN": "relative/codex"], applicationURL: appURL, homeDirectory: root) == nil)
    }

    @Test("Delivery merges caller environment overrides while stripping all CODING_REWIND_ keys")
    func deliveryPropagatesCallerEnvironmentWithoutSecrets() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/codex-env-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dumpFile = root.appendingPathComponent("env.json")
        let fakeCodex = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        with open(\(String(reflecting: dumpFile.path)), "w", encoding="utf-8") as fh:
            json.dump(dict(os.environ), fh)
        sys.exit(1)
        """
        try AtomicFile.writeUTF8(script + "\n", to: fakeCodex, permissions: 0o755)

        let deliver = try #require(CodexAppIntegration.delivery(
            environment: [
                "CODING_REWIND_CODEX_BIN": fakeCodex.path,
                "CODING_REWIND_MEMOS_TOKEN": "secret-token-must-not-leak",
                "CUSTOM_CODEX_OVERRIDE": "expected-value"
            ],
            applicationURL: nil,
            homeDirectory: root
        ))
        let outcome = await deliver(ConversationRequest(prompt: "env check"))
        #expect(outcome.0 == .rejected)
        let recorded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dumpFile))
        #expect(recorded["CUSTOM_CODEX_OVERRIDE"] == "expected-value")
        #expect(recorded.keys.allSatisfy { !$0.hasPrefix("CODING_REWIND_") })
    }
}

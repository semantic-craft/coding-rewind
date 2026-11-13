// SPDX-License-Identifier: MIT

import CodingRewindApp
import Foundation
import Testing

@MainActor
struct CodexAppIntegrationTests {
    @Test("A configured missing CLI does not fall through to a different installation")
    func explicitBinaryIsAuthoritative() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/test-data/codex-discovery-" + UUID().uuidString)
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
}

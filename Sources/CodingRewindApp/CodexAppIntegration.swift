// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation

@MainActor
public enum CodexAppIntegration {
    public static func delivery(
        environment: [String: String],
        applicationURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (@Sendable (ConversationRequest) -> (ConversationReceipt.State, String?))? {
        let binary: URL?
        if let configured = environment["CODING_REWIND_CODEX_BIN"] {
            let candidate = URL(fileURLWithPath: configured)
            binary = configured.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        } else {
            binary = [
                applicationURL?.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                homeDirectory.appendingPathComponent(".local/bin/codex")
            ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        guard let binary else { return nil }
        let childEnvironment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CODING_REWIND_") }
        let client = CodexConversationClient(binaryURL: binary, environment: childEnvironment) { threadID in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let url = URL(string: "codex://threads/wake/\(threadID.uuidString.lowercased())") else { return false }
                    return NSWorkspace.shared.open(url)
                }
            }
        }
        return { client.deliver($0) }
    }
}

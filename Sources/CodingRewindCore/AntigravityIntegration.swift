// SPDX-License-Identifier: MIT
// Stable binary staging into Application Support/CodingRewind/bin/ adapted from wxtsky/CodeIsland (MIT).

import Darwin
import Foundation

public enum AntigravityIntegration {
    public static let pluginName = "coding-rewind"
    public static let pluginVersion = "0.2.0"

    public enum Status: Equatable, Sendable {
        case installed(pluginDirectoryURL: URL, hookBinaryURL: URL)
        case needsInstallOrRepair(reasons: [String])
    }

    public static func stableHookBinaryURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("coding-rewind-hook", isDirectory: false)
    }

    public static func stableMCPBridgeURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("memos-mcp-bridge.sh", isDirectory: false)
    }

    public static func hookCommandString(for executableURL: URL) -> String {
        let path = executableURL.standardizedFileURL.path
        if path.contains(" ") {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }

    @discardableResult
    public static func installOrRepair(
        dataDirectoryURL: URL,
        configDirectoryURL: URL,
        sourceHookBinaryURL: URL? = nil,
        sourceMCPBridgeURL: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        let binDir = resolvedData.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let destHook = stableHookBinaryURL(in: resolvedData)
        guard !destHook.path.contains("/.build/") else {
            throw RewindError.ioError("Refusing to install hook inside transient .build/ path")
        }

        if let srcHook = sourceHookBinaryURL?.standardizedFileURL,
           srcHook != destHook,
           fm.fileExists(atPath: srcHook.path) {
            let binData = try Data(contentsOf: srcHook)
            try AtomicFile.writeData(binData, to: destHook, permissions: 0o755)
            _ = chmod(destHook.path, 0o755)
        }

        if let srcBridge = sourceMCPBridgeURL?.standardizedFileURL,
           fm.fileExists(atPath: srcBridge.path) {
            let destBridge = stableMCPBridgeURL(in: resolvedData)
            if srcBridge != destBridge {
                let bridgeData = try Data(contentsOf: srcBridge)
                try AtomicFile.writeData(bridgeData, to: destBridge, permissions: 0o755)
                _ = chmod(destBridge.path, 0o755)
            }
        }

        let pluginDir = resolvedConfig
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let skillDir = pluginDir
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("rewind", isDirectory: true)
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)

        for legacyRel in ["mcp_config.json", "bin"] {
            let legacyURL = pluginDir.appendingPathComponent(legacyRel)
            if fm.fileExists(atPath: legacyURL.path) {
                try? fm.removeItem(at: legacyURL)
            }
        }

        let pluginManifest: [String: Any] = [
            "name": pluginName,
            "version": pluginVersion,
            "description": "Coding Rewind 72-hour hot-window context stash and Memos bridge for Antigravity 2.x.",
            "suggestedPrompts": [
                "/rewind 列出我最近 72 小时暂存的灵感卡片并梳理核心脉络",
                "/rewind 检索我近期定锚的技术讨论片段并附上原对话出处",
                "/rewind 将我最近暂存的 Rewind 卡片串联成结构化初稿"
            ]
        ]
        let pluginData = try JSONSerialization.data(
            withJSONObject: pluginManifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFile.writeData(
            pluginData,
            to: pluginDir.appendingPathComponent("plugin.json", isDirectory: false),
            permissions: 0o644
        )

        let handler: [String: Any] = [
            "type": "command",
            "command": hookCommandString(for: destHook),
            "timeout": 5
        ]
        let hooksPayload: [String: Any] = [
            pluginName: [
                "PostInvocation": [handler],
                "Stop": [handler]
            ]
        ]
        let hooksData = try JSONSerialization.data(
            withJSONObject: hooksPayload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFile.writeData(
            hooksData,
            to: pluginDir.appendingPathComponent("hooks.json", isDirectory: false),
            permissions: 0o644
        )

        let skillMarkdown = """
        ---
        name: rewind
        description: Query and synthesize recent 72-hour Coding Rewind highlights stored in Memos with full conversation provenance.
        ---

        # Coding Rewind (/rewind)

        Use the configured Memos MCP tools to inspect, synthesize, and update `#rewind/` cards:

        1. Call `memo_list_memos` to list recent memos and filter to entries tagged `#rewind/ready` or `#rewind/pending` within the 72-hour hot window (skip `#rewind/synthesized` unless requested).
        2. Call `memo_get_memo` and `memo_list_memo_comments` when inspecting a specific `memos/<id>` card; preserve verbatim body text unmodified and read the `> **Title:**`, `> **Session:**`, `> **Context:**`, and `> **Source:**` blockquote headers.
        3. Always cite original provenance links (`[出处](conversation://<id>)` or web chat URLs) when referencing or quoting a highlight.
        4. Use `memo_create_memo` to store new synthesized notes when requested, or `memo_update_memo` (`updateMask: content`) to replace `#rewind/ready` / `#rewind/pending` with `#rewind/synthesized` once cards are incorporated.
        """
        try AtomicFile.writeUTF8(
            skillMarkdown + "\n",
            to: skillDir.appendingPathComponent("SKILL.md", isDirectory: false),
            permissions: 0o644
        )
        return pluginDir
    }

    public static func verify(
        dataDirectoryURL: URL,
        configDirectoryURL: URL
    ) -> Status {
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let pluginDir = configDirectoryURL.standardizedFileURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let pluginJSONURL = pluginDir.appendingPathComponent("plugin.json", isDirectory: false)
        let hooksJSONURL = pluginDir.appendingPathComponent("hooks.json", isDirectory: false)
        let skillURL = pluginDir.appendingPathComponent("skills/rewind/SKILL.md", isDirectory: false)
        let expectedHookURL = stableHookBinaryURL(in: resolvedData)
        let expectedCmd = hookCommandString(for: expectedHookURL)

        var reasons: [String] = []
        let allowedPluginKeys: Set<String> = ["name", "version", "description", "suggestedPrompts"]

        if let pData = try? Data(contentsOf: pluginJSONURL),
           let pObj = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] {
            if !Set(pObj.keys).isSubset(of: allowedPluginKeys) {
                reasons.append("plugin.json contains unsupported fields")
            }
            if pObj["name"] as? String != pluginName {
                reasons.append("plugin.json name mismatch")
            }
            if pObj["version"] as? String != pluginVersion {
                reasons.append("plugin.json version mismatch")
            }
            if let prompts = pObj["suggestedPrompts"] as? [String], prompts.count == 3, prompts.allSatisfy({ !$0.isEmpty }) {
            } else {
                reasons.append("plugin.json suggestedPrompts must be 3 non-empty strings")
            }
        } else {
            reasons.append("plugin.json missing or invalid")
        }

        if let hData = try? Data(contentsOf: hooksJSONURL),
           let hRoot = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
           let group = hRoot[pluginName] as? [String: Any] {
            for event in ["PostInvocation", "Stop"] {
                if let list = group[event] as? [[String: Any]], let first = list.first {
                    if first["hooks"] != nil || first["matcher"] != nil {
                        reasons.append("hooks.json \(event) must be a flat handler array")
                    }
                    if first["type"] as? String != "command" {
                        reasons.append("hooks.json \(event) missing type=command")
                    }
                    if (first["timeout"] as? Int) != 5 {
                        reasons.append("hooks.json \(event) timeout must be 5")
                    }
                    let cmd = first["command"] as? String ?? ""
                    if cmd != expectedCmd || cmd.contains("/.build/") {
                        reasons.append("hooks.json \(event) command mismatch")
                    }
                } else {
                    reasons.append("hooks.json missing \(event)")
                }
            }
        } else {
            reasons.append("hooks.json missing or invalid")
        }

        if let skillText = try? String(contentsOf: skillURL, encoding: .utf8) {
            if !skillText.contains("memo_list_memos") || !skillText.contains("conversation://") {
                reasons.append("SKILL.md missing Memos MCP guidance")
            }
        } else {
            reasons.append("skills/rewind/SKILL.md missing")
        }

        return reasons.isEmpty
            ? .installed(pluginDirectoryURL: pluginDir, hookBinaryURL: expectedHookURL)
            : .needsInstallOrRepair(reasons: reasons)
    }
}

public enum AntigravityLauncher {
    public static let agentAPIEnvironmentKey = "CODING_REWIND_AGENTAPI_BIN"
    public static let defaultBundledAgentAPIPath = "/Applications/Antigravity.app/Contents/Resources/app/bin/agentapi"

    public enum LaunchOutcome: Equatable, Sendable {
        case launchedViaAgentAPI(binaryURL: URL, prompt: String)
        case copiedToClipboardFallback(prompt: String)
    }

    public static func buildPrompt(for cards: [RewindCard]) -> String {
        var sections: [String] = [
            "请围绕以下我在 Coding Rewind 暂存的灵感卡片展开分析与写作推演，保留关键原文论据并在引用处附上出处链接："
        ]
        for (index, card) in cards.enumerated() {
            var lines: [String] = []
            let heading = card.title ?? card.sourceTitle
            lines.append("### 卡片 \(index + 1)：\(heading)")
            if let session = card.sessionTopic, !session.isEmpty {
                lines.append("- 会话主题：\(session)")
            }
            if let ctx = card.contextSummary, !ctx.isEmpty {
                lines.append("- 上下文脉络：\(ctx)")
            }
            if let url = card.sourceURL, !url.isEmpty {
                lines.append("- 原文出处：[出处](\(url))（\(card.sourceTitle)）")
            } else {
                lines.append("- 原文出处：\(card.sourceTitle)")
            }
            lines.append("")
            let quoted = card.verbatimText
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            lines.append(quoted)
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    public static func resolveAgentAPIBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultAppBinaryPath: String = defaultBundledAgentAPIPath
    ) -> URL? {
        let fm = FileManager.default
        if let explicit = environment[agentAPIEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                    .appendingPathComponent("agentapi", isDirectory: false)
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
            }
        }
        if fm.isExecutableFile(atPath: defaultAppBinaryPath) {
            return URL(fileURLWithPath: defaultAppBinaryPath).standardizedFileURL
        }
        return nil
    }

    public static func launchConversation(
        cards: [RewindCard],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultAppBinaryPath: String = defaultBundledAgentAPIPath,
        copyToClipboard: (String) -> Void,
        openAntigravityApp: () -> Void
    ) -> LaunchOutcome {
        let prompt = buildPrompt(for: cards)
        if let binURL = resolveAgentAPIBinary(environment: environment, defaultAppBinaryPath: defaultAppBinaryPath) {
            let process = Process()
            process.executableURL = binURL
            process.arguments = ["new-conversation", prompt]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return .launchedViaAgentAPI(binaryURL: binURL, prompt: prompt)
                }
            } catch {
            }
        }
        copyToClipboard(prompt)
        openAntigravityApp()
        return .copiedToClipboardFallback(prompt: prompt)
    }
}

// SPDX-License-Identifier: MIT
// Stable binary staging into Application Support/CodingRewind/bin/ adapted from wxtsky/CodeIsland (MIT).

import Darwin
import Foundation

public enum AntigravityIntegration {
    public static let pluginName = "coding-rewind"
    public static let pluginVersion = "0.2.0"

    public enum Status: Equatable, Sendable {
        case installed(pluginDirectoryURL: URL)
        case needsInstallOrRepair(reasons: [String])
    }

    public static func stableSidecarBinaryURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL.appendingPathComponent("bin/coding-rewind-sidecar")
    }

    public static func stableMCPBridgeURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("memos-mcp-bridge.sh", isDirectory: false)
    }

    public static func suggestedPrompts(in language: AppLanguage = .zhHans) -> [String] {
        L10n.suggestedPrompts(in: language)
    }

    @discardableResult
    public static func installOrRepair(
        dataDirectoryURL: URL,
        configDirectoryURL: URL,
        sourceMCPBridgeURL: URL? = nil,
        sourceSidecarBinaryURL: URL? = nil,
        language: AppLanguage = .zhHans
    ) throws -> URL {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        let binDir = resolvedData.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let retiredActiveTurn = resolvedData.appendingPathComponent("active_turn.json")
        if fm.fileExists(atPath: retiredActiveTurn.path) {
            try? fm.removeItem(at: retiredActiveTurn)
        }
        let retiredHook = binDir.appendingPathComponent("coding-rewind-hook")
        if fm.fileExists(atPath: retiredHook.path) {
            try? fm.removeItem(at: retiredHook)
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

        let destSidecar = stableSidecarBinaryURL(in: resolvedData)
        guard !destSidecar.path.contains("/.build/") else {
            throw RewindError.ioError("Refusing to install sidecar inside transient .build/ path")
        }
        if let source = sourceSidecarBinaryURL?.standardizedFileURL, source != destSidecar,
           fm.isExecutableFile(atPath: source.path) {
            try AtomicFile.writeData(Data(contentsOf: source), to: destSidecar, permissions: 0o755)
        }
        guard fm.isExecutableFile(atPath: destSidecar.path) else {
            let detail = language == .en
                ? "Missing coding-rewind-sidecar; install the plugin from a packaged app bundle"
                : "缺少 coding-rewind-sidecar，请用完整应用包安装插件"
            throw RewindError.ioError(detail)
        }
        _ = try ConversationHandoffStore(dataDirectoryURL: resolvedData)

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
            "suggestedPrompts": suggestedPrompts(in: language)
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
        let sidecarDirectory = pluginDir.appendingPathComponent("sidecars/launcher", isDirectory: true)
        try fm.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        let sidecar: [String: Any] = [
            "command": destSidecar.path,
            "args": ["--data-dir", resolvedData.path],
            "restart_policy": "always",
            "display_name": "Coding Rewind"
        ]
        try AtomicFile.writeData(JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]), to: sidecarDirectory.appendingPathComponent("sidecar.json"))
        let configURL = resolvedConfig.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        if fm.fileExists(atPath: configURL.path) {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else {
                let detail = language == .en
                    ? "Antigravity config.json must be a JSON object; configuration left unchanged"
                    : "Antigravity config.json 必须是 JSON 对象，未改写配置"
                throw RewindError.ioError(detail)
            }
            config = decoded
        }
        guard config["sidecars"] == nil || config["sidecars"] is [String: Any] else {
            let detail = language == .en
                ? "Invalid Antigravity sidecars configuration type; configuration left unchanged"
                : "Antigravity sidecars 配置类型无效，未改写配置"
            throw RewindError.ioError(detail)
        }
        var sidecars = config["sidecars"] as? [String: Any] ?? [:]
        guard sidecars["coding-rewind/launcher"] == nil || sidecars["coding-rewind/launcher"] is [String: Any] else {
            let detail = language == .en
                ? "Invalid Antigravity launcher configuration type; configuration left unchanged"
                : "Antigravity launcher 配置类型无效，未改写配置"
            throw RewindError.ioError(detail)
        }
        var launcher = sidecars["coding-rewind/launcher"] as? [String: Any] ?? [:]
        launcher["enabled"] = true
        sidecars["coding-rewind/launcher"] = launcher
        config["sidecars"] = sidecars
        try AtomicFile.writeData(JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: configURL)
        let hooksURL = pluginDir.appendingPathComponent("hooks.json")
        if let migrated = hooksWithoutLegacyCapture(at: hooksURL, dataDirectory: resolvedData) {
            try AtomicFile.writeData(
                JSONSerialization.data(withJSONObject: migrated, options: [.prettyPrinted, .sortedKeys]),
                to: hooksURL,
                permissions: 0o644
            )
        }
        return pluginDir
    }

    private static func hooksWithoutLegacyCapture(at url: URL, dataDirectory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var group = root[pluginName] as? [String: Any] else { return nil }

        func quoted(_ value: String) -> String {
            "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        let environment = quoted("CODING_REWIND_DATA_DIR=\(dataDirectory.path)")
        let path = dataDirectory.appendingPathComponent("bin/coding-rewind-hook").path
        let executable = quoted(path)
        let commands: Set<String> = [
            "/usr/bin/env \(environment) \(executable)",
            path.contains(" ") ? executable : path
        ]
        var changed = false
        for event in ["PostInvocation", "Stop"] {
            guard let handlers = group[event] as? [[String: Any]] else { continue }
            let remaining = handlers.filter {
                !commands.contains($0["command"] as? String ?? "")
                    || $0["type"] as? String != "command"
                    || $0["timeout"] as? Int != 5
                    || $0.count != 3
            }
            guard remaining.count < handlers.count else { continue }
            group[event] = remaining.isEmpty ? nil : remaining
            changed = true
        }
        guard changed else { return nil }
        root[pluginName] = group.isEmpty ? nil : group
        return root
    }

    public static func repairReasons(
        dataDirectoryURL: URL,
        configDirectoryURL: URL
    ) -> [PluginRepairReason] {
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let pluginDir = configDirectoryURL.standardizedFileURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let pluginJSONURL = pluginDir.appendingPathComponent("plugin.json", isDirectory: false)
        let hooksJSONURL = pluginDir.appendingPathComponent("hooks.json", isDirectory: false)
        let skillURL = pluginDir.appendingPathComponent("skills/rewind/SKILL.md", isDirectory: false)

        var reasons: [PluginRepairReason] = []
        let allowedPluginKeys: Set<String> = ["name", "version", "description", "suggestedPrompts"]

        if let pData = try? Data(contentsOf: pluginJSONURL),
           let pObj = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] {
            if !Set(pObj.keys).isSubset(of: allowedPluginKeys) {
                reasons.append(.unsupportedManifestKeys)
            }
            if pObj["name"] as? String != pluginName {
                reasons.append(.manifestNameMismatch)
            }
            if pObj["version"] as? String != pluginVersion {
                reasons.append(.manifestVersionMismatch)
            }
            if let prompts = pObj["suggestedPrompts"] as? [String],
               prompts.count == 3,
               prompts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            } else {
                reasons.append(.invalidSuggestedPrompts)
            }
        } else {
            reasons.append(.missingOrInvalidManifest)
        }

        if hooksWithoutLegacyCapture(at: hooksJSONURL, dataDirectory: resolvedData) != nil {
            reasons.append(.legacyCaptureHooksPresent)
        }

        if let skillText = try? String(contentsOf: skillURL, encoding: .utf8) {
            if !skillText.contains("memo_list_memos") || !skillText.contains("conversation://") {
                reasons.append(.skillMissingMemosGuidance)
            }
        } else {
            reasons.append(.missingSkillFile)
        }

        let expectedSidecar = stableSidecarBinaryURL(in: resolvedData)
        if !FileManager.default.isExecutableFile(atPath: expectedSidecar.path) {
            reasons.append(.missingSidecarBinary)
        }
        let sidecarURL = pluginDir.appendingPathComponent("sidecars/launcher/sidecar.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let definition = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           definition["command"] as? String == expectedSidecar.path,
           definition["args"] as? [String] == ["--data-dir", resolvedData.path],
           definition["restart_policy"] as? String == "always" {
        } else {
            reasons.append(.invalidSidecarConfig)
        }
        if let data = try? Data(contentsOf: configDirectoryURL.appendingPathComponent("config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sidecars = config["sidecars"] as? [String: Any],
           let launcher = sidecars["coding-rewind/launcher"] as? [String: Any], launcher["enabled"] as? Bool == true {
        } else {
            reasons.append(.sidecarLauncherDisabled)
        }

        return reasons
    }

    public static func verify(
        dataDirectoryURL: URL,
        configDirectoryURL: URL,
        language: AppLanguage = .zhHans
    ) -> Status {
        let pluginDir = configDirectoryURL.standardizedFileURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let reasons = repairReasons(dataDirectoryURL: dataDirectoryURL, configDirectoryURL: configDirectoryURL)
        return reasons.isEmpty
            ? .installed(pluginDirectoryURL: pluginDir)
            : .needsInstallOrRepair(reasons: reasons.map { L10n.pluginRepairReason($0, in: language) })
    }
}

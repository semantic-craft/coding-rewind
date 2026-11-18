// SPDX-License-Identifier: MIT
// Stable binary staging into Application Support/CodingRewind/bin/ adapted from wxtsky/CodeIsland (MIT).

import Darwin
import Foundation

public enum AntigravityIntegration {
    public static let pluginName = "coding-rewind"
    public static let pluginVersion = "0.6.0"

    public enum Status: Equatable, Sendable {
        case installed(pluginDirectoryURL: URL)
        case needsInstallOrRepair(reasons: [String])
    }

    public static func stableSidecarBinaryURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL.appendingPathComponent("bin/coding-rewind-sidecar")
    }

    public static func stableCLIBinaryURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("coding-rewind", isDirectory: false)
    }

    public static func stageCLIBinary(
        sourceCLIBinaryURL: URL?,
        in dataDirectoryURL: URL
    ) throws {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let destCLI = stableCLIBinaryURL(in: resolvedData)
        guard !destCLI.path.contains("/.build/") else {
            throw RewindError.ioError("Refusing to install coding-rewind inside transient .build/ path")
        }
        let binDir = destCLI.deletingLastPathComponent()
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let retiredBridge = binDir.appendingPathComponent("memos-mcp-bridge.sh", isDirectory: false)
        if fm.fileExists(atPath: retiredBridge.path) {
            try? fm.removeItem(at: retiredBridge)
        }

        if let sourceCLI = sourceCLIBinaryURL?.standardizedFileURL,
           sourceCLI != destCLI,
           fm.isExecutableFile(atPath: sourceCLI.path) {
            try AtomicFile.writeData(Data(contentsOf: sourceCLI), to: destCLI, permissions: 0o755)
            _ = chmod(destCLI.path, 0o755)
        }
    }

    public static func refreshSidecarBinaryIfInstalled(
        sourceSidecarBinaryURL: URL?,
        in dataDirectoryURL: URL,
        configDirectoryURL: URL
    ) throws {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let destSidecar = stableSidecarBinaryURL(in: resolvedData)
        guard !destSidecar.path.contains("/.build/") else {
            throw RewindError.ioError("Refusing to install sidecar inside transient .build/ path")
        }
        let pluginDir = configDirectoryURL.standardizedFileURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        guard fm.fileExists(atPath: destSidecar.path) || fm.fileExists(atPath: pluginDir.path) else {
            return
        }
        guard let sourceSidecar = sourceSidecarBinaryURL?.standardizedFileURL,
              sourceSidecar != destSidecar,
              fm.isExecutableFile(atPath: sourceSidecar.path) else {
            return
        }
        try fm.createDirectory(at: destSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.writeData(Data(contentsOf: sourceSidecar), to: destSidecar, permissions: 0o755)
        _ = chmod(destSidecar.path, 0o755)
    }

    public static func suggestedPrompts(in language: AppLanguage = .zhHans) -> [String] {
        L10n.suggestedPrompts(in: language)
    }

    @discardableResult
    public static func installOrRepair(
        dataDirectoryURL: URL,
        configDirectoryURL: URL,
        sourceCLIBinaryURL: URL? = nil,
        sourceSidecarBinaryURL: URL? = nil,
        language: AppLanguage = .zhHans
    ) throws -> URL {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        try stageCLIBinary(sourceCLIBinaryURL: sourceCLIBinaryURL, in: resolvedData)
        guard fm.isExecutableFile(atPath: stableCLIBinaryURL(in: resolvedData).path) else {
            let detail = language == .en
                ? "Missing coding-rewind; install the plugin from a packaged app bundle"
                : "缺少 coding-rewind，请用完整应用包安装插件"
            throw RewindError.ioError(detail)
        }
        let binDir = resolvedData.appendingPathComponent("bin", isDirectory: true)

        let retiredActiveTurn = resolvedData.appendingPathComponent("active_turn.json")
        if fm.fileExists(atPath: retiredActiveTurn.path) {
            try? fm.removeItem(at: retiredActiveTurn)
        }
        let retiredHook = binDir.appendingPathComponent("coding-rewind-hook")
        if fm.fileExists(atPath: retiredHook.path) {
            try? fm.removeItem(at: retiredHook)
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

        try writePluginManifest(to: pluginDir, language: language)
        try writeSkillFile(to: pluginDir)
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
            if !skillText.contains("list_snippets")
                || !skillText.contains("search_snippets")
                || !skillText.contains("get_snippet")
                || !skillText.contains("create_snippet")
                || !skillText.contains("update_snippet_metadata")
                || !skillText.contains("append_snippet_note")
                || !skillText.contains("archive_snippet")
                || !skillText.contains("CLI write/delete subcommands")
                || !skillText.contains("conversation://")
                || skillText.contains("memo_list_memos") {
                reasons.append(.skillMissingMemosGuidance)
            }
        } else {
            reasons.append(.missingSkillFile)
        }

        let expectedCLI = stableCLIBinaryURL(in: resolvedData)
        if !FileManager.default.isExecutableFile(atPath: expectedCLI.path) {
            reasons.append(.missingCLIBinary)
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

    public static func writePluginManifest(to pluginDirectoryURL: URL, language: AppLanguage) throws {
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
            to: pluginDirectoryURL.appendingPathComponent("plugin.json", isDirectory: false),
            permissions: 0o644
        )
    }

    public static func writeSkillFile(to pluginDirectoryURL: URL) throws {
        let skillDir = pluginDirectoryURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("rewind", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillMarkdown = """
        ---
        name: rewind
        description: Query, search, synthesize, annotate, and stash Coding Rewind highlights with full conversation provenance via coding-rewind MCP tools or CLI.
        ---

        # Coding Rewind (/rewind)

        Use the `coding-rewind` MCP tools (or `~/Library/Application Support/CodingRewind/bin/coding-rewind` CLI when MCP is not wired) to inspect, search, synthesize, annotate, and archive `#rewind/` snippets:

        1. Call `list_snippets` (defaults: `window: "72h"`, `status: "active"`) or `search_snippets` (`query`) to inspect recent highlights. Pass `window: "all"` (CLI `--window all` or `--window <N>h`) to read snippets older than 72 hours, and `status: "synthesized"` or `"all"` (CLI `--status synthesized|all`) to include archived snippets.
        2. Call `get_snippet` (`id`, `include_context: true`; CLI `~/Library/Application Support/CodingRewind/bin/coding-rewind get <id> --json`) to inspect a specific snippet, reading its `title`, `sessionTopic`, `contextSummary`, `keywords`, `tags`, `sourceTitle`, `sourceURL`, `conversationContext`, `notes`, and unmodified `verbatimText`.
        3. Preserve `verbatimText` word-for-word without alteration, keep AI summary fields and `notes` distinct from the original quote, and always cite provenance links (`[出处](conversation://<id>)` or web chat/page URLs).
        4. When write access is enabled (`read_write`), close the synthesis loop when helpful or requested:
           - Call `append_snippet_note` (`id`, `note`, optional `author`; CLI `coding-rewind note <id> --text ...` or `--stdin`) using the card's Clip ID to attach conclusions back to the original card without touching `verbatimText`.
           - Call `create_snippet` (`text`, optional `title`, `session_topic`, `context_summary`, `keywords`, `tags`, `source_url`; CLI `coding-rewind create --text ...` or `--stdin`) to stash a newly synthesized outline or draft back into Coding Rewind (`#source/agent`).
           - Call `update_snippet_metadata` (`id`, optional `title`, `session_topic`, `context_summary`, `keywords`, `add_tags`, `remove_tags`, `archived`; CLI `coding-rewind update <id> ...`) to refine metadata headers, tags, or archive state while keeping `verbatimText` 100% byte-identical.
           - Call `archive_snippet` (`id`; CLI `~/Library/Application Support/CodingRewind/bin/coding-rewind archive <id>`) when asked to mark incorporated snippets as `#rewind/synthesized`.
        5. Respect the permission boundary: physical deletion is never exposed via MCP, and when AI access is set to `read_only` (in Settings or via `CODING_REWIND_AI_ACCESS=read_only`), all mutating MCP tools (`create_snippet`, `update_snippet_metadata`, `append_snippet_note`, `archive_snippet`) and CLI write/delete subcommands (`create`, `update`, `note`, `archive`, `delete`) are rejected while read tools and `list`/`search`/`get` remain available.
        """
        try AtomicFile.writeUTF8(
            skillMarkdown + "\n",
            to: skillDir.appendingPathComponent("SKILL.md", isDirectory: false),
            permissions: 0o644
        )
    }
}

public struct AntigravityPluginInstaller: Sendable {
    public enum InspectionStatus: Equatable, Sendable {
        case installed
        case needsInstallOrRepair([PluginRepairReason])
    }

    public let dataDirectoryURL: URL
    public let configDirectoryURL: URL

    public init(dataDirectoryURL: URL, configDirectoryURL: URL) {
        self.dataDirectoryURL = dataDirectoryURL.standardizedFileURL
        self.configDirectoryURL = configDirectoryURL.standardizedFileURL
    }

    public init(paths: StoragePaths) {
        self.init(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        )
    }

    public func inspectStatus() -> InspectionStatus {
        let reasons = AntigravityIntegration.repairReasons(
            dataDirectoryURL: dataDirectoryURL,
            configDirectoryURL: configDirectoryURL
        )
        return reasons.isEmpty ? .installed : .needsInstallOrRepair(reasons)
    }

    public func refreshLocalizedMetadataIfInstalled(language: AppLanguage) throws {
        let pluginDir = configDirectoryURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(AntigravityIntegration.pluginName, isDirectory: true)
        switch inspectStatus() {
        case .installed:
            try AntigravityIntegration.writePluginManifest(to: pluginDir, language: language)
        case .needsInstallOrRepair(let reasons):
            let reasonSet = Set(reasons)
            let autoMigratable: Set<PluginRepairReason> = [
                .manifestVersionMismatch,
                .skillMissingMemosGuidance,
                .invalidSuggestedPrompts
            ]
            guard !reasonSet.isEmpty, reasonSet.isSubset(of: autoMigratable) else { return }
            try AntigravityIntegration.writePluginManifest(to: pluginDir, language: language)
            try AntigravityIntegration.writeSkillFile(to: pluginDir)
        }
    }
}

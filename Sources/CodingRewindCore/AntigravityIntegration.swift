// SPDX-License-Identifier: MIT

import Foundation

public enum RewindMCPToolID: String, CaseIterable, Codable, Sendable {
    case listHotClips = "rewind_list_hot_clips"
    case searchClips = "rewind_search_clips"
    case getClip = "rewind_get_clip"

    public var summaryDescription: String {
        switch self {
        case .listHotClips:
            return "List recently stashed Coding-Rewind clips in the 72-hour hot window."
        case .searchClips:
            return "Search saved Coding-Rewind clips offline using Chinese or English natural language."
        case .getClip:
            return "Fetch a single Coding-Rewind clip by clip_id including verbatim excerpt, prompt context, source, and user notes."
        }
    }
}

public struct AntigravityIntegration: Sendable {
    public static let hookGroupKey = "coding-rewind-bridge"
    public static let pluginDirectoryName = "coding-rewind"
    public static let pluginSchemaURL = "https://antigravity.google/schemas/v1/plugin.json"

    public struct BinaryLocations: Equatable, Sendable {
        public let antigravityBridgeExecutableURL: URL
        public let rewindMCPExecutableURL: URL

        public init(antigravityBridgeExecutableURL: URL, rewindMCPExecutableURL: URL) {
            self.antigravityBridgeExecutableURL = antigravityBridgeExecutableURL.standardizedFileURL
            self.rewindMCPExecutableURL = rewindMCPExecutableURL.standardizedFileURL
        }
    }

    public enum Status: Equatable, Sendable {
        case installed(pluginDirectoryURL: URL, hooksFileURL: URL)
        case needsInstallOrRepair(reasons: [String])
    }

    public static func verify(configDirectoryURL: URL, binaries: BinaryLocations) -> Status {
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        let hooksFileURL = resolvedConfig.appendingPathComponent("hooks.json", isDirectory: false)
        let pluginDirURL = resolvedConfig
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
        let pluginJSONURL = pluginDirURL.appendingPathComponent("plugin.json", isDirectory: false)
        let mcpConfigURL = pluginDirURL.appendingPathComponent("mcp_config.json", isDirectory: false)
        let wrapperScriptURL = pluginDirURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("rewind-mcp.sh", isDirectory: false)
        let skillMarkdownURL = pluginDirURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("rewind", isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)

        var reasons: [String] = []
        let expectedHookPath = binaries.antigravityBridgeExecutableURL.path
        let expectedMCPPath = binaries.rewindMCPExecutableURL.path

        if !expectedHookPath.hasPrefix("/") {
            reasons.append("Hook binary path must be absolute")
        }

        if let hooksData = try? Data(contentsOf: hooksFileURL),
           let root = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any],
           let group = root[hookGroupKey] as? [String: Any] {
            let groupKeys = Set(group.keys)
            if groupKeys != Set(["PostInvocation", "Stop"]) {
                reasons.append("hooks.json group must contain only PostInvocation and Stop events")
            }
            for event in ["PostInvocation", "Stop"] {
                if let entries = group[event] as? [[String: Any]],
                   let hooks = entries.first?["hooks"] as? [[String: Any]],
                   let cmd = hooks.first?["command"] as? String {
                    if cmd != expectedHookPath {
                        reasons.append("hooks.json \(event) command mismatch")
                    }
                } else {
                    reasons.append("hooks.json missing \(event) command definition")
                }
            }
        } else {
            reasons.append("hooks.json missing \(hookGroupKey) group")
        }

        if let pluginData = try? Data(contentsOf: pluginJSONURL),
           let pluginObj = try? JSONSerialization.jsonObject(with: pluginData) as? [String: Any] {
            if pluginObj["$schema"] as? String != pluginSchemaURL {
                reasons.append("plugin.json $schema mismatch")
            }
            if pluginObj["name"] as? String != pluginDirectoryName {
                reasons.append("plugin.json name mismatch")
            }
        } else {
            reasons.append("plugin.json missing or unreadable")
        }

        if let mcpData = try? Data(contentsOf: mcpConfigURL),
           let mcpObj = try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
           let servers = mcpObj["mcpServers"] as? [String: Any],
           let server = servers[pluginDirectoryName] as? [String: Any] {
            if server["command"] as? String != "/bin/sh" {
                reasons.append("mcp_config.json command must be /bin/sh")
            }
            if server["args"] as? [String] != ["${PLUGIN_ROOT}/bin/rewind-mcp.sh"] {
                reasons.append("mcp_config.json args must be [\"${PLUGIN_ROOT}/bin/rewind-mcp.sh\"]")
            }
            if let toolsMap = server["tools"] as? [String: [String: Any]] {
                for tool in RewindMCPToolID.allCases {
                    if toolsMap[tool.rawValue]?["eager"] as? Bool != true {
                        reasons.append("mcp_config.json missing eager:true for \(tool.rawValue)")
                    }
                }
            } else {
                reasons.append("mcp_config.json missing tools map")
            }
        } else {
            reasons.append("mcp_config.json missing or unreadable")
        }

        if let scriptContent = try? String(contentsOf: wrapperScriptURL, encoding: .utf8) {
            if !scriptContent.contains(expectedMCPPath) {
                reasons.append("bin/rewind-mcp.sh does not reference expected rewind-mcp binary path")
            }
            if !FileManager.default.isExecutableFile(atPath: wrapperScriptURL.path) {
                reasons.append("bin/rewind-mcp.sh is not executable (0755)")
            }
        } else {
            reasons.append("bin/rewind-mcp.sh missing")
        }

        if let skillContent = try? String(contentsOf: skillMarkdownURL, encoding: .utf8) {
            if !skillContent.contains("name: rewind") || skillContent.contains("mode:") {
                reasons.append("skills/rewind/SKILL.md frontmatter invalid")
            }
        } else {
            reasons.append("skills/rewind/SKILL.md missing")
        }

        if reasons.isEmpty {
            return .installed(pluginDirectoryURL: pluginDirURL, hooksFileURL: hooksFileURL)
        }
        return .needsInstallOrRepair(reasons: reasons)
    }

    public static func installOrRepair(
        configDirectoryURL: URL,
        binaries: BinaryLocations
    ) throws {
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: resolvedConfig, withIntermediateDirectories: true)

        let hooksFileURL = resolvedConfig.appendingPathComponent("hooks.json", isDirectory: false)
        var existingRoot: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: hooksFileURL),
           let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            existingRoot = parsed
        }

        let hookEntry: [[String: Any]] = [
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": binaries.antigravityBridgeExecutableURL.path
                    ]
                ]
            ]
        ]
        existingRoot[hookGroupKey] = [
            "PostInvocation": hookEntry,
            "Stop": hookEntry
        ]
        let hooksData = try JSONSerialization.data(
            withJSONObject: existingRoot,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFileWriter.writeData(hooksData, to: hooksFileURL, permissions: 0o644)

        let pluginDirURL = resolvedConfig
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
        let binDirURL = pluginDirURL.appendingPathComponent("bin", isDirectory: true)
        let skillDirURL = pluginDirURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("rewind", isDirectory: true)

        try FileManager.default.createDirectory(at: binDirURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDirURL, withIntermediateDirectories: true)

        let pluginManifest: [String: Any] = [
            "$schema": pluginSchemaURL,
            "name": pluginDirectoryName,
            "version": "0.1.0",
            "description": "Coding-Rewind recent hot-window clip stash and writing synthesis bridge for Antigravity App 2.x",
            "mcpServers": "./mcp_config.json",
            "skills": "./skills/",
            "suggestedPrompts": [
                [
                    "title": "回顾近期灵感片段",
                    "prompt": "/rewind 列出我最近 72 小时在 Coding-Rewind 暂存的灵感片段，并帮我串联成文。"
                ]
            ]
        ]
        let pluginData = try JSONSerialization.data(
            withJSONObject: pluginManifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFileWriter.writeData(
            pluginData,
            to: pluginDirURL.appendingPathComponent("plugin.json", isDirectory: false),
            permissions: 0o644
        )

        var toolsDict: [String: [String: Bool]] = [:]
        for tool in RewindMCPToolID.allCases {
            toolsDict[tool.rawValue] = ["eager": true]
        }
        let mcpConfig: [String: Any] = [
            "mcpServers": [
                pluginDirectoryName: [
                    "command": "/bin/sh",
                    "args": ["${PLUGIN_ROOT}/bin/rewind-mcp.sh"],
                    "tools": toolsDict
                ]
            ]
        ]
        let mcpData = try JSONSerialization.data(
            withJSONObject: mcpConfig,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFileWriter.writeData(
            mcpData,
            to: pluginDirURL.appendingPathComponent("mcp_config.json", isDirectory: false),
            permissions: 0o644
        )

        let wrapperScript = """
        #!/bin/sh
        exec "\(binaries.rewindMCPExecutableURL.path)" "$@"
        """
        let wrapperURL = binDirURL.appendingPathComponent("rewind-mcp.sh", isDirectory: false)
        try AtomicFileWriter.writeUTF8(wrapperScript + "\n", to: wrapperURL, permissions: 0o755)
        _ = chmod(wrapperURL.path, 0o755)

        let skillMarkdown = """
        ---
        name: rewind
        description: Retrieve and synthesize recent 72-hour Coding-Rewind clips stashed from Antigravity App 2.x and web chats.
        ---

        # Coding-Rewind (/rewind)

        Use the `Coding-Rewind` MCP tools to inspect and build upon the user's stashed highlights:

        1. Call `rewind_list_hot_clips` to inspect clips captured within the last 72 hours.
        2. Call `rewind_search_clips` with a natural-language query to locate specific stashed ideas.
        3. Call `rewind_get_clip` with `clip_id` to read the full verbatim excerpt, original prompt context, provenance, and user notes.
        """
        try AtomicFileWriter.writeUTF8(
            skillMarkdown + "\n",
            to: skillDirURL.appendingPathComponent("SKILL.md", isDirectory: false),
            permissions: 0o644
        )
    }

    public static func uninstall(configDirectoryURL: URL) throws {
        let resolvedConfig = configDirectoryURL.standardizedFileURL
        let hooksFileURL = resolvedConfig.appendingPathComponent("hooks.json", isDirectory: false)
        if let existingData = try? Data(contentsOf: hooksFileURL),
           var parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            parsed.removeValue(forKey: hookGroupKey)
            let updatedData = try JSONSerialization.data(
                withJSONObject: parsed,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try AtomicFileWriter.writeData(updatedData, to: hooksFileURL, permissions: 0o644)
        }

        let pluginDirURL = resolvedConfig
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: pluginDirURL.path) {
            try FileManager.default.removeItem(at: pluginDirURL)
        }
    }
}

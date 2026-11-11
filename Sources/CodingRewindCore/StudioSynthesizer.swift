// SPDX-License-Identifier: MIT

import Foundation
import Security

public enum StudioSynthesisError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpointHost
    case insecureEndpointScheme(String)
    case unacknowledgedEndpointHost(expected: String, actual: String)
    case emptyModelIdentifier
    case emptyKeychainAccount
    case noPinnedClips
    case remoteKeyMissing(account: String)
    case remoteCallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpointHost:
            return "远端模型地址缺少有效的主机名。"
        case .insecureEndpointScheme(let scheme):
            return "远端模型接口必须使用 HTTPS 或本机 localhost，当前为: \(scheme)"
        case .unacknowledgedEndpointHost(let expected, let actual):
            return "用户确认的外发主机 (\(expected)) 与实际接口主机 (\(actual)) 不一致。"
        case .emptyModelIdentifier:
            return "模型标识不能为空。"
        case .emptyKeychainAccount:
            return "Keychain 凭据账户名不能为空。"
        case .noPinnedClips:
            return "请先勾选至少一条暂存片段再发起推演。"
        case .remoteKeyMissing(let account):
            return "未在 macOS Keychain 中找到账户 \(account) 的 API Key。"
        case .remoteCallFailed(let detail):
            return "远端模型请求失败: \(detail)"
        }
    }
}

public struct RemoteEndpointConsent: Equatable, Codable, Sendable {
    public let endpointURL: URL
    public let modelIdentifier: String
    public let keychainAccount: String
    public let acknowledgedHost: String

    public init(
        endpointURL: URL,
        modelIdentifier: String,
        keychainAccount: String,
        acknowledgedHost: String
    ) throws {
        guard let host = endpointURL.host?.lowercased(), !host.isEmpty else {
            throw StudioSynthesisError.invalidEndpointHost
        }
        let scheme = endpointURL.scheme?.lowercased() ?? ""
        let isLocalhost = (host == "localhost" || host == "127.0.0.1")
        guard scheme == "https" || (scheme == "http" && isLocalhost) else {
            throw StudioSynthesisError.insecureEndpointScheme(scheme)
        }
        let normalizedAck = acknowledgedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host == normalizedAck else {
            throw StudioSynthesisError.unacknowledgedEndpointHost(expected: normalizedAck, actual: host)
        }
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw StudioSynthesisError.emptyModelIdentifier
        }
        let trimmedAccount = keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else {
            throw StudioSynthesisError.emptyKeychainAccount
        }

        self.endpointURL = endpointURL
        self.modelIdentifier = trimmedModel
        self.keychainAccount = trimmedAccount
        self.acknowledgedHost = host
    }
}

public enum SynthesisBackend: Equatable, Sendable {
    case localOutline
    case antigravityHandoff
    case openAICompatible(RemoteEndpointConsent)

    public var privacyBadgeText: String {
        switch self {
        case .localOutline:
            return "本地离线推演 · 零外发"
        case .antigravityHandoff:
            return "Antigravity 本机联动 · 零外发"
        case .openAICompatible(let consent):
            return "已授权外发至 \(consent.acknowledgedHost)"
        }
    }
}

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ChatTurn: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public let text: String
    public let citedClipIDs: [ClipID]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        citedClipIDs: [ClipID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citedClipIDs = citedClipIDs
        self.createdAt = createdAt
    }
}

public struct StudioRequest: Equatable, Sendable {
    public let pinnedClips: [Clip]
    public let conversation: [ChatTurn]
    public let draftMarkdown: String
    public let backend: SynthesisBackend

    public init(
        pinnedClips: [Clip],
        conversation: [ChatTurn],
        draftMarkdown: String,
        backend: SynthesisBackend = .localOutline
    ) {
        self.pinnedClips = pinnedClips
        self.conversation = conversation
        self.draftMarkdown = draftMarkdown
        self.backend = backend
    }
}

public struct StudioResponse: Equatable, Sendable {
    public let assistantTurn: ChatTurn
    public let suggestedMarkdown: String
    public let citedClipIDs: Set<ClipID>
    public let outboundHostUsed: String?

    public init(
        assistantTurn: ChatTurn,
        suggestedMarkdown: String,
        citedClipIDs: Set<ClipID>,
        outboundHostUsed: String?
    ) {
        self.assistantTurn = assistantTurn
        self.suggestedMarkdown = suggestedMarkdown
        self.citedClipIDs = citedClipIDs
        self.outboundHostUsed = outboundHostUsed
    }
}

public struct StudioSynthesizer: Sendable {
    public typealias RemoteTransport = @Sendable (RemoteEndpointConsent, [Clip], [ChatTurn]) async throws -> String

    private let remoteTransport: RemoteTransport?

    public init(remoteTransport: RemoteTransport? = nil) {
        self.remoteTransport = remoteTransport
    }

    public func respond(_ request: StudioRequest) async throws -> StudioResponse {
        guard !request.pinnedClips.isEmpty else {
            throw StudioSynthesisError.noPinnedClips
        }

        let userPrompt = request.conversation.last(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "围绕已勾选片段提炼成文脉络"
        let citedIDs = request.pinnedClips.map(\.id)
        let citedSet = Set(citedIDs)

        switch request.backend {
        case .localOutline:
            let markdown = Self.buildLocalStructuredMarkdown(
                instruction: userPrompt,
                clips: request.pinnedClips,
                priorTurnsCount: request.conversation.count
            )
            let turn = ChatTurn(role: .assistant, text: markdown, citedClipIDs: citedIDs)
            return StudioResponse(
                assistantTurn: turn,
                suggestedMarkdown: markdown,
                citedClipIDs: citedSet,
                outboundHostUsed: nil
            )

        case .antigravityHandoff:
            let command = Self.makeAntigravitySlashCommand(for: request.pinnedClips, instruction: userPrompt)
            let turn = ChatTurn(role: .assistant, text: command, citedClipIDs: citedIDs)
            return StudioResponse(
                assistantTurn: turn,
                suggestedMarkdown: command,
                citedClipIDs: citedSet,
                outboundHostUsed: nil
            )

        case .openAICompatible(let consent):
            let outputText: String
            if let remoteTransport {
                outputText = try await remoteTransport(consent, request.pinnedClips, request.conversation)
            } else {
                outputText = try await Self.executeKeychainGatedRemoteRequest(
                    consent: consent,
                    clips: request.pinnedClips,
                    conversation: request.conversation
                )
            }
            let turn = ChatTurn(role: .assistant, text: outputText, citedClipIDs: citedIDs)
            return StudioResponse(
                assistantTurn: turn,
                suggestedMarkdown: outputText,
                citedClipIDs: citedSet,
                outboundHostUsed: consent.acknowledgedHost
            )
        }
    }

    public static func makeAntigravitySlashCommand(
        for clips: [Clip],
        instruction: String? = nil
    ) -> String {
        let ids = clips.map { $0.id.rawValue }.joined(separator: ", ")
        let taskLine = (instruction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "请结合这些近期暂存片段继续推演，并整理出可直接落稿的结构化段落。"

        var lines: [String] = [
            "/rewind",
            "请调用本机 Coding-Rewind MCP 工具 `\(RewindMCPToolID.getClip.rawValue)` 读取以下暂存片段 ID: \(ids)",
            ""
        ]
        for (idx, clip) in clips.enumerated() {
            let preview = clip.excerpt.replacingOccurrences(of: "\n", with: " ")
            let clippedPreview = preview.count > 72 ? String(preview.prefix(72)) + "..." : preview
            lines.append("\(idx + 1). [`\(clip.id.shortCode)`] (\(clip.source.displayBadge)): \(clippedPreview)")
        }
        lines.append("")
        lines.append("推演目标: \(taskLine)")
        return lines.joined(separator: "\n")
    }

    private static func buildLocalStructuredMarkdown(
        instruction: String,
        clips: [Clip],
        priorTurnsCount: Int
    ) -> String {
        var lines: [String] = [
            "### 围绕 \(clips.count) 条暂存片段的递进成文要点",
            "",
            "**推演方向**: \(instruction)",
            ""
        ]

        for (index, clip) in clips.enumerated() {
            let heading = clip.annotation.title ?? "要点 \(index + 1) · \(clip.source.displayBadge)"
            lines.append("#### \(index + 1). \(heading) [^clip-\(clip.id.shortCode)]")
            lines.append("")
            switch clip.promptContext {
            case .captured(let prompt):
                lines.append("- **触发问题**: \(prompt)")
            case .missing:
                lines.append("- **触发问题**: 原问题缺失")
            }
            lines.append("- **核心摘录**:")
            lines.append("  > \(clip.excerpt.replacingOccurrences(of: "\n", with: "\n  > "))")
            if let note = clip.annotation.userNote {
                lines.append("- **批注延伸**: \(note)")
            }
            lines.append("")
        }

        if priorTurnsCount > 2 {
            lines.append("**合流结论**: 已结合多轮追问将上述 \(clips.count) 条原话证据串联为可插入左侧 `.md` 草稿的章节段落。")
        } else {
            lines.append("**合流结论**: 上述片段已按「问题背景 -> 原话论据 -> 批注延伸」对齐，可直接点击「插入左侧草稿」落盘为标准 Markdown 并自动记录引用脚注。")
        }
        return lines.joined(separator: "\n")
    }

    private static func executeKeychainGatedRemoteRequest(
        consent: RemoteEndpointConsent,
        clips: [Clip],
        conversation: [ChatTurn]
    ) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.codingrewind.app",
            kSecAttrAccount as String: consent.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let keyData = item as? Data,
              let apiKey = String(data: keyData, encoding: .utf8),
              !apiKey.isEmpty else {
            throw StudioSynthesisError.remoteKeyMissing(account: consent.keychainAccount)
        }

        var request = URLRequest(url: consent.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let clipContext = clips.map { clip in
            "[Clip \(clip.id.shortCode) | \(clip.source.displayBadge)]\nExcerpt: \(clip.excerpt)"
        }.joined(separator: "\n\n")

        let payload: [String: Any] = [
            "model": consent.modelIdentifier,
            "messages": [
                ["role": "system", "content": "Ground every claim in the user's selected clips:\n\n\(clipContext)"]
            ] + conversation.map { ["role": $0.role.rawValue, "content": $0.text] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StudioSynthesisError.remoteCallFailed("HTTP status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw StudioSynthesisError.remoteCallFailed("Malformed response body")
        }
        return content
    }
}

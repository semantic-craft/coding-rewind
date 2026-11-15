// SPDX-License-Identifier: MIT

import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }
}

public enum AppLanguagePreference: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .system:
            var sawNonEmptyTag = false
            for rawTag in preferredLanguages {
                let normalized = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                sawNonEmptyTag = true
                let primary = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? normalized
                if primary == "zh" {
                    return .zhHans
                }
                if primary == "en" {
                    return .en
                }
            }
            return sawNonEmptyTag ? .en : .zhHans
        }
    }
}

public enum PluginRepairReason: Equatable, Hashable, Sendable {
    case notInstalled
    case unsupportedManifestKeys
    case manifestNameMismatch
    case manifestVersionMismatch
    case invalidSuggestedPrompts
    case missingOrInvalidManifest
    case legacyCaptureHooksPresent
    case skillMissingMemosGuidance
    case missingSkillFile
    case missingCLIBinary
    case missingSidecarBinary
    case invalidSidecarConfig
    case sidecarLauncherDisabled
}

public enum BannerNotice: Equatable, Sendable {
    case savedOfflineNeedsConfig
    case savedClip(sourceTitle: String)
    case savedOfflineTemporaryFailure
    case syncFailedShowingLocal
    case selectAtLeastOneCard
    case needsAntigravityPlugin
    case needsCodexInstalled
    case waitingForHostConfirmation(ConversationHost)
    case sentArchiveBlockedUnconfigured
    case sentPartialArchiveFailure
    case sentToNewConversation(count: Int, host: ConversationHost)
    case sentOpenConversationFailed(ConversationHost)
    case requestExpired(ConversationHost)
    case hostRejected(ConversationHost)
    case deliveryUnconfirmed(ConversationHost)
    case stillWaitingForReceipt
    case clearedUnconfirmedRequest
    case retainedUnarchivedCards
    case reopenConversationFailed
    case openedConversation(ConversationHost)
    case resumeUnarchivedStartup
    case resumePendingStartup
    case archiveCardBlockedOfflineOrUnconfigured
    case savedConnectionSettings
    case pluginInstalled
    case pluginNeedsRepair(PluginRepairReason?)
    case pluginInstallFailedRewind(RewindError)
    case pluginInstallFailedMessage(String)
    case rewindError(RewindError)
    case custom(String)
}

public enum L10n {
    public static func statusFilterLabel(_ filter: StatusFilter, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch filter {
            case .all: return "全部片段"
            case .ready: return "AI 已整理"
            case .pending: return "待整理"
            }
        case .en:
            switch filter {
            case .all: return "All Clips"
            case .ready: return "AI Enriched"
            case .pending: return "Pending"
            }
        }
    }

    public static func cardStatusBadge(_ status: CardStatus, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch status {
            case .pending: return "待整理"
            case .ready: return "AI 已整理"
            }
        case .en:
            switch status {
            case .pending: return "Pending"
            case .ready: return "AI Enriched"
            }
        }
    }

    public static func rewindError(_ error: RewindError, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch error {
            case .emptySelection:
                return "请先选中要保存的文本，再按快捷键。"
            case .accessibilityPermissionDenied:
                return "请在系统设置的“辅助功能”中允许 Coding Rewind 读取所选文本。"
            case .noFrontmostApplication:
                return "未找到当前应用的窗口。"
            case .invalidClipID(let id):
                return "片段编号无效：\(id)"
            case .invalidMemosURL(let raw):
                return "Memos 服务地址无效：\(raw)"
            case .missingCredentials:
                return "尚未设置 Memos 服务地址或访问令牌。"
            case .httpError(let code, let body):
                return "Memos 请求失败（HTTP \(code)）：\(body.prefix(120))"
            case .invalidServerResponse:
                return "该地址返回的不是 Memos 数据，请检查服务地址是否指向 Memos 实例。"
            case .networkFailure(let detail):
                return "无法连接到服务器（\(detail)）。"
            case .ioError(let detail):
                return "本机文件读写失败：\(detail)"
            case .keychainError(let status):
                return "无法访问 macOS 钥匙串（错误代码 \(status)）"
            }
        case .en:
            switch error {
            case .emptySelection:
                return "Select text to save before pressing the shortcut."
            case .accessibilityPermissionDenied:
                return "Allow Coding Rewind in System Settings > Privacy & Security > Accessibility to read selected text."
            case .noFrontmostApplication:
                return "Could not find an active window in the frontmost app."
            case .invalidClipID(let id):
                return "Invalid clip ID: \(id)"
            case .invalidMemosURL(let raw):
                return "Invalid Memos server URL: \(raw)"
            case .missingCredentials:
                return "Memos server URL or access token is not configured."
            case .httpError(let code, let body):
                return "Memos request failed (HTTP \(code)): \(body.prefix(120))"
            case .invalidServerResponse:
                return "This address did not return Memos data. Check that the server URL points to a Memos instance."
            case .networkFailure(let detail):
                return "Could not reach the server (\(detail))."
            case .ioError(let detail):
                return "Local file I/O failed: \(detail)"
            case .keychainError(let status):
                return "Could not access macOS Keychain (OSStatus \(status))."
            }
        }
    }

    public static func menuHeaderTitle(hotCardCount: Int, pendingOutboxCount: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return pendingOutboxCount > 0
                ? "Coding Rewind · \(hotCardCount) 条片段（待同步 \(pendingOutboxCount) 条）"
                : "Coding Rewind · \(hotCardCount) 条片段"
        case .en:
            let clipNoun = hotCardCount == 1 ? "clip" : "clips"
            return pendingOutboxCount > 0
                ? "Coding Rewind · \(hotCardCount) \(clipNoun) (\(pendingOutboxCount) pending sync)"
                : "Coding Rewind · \(hotCardCount) \(clipNoun)"
        }
    }

    public static func menuHeaderSubtitle(
        connection: MenuStatusSnapshot.ConnectionState,
        isPluginReady: Bool,
        in language: AppLanguage
    ) -> String {
        switch language {
        case .zhHans:
            let memosPart: String
            switch connection {
            case .configured(let hostSummary, _):
                memosPart = "Memos 已配置 \(hostSummary)"
            case .unconfigured:
                memosPart = "Memos 尚未设置，可先保存到本机"
            }
            let pluginPart = isPluginReady ? "插件已安装" : "插件需要安装或修复"
            return "\(memosPart) · \(pluginPart)"
        case .en:
            let memosPart: String
            switch connection {
            case .configured(let hostSummary, _):
                memosPart = "Memos configured (\(hostSummary))"
            case .unconfigured:
                memosPart = "Memos not configured (saving locally)"
            }
            let pluginPart = isPluginReady ? "Plugin installed" : "Plugin needs install or repair"
            return "\(memosPart) · \(pluginPart)"
        }
    }

    public static func menuToggleHUDTitle(isHUDVisible: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return isHUDVisible ? "隐藏片段浮窗" : "显示片段浮窗"
        case .en:
            return isHUDVisible ? "Hide Clips HUD" : "Show Clips HUD"
        }
    }

    public static func menuLaunchTitle(checkedCardCount: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return checkedCardCount > 0
                ? "在所选应用中开始对话（已选 \(checkedCardCount) 条）"
                : "在所选应用中开始对话"
        case .en:
            return checkedCardCount > 0
                ? "Start Chat in Selected App (\(checkedCardCount) selected)"
                : "Start Chat in Selected App"
        }
    }

    public static func conversationActionTitle(
        isLaunching: Bool,
        canEndUnarchived: Bool,
        hasActiveConversation: Bool,
        hasConfirmedConversation: Bool,
        in language: AppLanguage
    ) -> String {
        switch language {
        case .zhHans:
            if isLaunching { return "正在处理…" }
            if canEndUnarchived { return "重试归档" }
            if hasActiveConversation {
                return hasConfirmedConversation ? "打开对话" : "查询发送结果"
            }
            return "开始对话"
        case .en:
            if isLaunching { return "Working…" }
            if canEndUnarchived { return "Retry Archive" }
            if hasActiveConversation {
                return hasConfirmedConversation ? "Open Chat" : "Check Status"
            }
            return "Start Chat"
        }
    }

    public static func pluginRepairReason(_ reason: PluginRepairReason, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch reason {
            case .notInstalled: return "尚未安装"
            case .unsupportedManifestKeys: return "插件配置中有不支持的设置"
            case .manifestNameMismatch: return "插件配置中的名称不匹配"
            case .manifestVersionMismatch: return "插件配置中的版本不匹配"
            case .invalidSuggestedPrompts: return "插件的三条建议提示词缺失或格式不正确"
            case .missingOrInvalidManifest: return "插件配置缺失或格式不正确"
            case .legacyCaptureHooksPresent: return "仍保留旧版对话记录配置，需要修复"
            case .skillMissingMemosGuidance: return "插件说明缺少片段检索工具指引"
            case .missingSkillFile: return "未找到插件说明文件"
            case .missingCLIBinary: return "命令行与 MCP 组件尚未安装"
            case .missingSidecarBinary: return "对话发送组件尚未安装"
            case .invalidSidecarConfig: return "对话发送组件的配置缺失或不匹配"
            case .sidecarLauncherDisabled: return "对话发送组件尚未启用"
            }
        case .en:
            switch reason {
            case .notInstalled: return "not installed"
            case .unsupportedManifestKeys: return "unsupported settings in plugin.json"
            case .manifestNameMismatch: return "plugin name mismatch"
            case .manifestVersionMismatch: return "plugin version mismatch"
            case .invalidSuggestedPrompts: return "missing or invalid suggestedPrompts"
            case .missingOrInvalidManifest: return "missing or invalid plugin.json"
            case .legacyCaptureHooksPresent: return "legacy capture hooks need cleanup"
            case .skillMissingMemosGuidance: return "SKILL.md missing snippet tool guidance"
            case .missingSkillFile: return "SKILL.md not found"
            case .missingCLIBinary: return "coding-rewind CLI not installed"
            case .missingSidecarBinary: return "launcher sidecar not installed"
            case .invalidSidecarConfig: return "missing or mismatched sidecar.json"
            case .sidecarLauncherDisabled: return "launcher sidecar not enabled"
            }
        }
    }

    public static func pluginInstalledSummary(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Antigravity 插件已安装"
        case .en: return "Antigravity plugin installed"
        }
    }

    public static func pluginNeedsRepairSummary(firstReason: PluginRepairReason?, in language: AppLanguage) -> String {
        let detail = pluginRepairReason(firstReason ?? .notInstalled, in: language)
        switch language {
        case .zhHans: return "插件需要安装或修复（\(detail)）"
        case .en: return "Plugin needs install or repair (\(detail))"
        }
    }

    public static func pluginInstallFailedSummary(detail: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "插件安装失败：\(detail)"
        case .en: return "Plugin installation failed: \(detail)"
        }
    }

    public static func suggestedPrompts(in language: AppLanguage) -> [String] {
        switch language {
        case .zhHans:
            return [
                "/rewind 列出我最近 72 小时暂存的灵感卡片并梳理核心脉络",
                "/rewind 检索我近期定锚的技术讨论片段并附上原对话出处",
                "/rewind 将我最近暂存的 Rewind 卡片串联成结构化初稿"
            ]
        case .en:
            return [
                "/rewind List my highlights stashed in the last 72 hours and outline the key threads",
                "/rewind Search my recent technical discussion clips with original conversation citations",
                "/rewind Synthesize my recently stashed Rewind cards into a structured first draft"
            ]
        }
    }

    public static func codexThreadName(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "CodingRewind 剪藏"
        case .en: return "CodingRewind Clips"
        }
    }

    public static func missingReceiptConversationIDDetail(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "发送结果缺少对话编号"
        case .en: return "Delivery receipt is missing a conversation ID"
        }
    }

    public static func banner(_ notice: BannerNotice, in language: AppLanguage) -> String {
        switch notice {
        case .savedOfflineNeedsConfig:
            switch language {
            case .zhHans: return "已保存到本机，配置云端同步后将自动同步"
            case .en: return "Saved locally. Will sync automatically once Cloud Sync is configured."
            }
        case .savedClip(let sourceTitle):
            switch language {
            case .zhHans: return "已保存片段 · \(sourceTitle)"
            case .en: return "Saved clip · \(sourceTitle)"
            }
        case .savedOfflineTemporaryFailure:
            switch language {
            case .zhHans: return "暂未同步到 Memos，已保存到本机"
            case .en: return "Could not sync to Memos yet; saved locally."
            }
        case .syncFailedShowingLocal:
            switch language {
            case .zhHans: return "同步失败，当前显示本机保存的片段"
            case .en: return "Sync failed; showing locally saved clips."
            }
        case .selectAtLeastOneCard:
            switch language {
            case .zhHans: return "请先保存或勾选至少一条片段"
            case .en: return "Save or select at least one clip first."
            }
        case .needsAntigravityPlugin:
            switch language {
            case .zhHans: return "请先安装或修复 Antigravity 插件，再开始对话"
            case .en: return "Install or repair the Antigravity plugin before starting a chat."
            }
        case .needsCodexInstalled:
            switch language {
            case .zhHans: return "请先安装 Codex。所选片段已保留"
            case .en: return "Install Codex first. Selected clips remain checked."
            }
        case .waitingForHostConfirmation(let host):
            switch language {
            case .zhHans: return "正在等待 \(host.displayName) 确认发送结果…"
            case .en: return "Waiting for \(host.displayName) to confirm delivery…"
            }
        case .sentArchiveBlockedUnconfigured:
            switch language {
            case .zhHans: return "内容已发送，云端同步尚未配置，暂时无法归档。片段已保留，可重试归档"
            case .en: return "Sent, but Cloud Sync is not configured to archive yet. Clips remain checked to retry archiving."
            }
        case .sentPartialArchiveFailure:
            switch language {
            case .zhHans: return "内容已发送，部分片段未能归档或已不在最近片段列表中。未归档片段已保留，再次点击只重试归档"
            case .en: return "Sent, but some clips could not be archived. Unarchived clips are kept; click again to retry archiving without resending."
            }
        case .sentToNewConversation(let count, let host):
            switch language {
            case .zhHans: return "已将 \(count) 条片段发送到 \(host.displayName) 的新对话"
            case .en:
                let noun = count == 1 ? "clip" : "clips"
                return "Sent \(count) \(noun) to a new \(host.displayName) chat."
            }
        case .sentOpenConversationFailed(let host):
            switch language {
            case .zhHans: return "已发送到 \(host.displayName)，但未能打开对话。可重新打开，不会重复发送"
            case .en: return "Sent to \(host.displayName), but could not open the chat. You can reopen it without resending."
            }
        case .requestExpired(let host):
            switch language {
            case .zhHans: return "发送请求已过期，内容未发送。片段已保留，请打开 \(host.displayName) 后重试"
            case .en: return "Handoff request expired before sending. Clips are kept; open \(host.displayName) and try again."
            }
        case .hostRejected(let host):
            switch language {
            case .zhHans: return "\(host.displayName) 暂时无法接收片段，内容未发送。请检查应用是否已安装并重试"
            case .en: return "\(host.displayName) could not accept clips right now; nothing was sent. Check that the app is installed and try again."
            }
        case .deliveryUnconfirmed(let host):
            switch language {
            case .zhHans: return "无法确认是否发送成功，已停止自动重发。请到 \(host.displayName) 检查新对话，片段尚未归档"
            case .en: return "Could not confirm delivery; automatic retry stopped. Check \(host.displayName) for a new chat; clips remain unarchived."
            }
        case .stillWaitingForReceipt:
            switch language {
            case .zhHans: return "尚未收到发送结果，片段和请求已保留。再次点击只查询结果，不会重复发送"
            case .en: return "Still waiting for delivery confirmation; clips and request are kept. Click again to check status without resending."
            }
        case .clearedUnconfirmedRequest:
            switch language {
            case .zhHans: return "已清除本次待确认请求。重新勾选片段后可开始新对话"
            case .en: return "Cleared the unconfirmed request. Select clips again to start a new chat."
            }
        case .retainedUnarchivedCards:
            switch language {
            case .zhHans: return "未归档片段已保留。重新勾选后可开始新对话"
            case .en: return "Unarchived clips are kept. Select clips again to start a new chat."
            }
        case .reopenConversationFailed:
            switch language {
            case .zhHans: return "内容已发送，但未能打开对话。请重试打开"
            case .en: return "Clips were sent, but the chat could not be opened. Try opening again."
            }
        case .openedConversation(let host):
            switch language {
            case .zhHans: return "已打开 \(host.displayName) 对话"
            case .en: return "Opened \(host.displayName) chat."
            }
        case .resumeUnarchivedStartup:
            switch language {
            case .zhHans: return "片段已发送，但尚未全部归档。点击“重试归档”继续，不会重复发送"
            case .en: return "Clips were sent, but archiving is incomplete. Click \"Retry Archive\" to continue without resending."
            }
        case .resumePendingStartup:
            switch language {
            case .zhHans: return "上次对话请求已保留，可继续处理，不会重复发送片段"
            case .en: return "Previous chat handoff is preserved. You can continue without resending clips."
            }
        case .archiveCardBlockedOfflineOrUnconfigured:
            switch language {
            case .zhHans: return "片段尚未同步或云端同步尚未配置，暂时无法归档"
            case .en: return "Clip is not synced yet or Cloud Sync is not configured; cannot archive right now."
            }
        case .savedConnectionSettings:
            switch language {
            case .zhHans: return "已保存云端同步设置"
            case .en: return "Saved Cloud Sync settings."
            }
        case .pluginInstalled:
            return pluginInstalledSummary(in: language)
        case .pluginNeedsRepair(let reason):
            return pluginNeedsRepairSummary(firstReason: reason, in: language)
        case .pluginInstallFailedRewind(let err):
            return pluginInstallFailedSummary(detail: rewindError(err, in: language), in: language)
        case .pluginInstallFailedMessage(let detail):
            return pluginInstallFailedSummary(detail: detail, in: language)
        case .rewindError(let err):
            return rewindError(err, in: language)
        case .custom(let raw):
            return raw
        }
    }
}

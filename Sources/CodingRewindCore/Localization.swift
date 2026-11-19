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
    case needsDSHPlugin
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
    case archivedClips(count: Int)
    case partialArchiveClipsFailure(succeeded: Int, failed: Int)
    case deletedClips(count: Int)
    case partialDeleteClipsFailure(succeeded: Int, failed: Int)
    case deleteCardBlockedOfflineOrUnconfigured
    case cardsLockedByActiveConversation
    case savedConnectionSettings
    case savedAIAccessMode(AIAccessMode)
    case aiAccessManagedByEnvironment
    case pluginInstalled
    case pluginNeedsRepair(PluginRepairReason?)
    case pluginInstallFailedRewind(RewindError)
    case pluginInstallFailedMessage(String)
    case dshPluginInstalled
    case dshPluginNeedsRepair(DSHPluginRepairReason?)
    case dshPluginInstallFailedRewind(RewindError)
    case dshPluginInstallFailedMessage(String)
    case openedDSHConversation
    case copiedDSHSessionFallback(String)
    case openURLFailed(String)
    case copiedSessionID(String)
    case copiedClipText
    case copiedDraftAndWokeHost(ConversationHost)
    case copiedDraftHostUnavailable(ConversationHost)
    case emptyConversationDraft
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
            case .snippetNotFound(let id):
                return "未找到片段：\(id)"
            case .invalidMemosURL(let raw):
                return "Memos 服务地址无效：\(raw)"
            case .missingCredentials:
                return "尚未设置 Memos 服务地址或访问令牌。"
            case .aiWriteDisabled:
                return "AI 写入权限当前处于只读模式（read_only），请在 Coding Rewind 设置的“插件与权限”中切换为读写模式，或检查环境变量 CODING_REWIND_AI_ACCESS。"
            case .invalidMetadataUpdate(let detail):
                return "片段更新参数无效：\(detail)"
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
            case .snippetNotFound(let id):
                return "Snippet not found: \(id)"
            case .invalidMemosURL(let raw):
                return "Invalid Memos server URL: \(raw)"
            case .missingCredentials:
                return "Memos server URL or access token is not configured."
            case .aiWriteDisabled:
                return "AI write access is disabled in read-only mode (read_only). Switch to Read & Write in Coding Rewind Settings > Plugin & Permissions, or check CODING_REWIND_AI_ACCESS."
            case .invalidMetadataUpdate(let detail):
                return "Invalid snippet update: \(detail)"
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

    public static func dshPluginRepairReason(_ reason: DSHPluginRepairReason, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch reason {
            case .notInstalled: return "尚未安装"
            case .missingBundledPlugin: return "缺少内置 DSH 插件，请用完整应用包安装"
            case .missingCLIBinary: return "未找到 DeepSeek Harness（dsh）命令行工具"
            case .missingProfilePackage: return "未找到 DSH 桌面端配置（profiles/desktop/package.json）"
            case .pluginNotRegisteredInProfile: return "DSH 桌面端配置中未注册插件"
            case .stagedPluginMissingOrOutdated: return "本地插件文件缺失或版本已过期"
            case .invalidRuntimeConfig: return "插件数据目录配置缺失或不匹配"
            }
        case .en:
            switch reason {
            case .notInstalled: return "not installed"
            case .missingBundledPlugin: return "bundled DSH plugin missing; install from packaged app bundle"
            case .missingCLIBinary: return "DeepSeek Harness (dsh) CLI not found"
            case .missingProfilePackage: return "DSH desktop profile package.json not found"
            case .pluginNotRegisteredInProfile: return "plugin not registered in DSH desktop profile"
            case .stagedPluginMissingOrOutdated: return "staged plugin files missing or outdated"
            case .invalidRuntimeConfig: return "missing or mismatched plugin dataDir config"
            }
        }
    }

    public static func dshPluginInstalledSummary(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "DSH 插件已安装"
        case .en: return "DSH plugin installed"
        }
    }

    public static func dshPluginInstallRestartHint(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "DSH 插件已安装，重启 DeepSeek Harness 后生效"
        case .en: return "DSH plugin installed. Restart DeepSeek Harness to activate."
        }
    }

    public static func dshPluginNeedsRepairSummary(firstReason: DSHPluginRepairReason?, in language: AppLanguage) -> String {
        let detail = dshPluginRepairReason(firstReason ?? .notInstalled, in: language)
        switch language {
        case .zhHans: return "DSH 插件需要安装或修复（\(detail)）"
        case .en: return "DSH plugin needs install or repair (\(detail))"
        }
    }

    public static func dshPluginInstallFailedSummary(detail: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "DSH 插件安装失败：\(detail)"
        case .en: return "DSH plugin installation failed: \(detail)"
        }
    }

    public static func filledIntoNewDSHConversation(count: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已将 \(count) 条片段填入 DSH 新会话"
        case .en:
            let noun = count == 1 ? "clip" : "clips"
            return "Filled \(count) \(noun) into a new DSH chat."
        }
    }

    public static func mcpServiceStatusSummary(
        isInstalled: Bool,
        mode: AIAccessMode,
        in language: AppLanguage
    ) -> String {
        guard isInstalled else {
            switch language {
            case .zhHans:
                return "命令行与 MCP 组件尚未安装至 Application Support/CodingRewind/bin/，请点击“安装或修复插件”完成部署。"
            case .en:
                return "The coding-rewind helper binary is not yet staged in Application Support/CodingRewind/bin/. Click \"Install or Repair Plugin\" to deploy it."
            }
        }
        switch (language, mode) {
        case (.zhHans, .readWrite):
            return "本机 MCP 服务已就绪（读写）：已启用全部 7 个片段工具，支持检索、新建、改写元数据、追加笔记与归档；彻底删除不向 AI 开放。"
        case (.en, .readWrite):
            return "Local MCP service ready (Read & Write): all 7 snippet tools are active for search, creation, metadata updates, notes, and archiving. Physical deletion is never exposed to AI."
        case (.zhHans, .readOnly):
            return "本机 MCP 服务已就绪（只读）：已启用 3 个只读检索工具，已拦截新建、改写元数据、追加笔记与归档 4 个写入工具。"
        case (.en, .readOnly):
            return "Local MCP service ready (Read-Only): 3 read tools are active; all 4 write tools (create, metadata update, note, and archive) are blocked."
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
        case .needsDSHPlugin:
            switch language {
            case .zhHans: return "请先安装或修复 DSH 插件，再填入新会话。所选片段已保留"
            case .en: return "Install or repair the DSH plugin before filling a new chat. Selected clips remain checked."
            }
        case .waitingForHostConfirmation(let host):
            switch (host, language) {
            case (.dsh, .zhHans): return "正在等待 DSH 确认填入…"
            case (.dsh, .en): return "Waiting for DSH to confirm…"
            case (.antigravity, .zhHans): return "正在等待 \(host.displayName) 确认发送结果…"
            case (.antigravity, .en): return "Waiting for \(host.displayName) to confirm delivery…"
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
            switch host {
            case .dsh:
                return filledIntoNewDSHConversation(count: count, in: language)
            case .antigravity:
                switch language {
                case .zhHans: return "已将 \(count) 条片段发送到 \(host.displayName) 的新对话"
                case .en:
                    let noun = count == 1 ? "clip" : "clips"
                    return "Sent \(count) \(noun) to a new \(host.displayName) chat."
                }
            }
        case .sentOpenConversationFailed(let host):
            switch language {
            case .zhHans: return "已发送到 \(host.displayName)，但未能打开对话。可重新打开，不会重复发送"
            case .en: return "Sent to \(host.displayName), but could not open the chat. You can reopen it without resending."
            }
        case .requestExpired(let host):
            switch (host, language) {
            case (.dsh, .zhHans): return "填入请求已过期，草稿未填入。片段已保留，请打开 DSH 后重试"
            case (.dsh, .en): return "Prefill request expired before DSH confirmed. Clips are kept; open DSH and try again."
            case (.antigravity, .zhHans): return "发送请求已过期，内容未发送。片段已保留，请打开 \(host.displayName) 后重试"
            case (.antigravity, .en): return "Handoff request expired before sending. Clips are kept; open \(host.displayName) and try again."
            }
        case .hostRejected(let host):
            switch (host, language) {
            case (.dsh, .zhHans): return "DSH 暂时无法填入草稿，请检查工作区或输入框状态后重试"
            case (.dsh, .en): return "DSH could not fill the draft right now. Check the active workspace or composer and try again."
            case (.antigravity, .zhHans): return "\(host.displayName) 暂时无法接收片段，内容未发送。请检查应用是否已安装并重试"
            case (.antigravity, .en): return "\(host.displayName) could not accept clips right now; nothing was sent. Check that the app is installed and try again."
            }
        case .deliveryUnconfirmed(let host):
            switch (host, language) {
            case (.dsh, .zhHans): return "无法确认是否已填入 DSH，已停止自动重发。请到 DSH 检查新会话草稿，片段尚未归档"
            case (.dsh, .en): return "Could not confirm DSH prefill; automatic retry stopped. Check DSH for a new draft; clips remain unarchived."
            case (.antigravity, .zhHans): return "无法确认是否发送成功，已停止自动重发。请到 \(host.displayName) 检查新对话，片段尚未归档"
            case (.antigravity, .en): return "Could not confirm delivery; automatic retry stopped. Check \(host.displayName) for a new chat; clips remain unarchived."
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
        case .archivedClips(let count):
            switch language {
            case .zhHans: return "已归档 \(count) 条片段，原文仍保留在 Memos 中"
            case .en:
                let noun = count == 1 ? "clip" : "clips"
                return "Archived \(count) \(noun); originals remain in Memos."
            }
        case .partialArchiveClipsFailure(let succeeded, let failed):
            switch language {
            case .zhHans: return "已归档 \(succeeded) 条片段，另有 \(failed) 条归档失败，已保留在列表中"
            case .en:
                let succeededNoun = succeeded == 1 ? "clip" : "clips"
                let failedNoun = failed == 1 ? "clip" : "clips"
                return "Archived \(succeeded) \(succeededNoun), but \(failed) \(failedNoun) failed and remain in the list."
            }
        case .deletedClips(let count):
            switch language {
            case .zhHans: return "已删除 \(count) 条片段"
            case .en:
                let noun = count == 1 ? "clip" : "clips"
                return "Deleted \(count) \(noun)."
            }
        case .partialDeleteClipsFailure(let succeeded, let failed):
            switch language {
            case .zhHans: return "已删除 \(succeeded) 条片段，另有 \(failed) 条删除失败，已保留在列表中"
            case .en:
                let succeededNoun = succeeded == 1 ? "clip" : "clips"
                let failedNoun = failed == 1 ? "clip" : "clips"
                return "Deleted \(succeeded) \(succeededNoun), but \(failed) \(failedNoun) failed and remain in the list."
            }
        case .deleteCardBlockedOfflineOrUnconfigured:
            switch language {
            case .zhHans: return "已同步片段需要连接已配置的 Memos 后才能删除"
            case .en: return "Synced clips require a configured Memos connection to delete."
            }
        case .cardsLockedByActiveConversation:
            switch language {
            case .zhHans: return "当前仍有未结束的对话请求关联这些片段，请先完成或结束该请求"
            case .en: return "These clips are locked by an active chat handoff. Finish or clear that request first."
            }
        case .savedConnectionSettings:
            switch language {
            case .zhHans: return "已保存云端同步设置"
            case .en: return "Saved Cloud Sync settings."
            }
        case .savedAIAccessMode(let mode):
            switch (language, mode) {
            case (.zhHans, .readOnly):
                return "已切换为只读模式：AI 仅可检索片段，4 个写入工具已拦截"
            case (.en, .readOnly):
                return "Switched to Read-Only mode: AI write tools are now blocked."
            case (.zhHans, .readWrite):
                return "已切换为读写模式：AI 可追加批注、新建片段与更新元数据"
            case (.en, .readWrite):
                return "Switched to Read & Write mode: AI can now attach notes, create clips, and update metadata."
            }
        case .aiAccessManagedByEnvironment:
            switch language {
            case .zhHans: return "AI 写入权限由环境变量 CODING_REWIND_AI_ACCESS 接管，不能在设置中修改"
            case .en: return "AI access permission is managed by CODING_REWIND_AI_ACCESS and cannot be changed in Settings."
            }
        case .pluginInstalled:
            return pluginInstalledSummary(in: language)
        case .pluginNeedsRepair(let reason):
            return pluginNeedsRepairSummary(firstReason: reason, in: language)
        case .pluginInstallFailedRewind(let err):
            return pluginInstallFailedSummary(detail: rewindError(err, in: language), in: language)
        case .pluginInstallFailedMessage(let detail):
            return pluginInstallFailedSummary(detail: detail, in: language)
        case .dshPluginInstalled:
            return dshPluginInstallRestartHint(in: language)
        case .dshPluginNeedsRepair(let reason):
            return dshPluginNeedsRepairSummary(firstReason: reason, in: language)
        case .dshPluginInstallFailedRewind(let err):
            return dshPluginInstallFailedSummary(detail: rewindError(err, in: language), in: language)
        case .dshPluginInstallFailedMessage(let detail):
            return dshPluginInstallFailedSummary(detail: detail, in: language)
        case .openedDSHConversation:
            switch language {
            case .zhHans: return "已在 DSH 中打开原对话"
            case .en: return "Opened original conversation in DSH."
            }
        case .copiedDSHSessionFallback(let sessionID):
            switch language {
            case .zhHans: return "未能直达 DSH 原对话，已复制会话 ID：\(sessionID)"
            case .en: return "Could not jump to DSH conversation; copied Session ID: \(sessionID)"
            }
        case .openURLFailed(let rawURL):
            switch language {
            case .zhHans: return "未能打开链接：\(rawURL)"
            case .en: return "Could not open link: \(rawURL)"
            }
        case .copiedSessionID(let sessionID):
            switch language {
            case .zhHans: return "已复制会话 ID：\(sessionID)"
            case .en: return "Copied Session ID: \(sessionID)"
            }
        case .copiedClipText:
            switch language {
            case .zhHans: return "已拷贝片段原文"
            case .en: return "Copied clip text."
            }
        case .copiedDraftAndWokeHost(let host):
            switch language {
            case .zhHans: return "已复制草稿并唤醒 \(host.displayName)，可直接粘贴发送"
            case .en: return "Copied draft and woke \(host.displayName) — paste to send."
            }
        case .copiedDraftHostUnavailable(let host):
            switch language {
            case .zhHans: return "已复制草稿，但未找到 \(host.displayName)，请打开应用后粘贴发送"
            case .en: return "Copied draft, but \(host.displayName) was not found — open the app and paste to send."
            }
        case .emptyConversationDraft:
            switch language {
            case .zhHans: return "接聊草稿不能为空"
            case .en: return "Chat draft cannot be empty."
            }
        case .rewindError(let err):
            return rewindError(err, in: language)
        case .custom(let raw):
            return raw
        }
    }
}

// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

extension AppStrings {
    static func updaterStatusSummary(
        state: AppUpdater.State,
        lastCheckedAt: Date?,
        in language: AppLanguage
    ) -> String {
        let lastCheckedSuffix: String
        if let lastCheckedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = language.locale
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: lastCheckedAt, relativeTo: Date())
            switch language {
            case .zhHans: lastCheckedSuffix = "（上次检查：\(relative)）"
            case .en: lastCheckedSuffix = " (last checked \(relative))"
            }
        } else {
            lastCheckedSuffix = ""
        }

        switch state {
        case .idle:
            switch language {
            case .zhHans: return "尚未检查更新\(lastCheckedSuffix)"
            case .en: return "Not checked yet\(lastCheckedSuffix)"
            }
        case .checking:
            switch language {
            case .zhHans: return "正在从 GitHub Releases 检查更新…"
            case .en: return "Checking GitHub Releases for updates…"
            }
        case .upToDate(let ver):
            switch language {
            case .zhHans: return "已是最新版本（v\(ver.description)）\(lastCheckedSuffix)"
            case .en: return "Up to date (v\(ver.description))\(lastCheckedSuffix)"
            }
        case .updateAvailable(let candidate):
            switch language {
            case .zhHans: return "发现新版本 v\(candidate.version.description)"
            case .en: return "Update available: v\(candidate.version.description)"
            }
        case .downloading(let candidate):
            switch language {
            case .zhHans: return "正在下载 v\(candidate.version.description)…"
            case .en: return "Downloading v\(candidate.version.description)…"
            }
        case .verifying(let candidate):
            switch language {
            case .zhHans: return "正在校验 v\(candidate.version.description) 的校验和与签名…"
            case .en: return "Verifying checksum and code signature for v\(candidate.version.description)…"
            }
        case .readyToInstall(let staged):
            switch language {
            case .zhHans: return "新版本 v\(staged.candidate.version.description) 已通过校验，重启即可完成更新。"
            case .en: return "v\(staged.candidate.version.description) is verified and ready. Restart to finish updating."
            }
        case .manualDownloadRequired(let candidate, let reason):
            switch language {
            case .zhHans:
                switch reason {
                case .missingChecksum:
                    return "发现 v\(candidate.version.description)，但缺少 SHA256SUMS.txt 校验文件，请前往 GitHub 手动核验下载。"
                case .signatureDowngradeBlocked:
                    return "发现 v\(candidate.version.description)，但其签名权限与当前已安装版本不兼容（为保护辅助功能授权已拦截自动替换），请前往 GitHub 查看。"
                case .bundleIdentifierMismatch:
                    return "发现 v\(candidate.version.description)，但应用包标识符不匹配，请前往 GitHub 手动下载。"
                case .installLocationNotWritable:
                    return "发现 v\(candidate.version.description)，但当前安装目录不可写，请前往 GitHub 手动下载替换。"
                case .nonAppBundleInstall:
                    return "发现 v\(candidate.version.description)，当前未以 .app 应用包运行，请前往 GitHub 手动下载。"
                }
            case .en:
                switch reason {
                case .missingChecksum:
                    return "v\(candidate.version.description) is available, but SHA256SUMS.txt is missing. Download manually from GitHub."
                case .signatureDowngradeBlocked:
                    return "v\(candidate.version.description) has an incompatible code signature (blocked to preserve Accessibility permissions). View on GitHub."
                case .bundleIdentifierMismatch:
                    return "v\(candidate.version.description) bundle identifier does not match. Download manually from GitHub."
                case .installLocationNotWritable:
                    return "v\(candidate.version.description) is available, but the install folder is not writable. Download manually from GitHub."
                case .nonAppBundleInstall:
                    return "v\(candidate.version.description) is available. Running outside an .app bundle; download manually from GitHub."
                }
            }
        case .installing(let ver):
            switch language {
            case .zhHans: return "正在安装 v\(ver.description) 并重新启动…"
            case .en: return "Installing v\(ver.description) and restarting…"
            }
        case .failed(let message):
            return message
        }
    }

    static func checkForUpdatesButton(isBusy: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return isBusy ? "检查中…" : "检查更新"
        case .en: return isBusy ? "Checking…" : "Check for Updates"
        }
    }

    static func aboutVersionLine(version: String?, build: String?, in language: AppLanguage) -> String {
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = trimmedVersion.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBuild = trimmedBuild.flatMap { $0.isEmpty ? nil : $0 }

        switch language {
        case .zhHans:
            guard let resolvedVersion else {
                return "MIT 许可证"
            }
            if let resolvedBuild {
                return "版本 \(resolvedVersion)（Build \(resolvedBuild)） · MIT 许可证"
            }
            return "版本 \(resolvedVersion) · MIT 许可证"
        case .en:
            guard let resolvedVersion else {
                return "MIT License"
            }
            if let resolvedBuild {
                return "Version \(resolvedVersion) (Build \(resolvedBuild)) · MIT License"
            }
            return "Version \(resolvedVersion) · MIT License"
        }
    }

    static func aboutSummary(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "跨 AI 对话与网页顺手暂存灵感片段，保留提问脉络并一键接聊。"
        case .en: return "Stash highlights across AI chats and the web with conversation context intact."
        }
    }

    static func aboutGitHubRepoButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "GitHub 仓库 ↗"
        case .en: return "GitHub Repository ↗"
        }
    }

    static func aboutReleaseNotesButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "发布版本与更新日志 ↗"
        case .en: return "Releases & Changelog ↗"
        }
    }

    static func aboutGitHubRepoAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "GitHub 仓库"
        case .en: return "GitHub Repository"
        }
    }

    static func aboutReleaseNotesAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "发布版本与更新日志"
        case .en: return "Releases & Changelog"
        }
    }

    static func restartToUpdateButton(version: SemanticVersion, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重启并更新至 v\(version.description)"
        case .en: return "Restart to Update (v\(version.description))"
        }
    }

    static func viewReleaseOnGitHubButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "前往 GitHub 查看…"
        case .en: return "View on GitHub…"
        }
    }

    static func dockSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Dock 图标"
        case .en: return "Dock Icon"
        }
    }

    static func showInDockTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "在 Dock 中显示"
        case .en: return "Show Icon in Dock"
        }
    }

    static func showInDockHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "点击 Dock 图标或从 Finder 打开应用，会显示片段浮窗。"
        case .en: return "Clicking the Dock icon or opening the app from Finder brings up the Clips HUD."
        }
    }

    static func menuBarSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "菜单栏"
        case .en: return "Menu Bar"
        }
    }

    static func menuBarIconTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "菜单栏图标"
        case .en: return "Menu Bar Icon"
        }
    }

    static func menuBarIconHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "点击图标可查看最近片段、保存所选文本或打开设置。若图标未显示，请在系统菜单栏设置中允许 Coding Rewind。"
        case .en: return "Click the menu bar icon to view recent clips, save selected text, or open Settings. Allow Coding Rewind in Control Center settings if hidden."
        }
    }

    static func openMenuBarSettingsButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "打开系统菜单栏设置…"
        case .en: return "Open Menu Bar Settings…"
        }
    }

    static func selectionPopupSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "划词暂存"
        case .en: return "Selection Stash Capsule"
        }
    }

    static func showSelectionPopupTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "选中文本时显示暂存胶囊"
        case .en: return "Show Stash Capsule on Selection"
        }
    }

    static func showSelectionPopupHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "在 Antigravity、ChatGPT 与 Gemini 桌面端选中对话文本后，自动在选区附近显示快捷暂存按钮。"
        case .en: return "Shows a non-activating Stash button near selected conversation text in Antigravity, ChatGPT, and Gemini desktop."
        }
    }

    static func memosServiceSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "自建 Memos 服务"
        case .en: return "Self-hosted Memos Server"
        }
    }

    static let deploymentGuideURL = URL(string: "https://github.com/semantic-craft/coding-rewind/tree/main/deploy/vps")!

    static func cloudSyncLocalOnlyIntro(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "不配置也能用。片段会先保存在本机，仍可在 Antigravity 或 Codex 中开始对话。"
        case .en: return "Works without setup. Clips stay on this Mac, and you can still start chats in Antigravity or Codex."
        }
    }

    static func cloudSyncServerIntro(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "配置自建 Memos 服务后，可跨设备同步片段，并自动生成 AI 摘要。"
        case .en: return "Connect a self-hosted Memos server to sync clips across devices and get automatic AI summaries."
        }
    }

    static func deploymentGuideLink(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "查看部署指南 ↗"
        case .en: return "Deployment Guide ↗"
        }
    }

    static func getTokenButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "打开后台拿令牌 ↗"
        case .en: return "Get Token ↗"
        }
    }

    static func verifyingConnection(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "正在验证连接…"
        case .en: return "Verifying connection…"
        }
    }

    static func serverURLTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "服务地址"
        case .en: return "Server URL"
        }
    }

    static func serverURLManagedHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "服务地址由启动配置提供，不能在此修改。"
        case .en: return "Managed by launch environment and cannot be edited here."
        }
    }

    static func accessTokenTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "访问令牌"
        case .en: return "Access Token"
        }
    }

    static func accessTokenHelp(isManaged: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return isManaged
                ? "访问令牌由启动配置提供，不能在此修改。"
                : "请填写在 Memos 中生成的访问令牌。令牌保存在 macOS 钥匙串中。"
        case .en:
            return isManaged
                ? "Managed by launch environment and cannot be edited here."
                : "Enter a personal access token generated in Memos. Stored securely in macOS Keychain."
        }
    }

    static func accessTokenPlaceholder(hasSavedToken: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return hasSavedToken ? "已保存，留空则保留现有令牌" : "请输入访问令牌"
        case .en: return hasSavedToken ? "Saved; leave blank to keep existing token" : "Enter access token"
        }
    }

    static func saveConnectionButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "保存连接设置"
        case .en: return "Save Connection"
        }
    }

    static func syncSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "同步与提示"
        case .en: return "Sync & Status"
        }
    }

    static func syncClipsRowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "同步片段"
        case .en: return "Sync Clips"
        }
    }

    static func defaultSyncBannerHint(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "从 Memos 获取最新片段，并上传本机待同步的片段。"
        case .en: return "Fetches recent clips from Memos and uploads locally queued clips."
        }
    }

    static func globalShortcutsSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "全局快捷键"
        case .en: return "Global Shortcuts"
        }
    }

    static func shortcutsDescription(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "点击快捷键可修改，清空后停用。⌃ 是 Control，⌥ 是 Option，⇧ 是 Shift，⌘ 是 Command。"
        case .en: return "Click a shortcut to record a new combination, or clear to disable. ⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command."
        }
    }

    static func restoreDefaultButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "恢复默认"
        case .en: return "Restore Default"
        }
    }

    static func retryButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重试"
        case .en: return "Retry"
        }
    }

    static func antigravityPluginSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Antigravity 插件"
        case .en: return "Antigravity Plugin"
        }
    }

    static func pluginStatusRowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "插件状态"
        case .en: return "Plugin Status"
        }
    }

    static func installOrRepairShortButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "安装或修复插件"
        case .en: return "Install or Repair Plugin"
        }
    }

    static func accessibilitySectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "辅助功能"
        case .en: return "Accessibility"
        }
    }

    static func readSelectedTextRowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "读取所选文本"
        case .en: return "Read Selected Text"
        }
    }

    static func recheckPermissionButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重新核对权限"
        case .en: return "Recheck Permission"
        }
    }

    static func recheckPermissionAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重新核对辅助功能权限"
        case .en: return "Recheck Accessibility Permission"
        }
    }

    static func openSystemSettingsButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "前往系统设置…"
        case .en: return "Open System Settings…"
        }
    }

    static func openSystemSettingsAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "前往系统设置，允许读取所选文本"
        case .en: return "Open System Settings to allow reading selected text"
        }
    }

    static func resetStaleApprovalButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重置失效授权…"
        case .en: return "Reset Stale Approval…"
        }
    }

    static func accessibilityDescription(isTrusted: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return isTrusted
                ? "已授权，可读取其他应用中所选的文本。"
                : "未授权，需要在系统设置中允许读取其他应用的所选文本。若升级后系统设置中已开启但仍未生效，点击“重置失效授权…”可清除旧版本的失效签名记录。"
        case .en:
            return isTrusted
                ? "Granted. Coding Rewind can read selected text in supported apps."
                : "Not granted. Allow Coding Rewind in System Settings > Accessibility. If already toggled on after an update, click \"Reset Stale Approval…\" to clear outdated code-signature entries."
        }
    }

    static func syncNowHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "立即同步 (⌘R)"
        case .en: return "Sync Now (⌘R)"
        }
    }

    static func settingsLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "设置"
        case .en: return "Settings"
        }
    }

    static func settingsShortcutHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "设置… (⌘,)"
        case .en: return "Settings… (⌘,)"
        }
    }

    static func closeHUDLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关闭片段浮窗"
        case .en: return "Close Clips HUD"
        }
    }

    static func closeHUDHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关闭片段浮窗 (Esc)"
        case .en: return "Close Clips HUD (Esc)"
        }
    }

    static func dismissBannerLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关闭提示"
        case .en: return "Dismiss Notice"
        }
    }

    static func updateReadyHUDTitle(version: SemanticVersion, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "新版本 v\(version.description) 已通过校验"
        case .en: return "Update v\(version.description) verified and ready"
        }
    }

    static func restartToUpdateShortButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重启更新"
        case .en: return "Restart to Update"
        }
    }

    static func searchPlaceholder(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "搜索标题、摘要或原文…"
        case .en: return "Search title, summary, or text…"
        }
    }

    static func searchAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "搜索标题、摘要或原文"
        case .en: return "Search title, summary, or text"
        }
    }

    static func keepClipsSkipArchiveButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "暂不归档，保留片段"
        case .en: return "Skip Archiving & Keep Clips"
        }
    }

    static func clearUnconfirmedButton(hostName: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已检查 \(hostName)，清除待确认请求"
        case .en: return "Checked \(hostName) — Clear Pending Request"
        }
    }

    static func openCodexChatButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "打开 Codex 对话"
        case .en: return "Open Codex Chat"
        }
    }

    static func selectedCountText(count: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已选 \(count) 条"
        case .en: return "\(count) selected"
        }
    }

    static func archiveOnLaunchTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "发送后归档"
        case .en: return "Archive After Send"
        }
    }

    static func archiveOnLaunchHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "成功发送后，将所选片段从最近片段列表中移除。原文仍保留在 Memos 中。"
        case .en: return "Removes selected clips from the hot stream once sent. Original memos remain in Memos."
        }
    }

    static func conversationHostLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "对话应用"
        case .en: return "Chat App"
        }
    }

    static func emptyStateHeading(isAllCardsEmpty: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return isAllCardsEmpty ? "近 72 小时没有保存的片段" : "没有符合筛选条件的片段"
        case .en:
            return isAllCardsEmpty ? "No clips saved in the last 72 hours" : "No clips match the current filter"
        }
    }

    static func emptyBulletToggleAndLaunch(toggleInstruction: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "• \(toggleInstruction)，勾选片段后按 ⌘↵ 开始对话"
        case .en: return "• \(toggleInstruction), select clips, and press ⌘↵ to start a chat"
        }
    }

    static func emptyBulletMemosAndOffline(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "• 在设置中填写 Memos 服务地址和访问令牌后可同步，离线时也可保存片段"
        case .en: return "• Configure your Memos server URL and access token in Settings to sync; clips also save offline"
        }
    }

    static func clearFiltersButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "清除筛选"
        case .en: return "Clear Filters"
        }
    }

    static func pendingSyncBadge(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "待同步"
        case .en: return "Pending Sync"
        }
    }

    static func viewSourceButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "查看来源 ↗"
        case .en: return "Source ↗"
        }
    }

    static func archiveClipLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "归档片段"
        case .en: return "Archive Clip"
        }
    }

    static func archiveClipHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "归档片段 (⌘E)，从最近片段中移除，原文仍保留在 Memos 中"
        case .en: return "Archive Clip (⌘E). Removes from hot stream; original remains in Memos."
        }
    }

    static func deleteClipLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "删除片段"
        case .en: return "Delete Clip"
        }
    }

    static func deleteClipHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "删除片段 (⌘⌫，按住 ⌥ 立即删除)"
        case .en: return "Delete Clip (⌘⌫, hold ⌥ to delete immediately)"
        }
    }

    static func copyClipTextMenu(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "拷贝原文"
        case .en: return "Copy Text"
        }
    }

    static func deleteClipMenuEllipsis(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "删除片段…"
        case .en: return "Delete Clip…"
        }
    }

    static func archiveSelectedShortButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "归档"
        case .en: return "Archive"
        }
    }

    static func archiveSelectedHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "归档已选片段 (⌘E)，原文仍保留在 Memos 中"
        case .en: return "Archive selected clips (⌘E). Originals remain in Memos."
        }
    }

    static func deleteSelectedShortButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "删除"
        case .en: return "Delete"
        }
    }

    static func deleteSelectedHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "删除已选片段 (⌘⌫，按住 ⌥ 立即删除)"
        case .en: return "Delete selected clips (⌘⌫, hold ⌥ to delete immediately)"
        }
    }

    static func deleteConfirmationMessage(count: Int, allOfflinePending: Bool, in language: AppLanguage) -> String {
        let noun = count == 1 ? "clip" : "clips"
        switch (language, allOfflinePending) {
        case (.zhHans, true):
            return "确定删除选中的 \(count) 条待同步片段？删除后将从本机移除。"
        case (.en, true):
            return "Delete \(count) pending \(noun)? This removes them from this Mac."
        case (.zhHans, false):
            return "确定彻底删除选中的 \(count) 条片段？将从 Memos 与本机永久移除且不可撤销。"
        case (.en, false):
            return "Permanently delete \(count) \(noun)? This removes them from Memos and cannot be undone."
        }
    }

    static func cancelButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "取消"
        case .en: return "Cancel"
        }
    }

    static func confirmDeleteButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "彻底删除"
        case .en: return "Delete"
        }
    }

    static func startupFailedAlertTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Coding Rewind 未能启动"
        case .en: return "Coding Rewind Could Not Start"
        }
    }

    static func updaterFailureMessage(_ notice: AppUpdater.FailureNotice, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch notice {
            case .sha256Mismatch:
                return "安装包 SHA-256 校验不匹配，已拒绝安装。"
            case .missingAppInArchive:
                return "更新压缩包中未找到有效的应用包。"
            case .tamperedSignature:
                return "更新包代码签名校验失败，已拒绝安装。"
            case .httpStatus(let code, let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "GitHub Releases 请求失败（HTTP \(code)）。"
                    : "GitHub Releases 请求失败（HTTP \(code)）：\(trimmed)"
            case .parse(let parseError):
                switch parseError {
                case .invalidJSON:
                    return "GitHub Releases 返回的数据格式无效。"
                case .draftOrPrerelease:
                    return "最新 GitHub Release 为草稿或预发布版本，已跳过自动更新。"
                case .invalidVersionTag(let tag):
                    return "GitHub Release 版本标签无效：\(tag)"
                case .invalidReleaseURL(let url):
                    return "GitHub Release 下载地址无效或不安全：\(url)"
                case .missingMacOSArchiveAsset:
                    return "最新 GitHub Release 中未找到 macOS 安装包。"
                }
            case .rewind(let err):
                return "检查更新失败：\(err.localizedDescription(in: .zhHans))"
            case .other(let detail):
                return "检查更新失败：\(detail)"
            }
        case .en:
            switch notice {
            case .sha256Mismatch:
                return "Archive SHA-256 checksum mismatch; update was rejected."
            case .missingAppInArchive:
                return "No valid application bundle was found in the update archive."
            case .tamperedSignature:
                return "Code signature verification failed; update was rejected."
            case .httpStatus(let code, let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "GitHub Releases request failed (HTTP \(code))."
                    : "GitHub Releases request failed (HTTP \(code)): \(trimmed)"
            case .parse(let parseError):
                switch parseError {
                case .invalidJSON:
                    return "Invalid release metadata returned from GitHub Releases."
                case .draftOrPrerelease:
                    return "Latest GitHub Release is a draft or prerelease; automatic update skipped."
                case .invalidVersionTag(let tag):
                    return "Invalid GitHub Release version tag: \(tag)"
                case .invalidReleaseURL(let url):
                    return "Invalid or insecure GitHub Release URL: \(url)"
                case .missingMacOSArchiveAsset:
                    return "No macOS archive asset found in the latest GitHub Release."
                }
            case .rewind(let err):
                return "Update check failed: \(err.localizedDescription(in: .en))"
            case .other(let detail):
                return "Update check failed: \(detail)"
            }
        }
    }

    static func aiAccessSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "AI 接入与权限"
        case .en: return "AI Access & Permissions"
        }
    }

    static func mcpServiceRowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "MCP 服务状态"
        case .en: return "Local MCP Service"
        }
    }

    static func copyMCPConfigButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "复制 MCP JSON 配置"
        case .en: return "Copy MCP JSON Config"
        }
    }

    static func copiedMCPConfigFeedback(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已复制"
        case .en: return "Copied"
        }
    }

    static func mcpConfigCompatibilityCaption(in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "兼容 Claude Desktop、Cursor、Codex、Antigravity 等 MCP 客户端。访问令牌始终保存在 macOS 钥匙串中，不会写入 JSON 配置。"
        case .en:
            return "Compatible with Claude Desktop, Cursor, Codex, Antigravity, and other MCP clients. Access tokens stay in macOS Keychain and are never written to JSON."
        }
    }

    static func aiAccessPermissionRowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "AI 写入权限"
        case .en: return "AI Access Permission"
        }
    }

    static func aiAccessModeOptionTitle(_ mode: AIAccessMode, in language: AppLanguage) -> String {
        switch (language, mode) {
        case (.zhHans, .readOnly):
            return "只读（仅检索）"
        case (.en, .readOnly):
            return "Read-Only"
        case (.zhHans, .readWrite):
            return "允许读写（批注与新建）"
        case (.en, .readWrite):
            return "Read & Write"
        }
    }

    static func aiAccessPermissionHelp(isManaged: Bool, in language: AppLanguage) -> String {
        switch (language, isManaged) {
        case (.zhHans, true):
            return "当前由启动环境变量 CODING_REWIND_AI_ACCESS 接管，不能在此修改。"
        case (.en, true):
            return "Managed by environment variable CODING_REWIND_AI_ACCESS and cannot be edited here."
        case (.zhHans, false):
            return "切换后立即生效，同步控制 coding-rewind mcp 写入工具与开始对话提示词中的回写引导。"
        case (.en, false):
            return "Takes effect immediately for coding-rewind mcp write tools and Start Chat write-back prompts."
        }
    }
}

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
        case .zhHans: return isBusy ? "检查中…" : "立即检查"
        case .en: return isBusy ? "Checking…" : "Check Now"
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
        case .zhHans: return "在 Antigravity 与 Gemini 桌面端选中对话文本后，自动在选区上方显示快捷暂存按钮。"
        case .en: return "Shows a non-activating Stash button above selected conversation text in Antigravity and Gemini desktop."
        }
    }

    static func memosServiceSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Memos 服务"
        case .en: return "Memos Server"
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

    static func accessTokenPlaceholder(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "留空则保留现有令牌"
        case .en: return "Leave blank to keep existing token"
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

    static func startupFailedAlertTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Coding Rewind 未能启动"
        case .en: return "Coding Rewind Could Not Start"
        }
    }
}

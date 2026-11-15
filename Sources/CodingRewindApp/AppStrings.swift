// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

enum AppStrings {
    static func languagePreferenceTitle(_ preference: AppLanguagePreference, in language: AppLanguage) -> String {
        switch preference {
        case .system:
            switch language {
            case .zhHans: return "跟随系统"
            case .en: return "Follow System"
            }
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }

    static func dockIconError(in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "无法更改 Dock 图标的显示状态，请重新打开应用后再试。"
        case .en:
            return "Could not change Dock icon visibility. Reopen the app and try again."
        }
    }

    static func shortcutTitle(_ action: ShortcutAction, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch action {
            case .captureSelection: return "保存所选文本"
            case .toggleHUD: return "显示或隐藏片段浮窗"
            }
        case .en:
            switch action {
            case .captureSelection: return "Save Selected Text"
            case .toggleHUD: return "Show or Hide Clips HUD"
            }
        }
    }

    static func shortcutDisabled(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已停用"
        case .en: return "Disabled"
        }
    }

    static func shortcutPausedHint(value: String, in language: AppLanguage) -> String {
        guard !value.isEmpty else { return shortcutDisabled(in: language) }
        switch language {
        case .zhHans: return "\(value)（暂停）"
        case .en: return "\(value) (Paused)"
        }
    }

    static func shortcutFailedHint(value: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "\(value)（未生效）"
        case .en: return "\(value) (Inactive)"
        }
    }

    static func shortcutInstructionActive(_ action: ShortcutAction, hint: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return action == .captureSelection
                ? "选中文本后按 \(hint) 即可保存"
                : "按 \(hint) 查看近 72 小时保存的片段"
        case .en:
            return action == .captureSelection
                ? "Select text and press \(hint) to save"
                : "Press \(hint) to view clips from the last 72 hours"
        }
    }

    static func shortcutInstructionUnassigned(title: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "“\(title)”的快捷键已停用，可在设置中重新指定"
        case .en: return "Shortcut for \"\(title)\" is disabled. Assign one in Settings."
        }
    }

    static func shortcutInstructionPaused(title: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "设置快捷键期间，“\(title)”暂时停用"
        case .en: return "\"\(title)\" is paused while recording a shortcut"
        }
    }

    static func shortcutInstructionFailed(title: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "“\(title)”的快捷键未生效，请在设置中重试或更换组合键"
        case .en: return "Shortcut for \"\(title)\" is inactive. Retry or choose another combination in Settings."
        }
    }

    static func shortcutStatusActive(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "已生效"
        case .en: return "Active"
        }
    }

    static func shortcutStatusPaused(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "录制期间暂停"
        case .en: return "Paused while recording"
        }
    }

    static func shortcutStatusFailed(status: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "快捷键未生效（错误代码 \(status)）。请重试或更换组合键"
        case .en: return "Shortcut inactive (error \(status)). Retry or choose another combination."
        }
    }

    static func shortcutValidationNeedsModifier(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "字母等普通按键请至少搭配 ⌃、⌥、⌘ 中的一个修饰键。"
        case .en: return "Standard keys must include at least one of ⌃, ⌥, or ⌘."
        }
    }

    static func shortcutValidationSystemTaken(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "此组合键已由系统使用，请选择其他快捷键。"
        case .en: return "This shortcut is already used by macOS. Choose another combination."
        }
    }

    static func shortcutValidationDuplicateAction(otherTitle: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "此组合键已用于“\(otherTitle)”。"
        case .en: return "This shortcut is already assigned to \"\(otherTitle)\"."
        }
    }

    static func shortcutValidationMenuConflict(menuTitle: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "此组合键用于菜单“\(menuTitle)”，请选择其他快捷键。"
        case .en: return "This shortcut conflicts with menu item \"\(menuTitle)\". Choose another combination."
        }
    }

    static func selectionPopupLabel(_ phase: SelectionPopupPhase, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch phase {
            case .hidden: return ""
            case .ready: return "暂存"
            case .saving: return "暂存中…"
            case .saved(let offline): return offline ? "待同步" : "已同步"
            }
        case .en:
            switch phase {
            case .hidden: return ""
            case .ready: return "Stash"
            case .saving: return "Stashing…"
            case .saved(let offline): return offline ? "Pending Sync" : "Synced"
            }
        }
    }

    static func aboutApp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关于 Coding Rewind"
        case .en: return "About Coding Rewind"
        }
    }

    static func checkForUpdatesMenu(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "检查更新…"
        case .en: return "Check for Updates…"
        }
    }

    static func settingsEllipsis(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "设置…"
        case .en: return "Settings…"
        }
    }

    static func installOrRepairAntigravityPlugin(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "安装或修复 Antigravity 插件"
        case .en: return "Install or Repair Antigravity Plugin"
        }
    }

    static func hideApp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "隐藏 Coding Rewind"
        case .en: return "Hide Coding Rewind"
        }
    }

    static func hideOthers(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "隐藏其他"
        case .en: return "Hide Others"
        }
    }

    static func showAll(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "全部显示"
        case .en: return "Show All"
        }
    }

    static func quitApp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "退出 Coding Rewind"
        case .en: return "Quit Coding Rewind"
        }
    }

    static func actionsMenuTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "操作"
        case .en: return "Actions"
        }
    }

    static func startChatInSelectedApp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "在所选应用中开始对话"
        case .en: return "Start Chat in Selected App"
        }
    }

    static func startChatInHost(_ host: ConversationHost, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "在 \(host.displayName) 中开始对话"
        case .en: return "Start Chat in \(host.displayName)"
        }
    }

    static func syncNow(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "立即同步"
        case .en: return "Sync Now"
        }
    }

    static func openMemosWeb(withArrow: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return withArrow ? "打开 Memos 网页 ↗" : "打开 Memos 网页"
        case .en: return withArrow ? "Open Memos Web ↗" : "Open Memos Web"
        }
    }

    static func recentClips(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "最近片段"
        case .en: return "Recent Clips"
        }
    }

    static func editMenuTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "编辑"
        case .en: return "Edit"
        }
    }

    static func undo(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "撤销"
        case .en: return "Undo"
        }
    }

    static func redo(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重做"
        case .en: return "Redo"
        }
    }

    static func cut(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "剪切"
        case .en: return "Cut"
        }
    }

    static func copy(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "拷贝"
        case .en: return "Copy"
        }
    }

    static func paste(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "粘贴"
        case .en: return "Paste"
        }
    }

    static func selectAll(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "全选"
        case .en: return "Select All"
        }
    }

    static func windowMenuTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "窗口"
        case .en: return "Window"
        }
    }

    static func closeWindow(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关闭窗口"
        case .en: return "Close Window"
        }
    }

    static func bringHUDToFront(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "前置片段浮窗"
        case .en: return "Bring Clips HUD to Front"
        }
    }

    static func statusItemTooltip(in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return "Coding Rewind，左键打开菜单，右键或 ⌥点击显示或隐藏片段浮窗"
        case .en:
            return "Coding Rewind — Left-click for menu, right-click or ⌥-click to toggle Clips HUD"
        }
    }

    static func accessibilityStatusMenu(isTrusted: Bool, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            return isTrusted ? "辅助功能权限：已授权" : "辅助功能权限：前往系统设置…"
        case .en:
            return isTrusted ? "Accessibility: Granted" : "Accessibility: Open System Settings…"
        }
    }

    static func settingsWindowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Coding Rewind 设置"
        case .en: return "Coding Rewind Settings"
        }
    }

    static func connectionSavedVerifyHint(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "连接设置已保存，尚未确认同步成功。请点击“立即同步”检查。"
        case .en: return "Connection settings saved. Click \"Sync Now\" to verify connectivity."
        }
    }

    static func settingsPageTitle(_ page: SettingsPage, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch page {
            case .general: return "通用"
            case .connection: return "Memos 连接"
            case .keyboard: return "快捷键"
            case .integrations: return "插件与权限"
            }
        case .en:
            switch page {
            case .general: return "General"
            case .connection: return "Memos"
            case .keyboard: return "Shortcuts"
            case .integrations: return "Integrations"
            }
        }
    }

    static func settingsCategoriesLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "设置分类"
        case .en: return "Settings Categories"
        }
    }

    static func languageSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "界面语言"
        case .en: return "Language"
        }
    }

    static func displayLanguageTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "显示语言"
        case .en: return "Display Language"
        }
    }

    static func displayLanguageHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "切换后立即更新菜单、片段浮窗与设置界面，无需重启应用。"
        case .en: return "Updates menus, Clips HUD, and Settings immediately without restarting."
        }
    }

    static func startupSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "开机自启动"
        case .en: return "Startup"
        }
    }

    static func launchAtLoginTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "登录时自动打开"
        case .en: return "Launch at Login"
        }
    }

    static func launchAtLoginHelp(_ state: LoginItemState, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch state {
            case .disabled, .enabled:
                return "登录 macOS 后在后台静默启动 Coding Rewind，不自动弹出浮窗。"
            case .requiresApproval:
                return "已登记登录项，需要在系统设置的“登录项”中批准后台运行。"
            case .unavailable(.unbundledExecutable):
                return "当前以独立可执行文件运行，使用完整应用包打开后可启用开机自启动。"
            case .unavailable(.qaIsolated):
                return "QA 隔离模式下不会修改系统登录项。"
            }
        case .en:
            switch state {
            case .disabled, .enabled:
                return "Starts Coding Rewind silently in the menu bar when you log in to macOS."
            case .requiresApproval:
                return "Registered, but requires approval in System Settings > General > Login Items."
            case .unavailable(.unbundledExecutable):
                return "Unavailable when running outside a packaged .app bundle."
            case .unavailable(.qaIsolated):
                return "System Login Items are isolated in QA mode."
            }
        }
    }

    static func openLoginItemsSettingsButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "打开登录项设置…"
        case .en: return "Open Login Items Settings…"
        }
    }

    static func updatesSectionTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "软件更新"
        case .en: return "Software Update"
        }
    }

    static func autoCheckUpdatesTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "自动检查更新"
        case .en: return "Automatically Check for Updates"
        }
    }

    static func autoCheckUpdatesHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "后台定期从 GitHub Releases 检查经过 SHA-256 与代码签名校验的新版本。"
        case .en: return "Periodically checks GitHub Releases for SHA-256 and code-signature verified updates."
        }
    }

    static func currentVersionTitle(version: SemanticVersion, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "当前版本 v\(version.description)"
        case .en: return "Current Version v\(version.description)"
        }
    }

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

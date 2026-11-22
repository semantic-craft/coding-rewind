// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

enum AppStrings {
    static func exportOriginal(in language: AppLanguage) -> String {
        language == .zhHans ? "存储原件…" : "Save Original…"
    }

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
            case .captureSelection: return "Save Selection"
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

    static func startChat(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "开始对话"
        case .en: return "Start Chat"
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
        case .zhHans: return withArrow ? "查看全部历史（Memos）↗" : "查看全部历史（Memos）"
        case .en: return withArrow ? "View All History (Memos) ↗" : "View All History (Memos)"
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

    static func settingsWindowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Coding Rewind 设置"
        case .en: return "Coding Rewind Settings"
        }
    }

    static func connectionCheckMessage(_ outcome: ConnectionCheckOutcome, in language: AppLanguage) -> String {
        switch outcome {
        case .verified:
            switch language {
            case .zhHans: return "设置已保存，已连接到 Memos 服务。"
            case .en: return "Settings saved. Connected to the Memos server."
            }
        case .localOnly:
            switch language {
            case .zhHans: return "设置已保存。未填写服务地址，片段仅保存在本机。"
            case .en: return "Settings saved. No server URL is set, so clips stay on this Mac."
            }
        case .missingToken:
            switch language {
            case .zhHans: return "设置已保存，但还没有访问令牌，尚未验证连接。"
            case .en: return "Settings saved, but there is no access token yet, so the connection was not verified."
            }
        case .failed(let error):
            if case .httpError(let code, _) = error, code == 401 || code == 403 {
                switch language {
                case .zhHans: return "设置已保存，但访问令牌无效或权限不足。请在 Memos 后台重新生成令牌。"
                case .en: return "Settings saved, but the access token is invalid or lacks permission. Generate a new token in Memos."
                }
            }
            let detail = error.localizedDescription(in: language)
            switch language {
            case .zhHans: return "设置已保存，但连接失败。\(detail)"
            case .en: return "Settings saved, but the connection failed. \(detail)"
            }
        }
    }

    static func settingsPageTitle(_ page: SettingsPage, in language: AppLanguage) -> String {
        switch language {
        case .zhHans:
            switch page {
            case .general: return "通用"
            case .connection: return "云端同步"
            case .keyboard: return "快捷键"
            case .integrations: return "插件与权限"
            case .about: return "关于"
            }
        case .en:
            switch page {
            case .general: return "General"
            case .connection: return "Cloud Sync"
            case .keyboard: return "Shortcuts"
            case .integrations: return "Integrations"
            case .about: return "About"
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
            case .unavailable(.relocatedBundle):
                return "当前应用位于临时或构建目录，请将 CodingRewind.app 移入“应用程序”文件夹后再开启开机时启动。"
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
            case .unavailable(.relocatedBundle):
                return "Move CodingRewind.app to the Applications folder before enabling Launch at Login."
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
}

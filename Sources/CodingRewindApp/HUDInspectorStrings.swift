// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

extension AppStrings {
    static func contextPreviewButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "脉络"
        case .en: return "Context"
        }
    }

    static func contextPreviewHelp(isInspected: Bool, in language: AppLanguage) -> String {
        switch (language, isInspected) {
        case (.zhHans, true): return "收起片段脉络与全文 (⌘I)"
        case (.zhHans, false): return "查看片段脉络、会话开场与全文 (⌘I)"
        case (.en, true): return "Hide clip context & full text (⌘I)"
        case (.en, false): return "Inspect clip context, session opening & full text (⌘I)"
        }
    }

    static func toggleContextMenu(isInspected: Bool, in language: AppLanguage) -> String {
        switch (language, isInspected) {
        case (.zhHans, true): return "收起脉络"
        case (.zhHans, false): return "查看脉络"
        case (.en, true): return "Hide Context"
        case (.en, false): return "View Context"
        }
    }

    static func sourceActionButton(for locator: SourceLocator, in language: AppLanguage) -> String {
        switch (locator, language) {
        case (.web, .zhHans): return "打开原网页"
        case (.web, .en): return "Open Web"
        case (.antigravitySession, .zhHans): return "复制会话 ID"
        case (.antigravitySession, .en): return "Copy Session ID"
        case (.dshSession, .zhHans): return "打开原对话"
        case (.dshSession, .en): return "Open Chat"
        }
    }

    static func wakeAntigravityButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "唤醒 Antigravity"
        case .en: return "Wake Antigravity"
        }
    }

    static func wakeDSHButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "唤醒 DSH"
        case .en: return "Wake DSH"
        }
    }

    static func copySessionIDButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "复制会话 ID"
        case .en: return "Copy Session ID"
        }
    }

    static func inspectorCloseLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "关闭脉络详情"
        case .en: return "Close Inspector"
        }
    }

    static func inspectorCopyTextHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "拷贝完整摘录"
        case .en: return "Copy full excerpt"
        }
    }

    static func inspectorSessionIDLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "会话 ID"
        case .en: return "Session ID"
        }
    }

    static func inspectorCopySessionIDButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "复制"
        case .en: return "Copy"
        }
    }

    static func inspectorCopySessionIDHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "复制会话 ID"
        case .en: return "Copy Session ID"
        }
    }

    static func inspectorSessionOpeningHeading(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "会话开场"
        case .en: return "Session Opening"
        }
    }

    static func inspectorPageLeadHeading(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "页面导语"
        case .en: return "Page Lead"
        }
    }

    static func inspectorPrecedingPromptHeading(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "前序提问"
        case .en: return "Preceding Prompt"
        }
    }

    static func inspectorFullExcerptHeading(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "完整摘录"
        case .en: return "Full Excerpt"
        }
    }

    static func inspectorRecentTurnsHeading(count: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "最近对话（\(count) 条）"
        case .en: return "Recent Turns (\(count))"
        }
    }

    static func inspectorNotesHeading(count: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "批注笔记（\(count) 条）"
        case .en: return "Notes (\(count))"
        }
    }

    static func inspectorLoadingText(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "正在加载脉络与批注…"
        case .en: return "Loading context & notes…"
        }
    }

    static func inspectorRetryButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "重试"
        case .en: return "Retry"
        }
    }

    static func draftComposerTitle(count: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "接聊草稿（已选 \(count) 条）"
        case .en: return "Chat Draft (\(count) selected)"
        }
    }

    static func draftComposerSubtitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "发送前可调整提示词 · 按 Esc 返回片段列表"
        case .en: return "Adjust prompt before sending · Esc returns to clips"
        }
    }

    static func draftEditorAccessibilityLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "接聊提示词草稿"
        case .en: return "Continue-conversation prompt draft"
        }
    }

    static func draftResetButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "恢复默认"
        case .en: return "Reset"
        }
    }

    static func draftResetHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "恢复为所选片段的默认提示词"
        case .en: return "Reset to the default prompt for selected clips"
        }
    }

    static func draftCloseLabel(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "返回片段列表"
        case .en: return "Back to Clips"
        }
    }

    static func draftBackButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "返回列表"
        case .en: return "Back"
        }
    }

    static func draftCopyAndWakeButton(hostName: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "复制并唤醒 \(hostName)"
        case .en: return "Copy & Wake \(hostName)"
        }
    }

    static func draftCopyAndWakeHelp(for host: ConversationHost, in language: AppLanguage) -> String {
        switch (host, language) {
        case (.dsh, .zhHans):
            return "复制修改后的提示词并唤醒 DSH，便于手动粘贴发送"
        case (.dsh, .en):
            return "Copy edited draft and wake DSH to paste manually"
        case (.antigravity, .zhHans):
            return "复制修改后的提示词并唤醒 \(host.displayName)，便于手动粘贴发送 (⌘↵)"
        case (.antigravity, .en):
            return "Copy edited draft and wake \(host.displayName) to paste and send manually (⌘↵)"
        }
    }

    static func draftSendDirectButton(for host: ConversationHost, in language: AppLanguage) -> String {
        switch (host, language) {
        case (.dsh, .zhHans): return "填入 DSH 新会话"
        case (.dsh, .en): return "Fill New DSH Chat"
        case (.antigravity, .zhHans): return "直接新建对话"
        case (.antigravity, .en): return "Send to New Chat"
        }
    }

    static func draftSendDirectHelp(for host: ConversationHost, in language: AppLanguage) -> String {
        switch (host, language) {
        case (.dsh, .zhHans):
            return "在 DSH 中打开空白新会话并预填草稿，不自动发送 (⌘↵)"
        case (.dsh, .en):
            return "Open a new blank DSH chat and prefill the draft without sending automatically (⌘↵)"
        case (.antigravity, .zhHans):
            return "使用当前草稿在 \(host.displayName) 中直接创建并发送新对话"
        case (.antigravity, .en):
            return "Directly create and send a new chat in \(host.displayName) using this draft"
        }
    }
}

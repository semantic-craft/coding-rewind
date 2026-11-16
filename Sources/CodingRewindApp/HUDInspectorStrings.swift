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
        }
    }

    static func wakeAntigravityButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "唤醒 Antigravity"
        case .en: return "Wake Antigravity"
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
}

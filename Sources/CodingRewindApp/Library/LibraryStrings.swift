// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

extension AppStrings {
    static func libraryWindowTitle(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "Coding Rewind 资料库"
        case .en: return "Coding Rewind Library"
        }
    }

    static func openLibraryMenu(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "打开资料库"
        case .en: return "Open Library"
        }
    }

    static func librarySearchPlaceholder(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "搜索代码、提问、会话或笔记（⌘F）"
        case .en: return "Search code, prompts, sessions, or notes (⌘F)"
        }
    }

    static func libraryLayoutTitle(_ mode: LibraryLayoutMode, in language: AppLanguage) -> String {
        switch (mode, language) {
        case (.bentoCards, .zhHans): return "卡片墙"
        case (.bentoCards, .en): return "Cards"
        case (.sessionTimeline, .zhHans): return "会话时间轴"
        case (.sessionTimeline, .en): return "Sessions"
        }
    }

    static func libraryScopeTitle(
        _ scope: LibraryScope,
        placeTitle: (PlaceRef) -> String,
        in language: AppLanguage
    ) -> String {
        switch scope {
        case .all:
            return language == .zhHans ? "全部片段" : "All Clips"
        case .unplacedInbox:
            return language == .zhHans ? "未落位收件箱" : "Unplaced Inbox"
        case .hot72Hours:
            return language == .zhHans ? "最近 72 小时" : "Last 72 Hours"
        case .archived:
            return language == .zhHans ? "已归档" : "Archived"
        case .source(.geminiWeb):
            return language == .zhHans ? "Gemini 网页" : "Gemini Web"
        case .source(.antigravity):
            return "Antigravity"
        case .source(.chatGPTApp):
            return language == .zhHans ? "ChatGPT 客户端" : "ChatGPT App"
        case .place(let ref):
            return placeTitle(ref)
        }
    }

    static func librarySidebarSectionViews(in language: AppLanguage) -> String {
        language == .zhHans ? "视图" : "Views"
    }

    static func librarySidebarSectionSources(in language: AppLanguage) -> String {
        language == .zhHans ? "采集源" : "Sources"
    }

    static func librarySidebarSectionPlaces(_ kind: PlaceKind, in language: AppLanguage) -> String {
        AppStrings.placeKindColumnTitle(kind, in: language)
    }

    static func libraryHitSlotBadge(_ slot: SearchHitSlot, in language: AppLanguage) -> String {
        switch (slot, language) {
        case (.metadata, .zhHans): return "标题/标签命中"
        case (.metadata, .en): return "Metadata Match"
        case (.verbatimBody, .zhHans): return "代码/正文命中"
        case (.verbatimBody, .en): return "Excerpt Match"
        case (.promptContext, .zhHans): return "提问脉络命中"
        case (.promptContext, .en): return "Prompt Match"
        case (.agentNote, .zhHans): return "笔记命中"
        case (.agentNote, .en): return "Note Match"
        }
    }

    static func librarySourceDisplayName(
        source: CaptureSourceKind?,
        platform: String,
        in language: AppLanguage
    ) -> String {
        switch source {
        case .geminiWeb:
            return language == .zhHans ? "Gemini 网页" : "Gemini Web"
        case .antigravity:
            return "Antigravity"
        case .chatGPTApp:
            return language == .zhHans ? "ChatGPT 客户端" : "ChatGPT App"
        case nil:
            return "#\(platform)"
        }
    }

    static func libraryTriageHeadline(remaining: Int, triaged: Int, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "待分拣 \(remaining) 条 · 本次已整理 \(triaged) 条"
        case .en: return "\(remaining) unplaced · \(triaged) triaged this session"
        }
    }

    static func librarySuggestionReason(
        _ reason: SuggestedPlaceCandidate.MatchReason,
        in language: AppLanguage
    ) -> String {
        switch (reason, language) {
        case (.sameSessionInherited, .zhHans): return "同会话继承"
        case (.sameSessionInherited, .en): return "Same Session"
        case (.keywordAlias, .zhHans): return "词表匹配"
        case (.keywordAlias, .en): return "Keyword Match"
        case (.semanticNeighbor(let pct), .zhHans): return "语义相近 \(pct)%"
        case (.semanticNeighbor(let pct), .en): return "Similar \(pct)%"
        }
    }

    static func libraryAcceptAndNextButton(in language: AppLanguage) -> String {
        language == .zhHans ? "采纳并下一条 ↩" : "Accept & Next ↩"
    }

    static func libraryChoosePlaceButton(in language: AppLanguage) -> String {
        language == .zhHans ? "落位…" : "Place…"
    }

    static func libraryEmptyScopeTitle(in language: AppLanguage) -> String {
        language == .zhHans ? "当前范围暂无片段" : "No clips in this scope"
    }

    static func libraryHandoffSelectedCount(_ count: Int, in language: AppLanguage) -> String {
        language == .zhHans ? "已暂存 \(count) 条片段" : "\(count) clips staged"
    }

    static func libraryBatchPlaceButton(in language: AppLanguage) -> String {
        language == .zhHans ? "落位…" : "Place…"
    }

    static func libraryClearSelectionButton(in language: AppLanguage) -> String {
        language == .zhHans ? "清空" : "Clear"
    }

    static func librarySessionClipsBadge(_ count: Int, in language: AppLanguage) -> String {
        language == .zhHans ? "\(count) 条摘录" : "\(count) clips"
    }

    static func librarySessionOpeningLabel(in language: AppLanguage) -> String {
        language == .zhHans ? "首轮开场" : "Session Opening"
    }

    static func libraryPrecedingPromptLabel(in language: AppLanguage) -> String {
        language == .zhHans ? "紧邻提问" : "Preceding Prompt"
    }

    static func libraryVerbatimExcerptLabel(in language: AppLanguage) -> String {
        language == .zhHans ? "原始摘录" : "Verbatim Excerpt"
    }

    static func libraryCopyExcerptButton(in language: AppLanguage) -> String {
        language == .zhHans ? "拷贝摘录" : "Copy Excerpt"
    }

    static func libraryRecentTurnsLabel(_ count: Int, in language: AppLanguage) -> String {
        language == .zhHans ? "近期对话轮次 (\(count))" : "Recent Turns (\(count))"
    }

    static func libraryNotesSectionLabel(_ count: Int, in language: AppLanguage) -> String {
        language == .zhHans ? "AI 与个人笔记 (\(count))" : "Notes (\(count))"
    }

    static func libraryNotePlaceholder(in language: AppLanguage) -> String {
        language == .zhHans ? "追加一条脉络笔记…" : "Append a note…"
    }

    static func libraryAddNoteButton(in language: AppLanguage) -> String {
        language == .zhHans ? "追加" : "Add"
    }

    static func libraryRelatedClipsLabel(_ count: Int, in language: AppLanguage) -> String {
        language == .zhHans ? "同位置关联片段 (\(count))" : "Related Clips in Place (\(count))"
    }

    static func libraryMergeStartChatButton(in language: AppLanguage) -> String {
        language == .zhHans ? "合并开始对话" : "Merge & Start Chat"
    }

    static func libraryUnarchiveButton(in language: AppLanguage) -> String {
        language == .zhHans ? "取消归档" : "Unarchive"
    }

    static func libraryArchiveButton(in language: AppLanguage) -> String {
        language == .zhHans ? "归档" : "Archive"
    }

    static func libraryDeleteButton(in language: AppLanguage) -> String {
        language == .zhHans ? "删除" : "Delete"
    }

    static func libraryEmptyInspectorHint(in language: AppLanguage) -> String {
        language == .zhHans
            ? "选择一条片段查看完整对话脉络、原始代码与关联沉淀"
            : "Select a clip to inspect full provenance, verbatim code, and related clips"
    }

    static func libraryClearSearchLabel(in language: AppLanguage) -> String {
        language == .zhHans ? "清空搜索" : "Clear search"
    }

    static func libraryInspectorToggleHelp(in language: AppLanguage) -> String {
        language == .zhHans ? "显示或隐藏右侧脉络栏 (⌘I)" : "Toggle Inspector (⌘I)"
    }
}

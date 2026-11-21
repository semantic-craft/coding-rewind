// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

extension AppStrings {
    static func hudSectionTitle(_ section: HUDSection, unplacedCount: Int?, in language: AppLanguage) -> String {
        switch (section, language) {
        case (.hot, .zhHans): return "热流 72h"
        case (.hot, .en): return "Hot 72h"
        case (.unplaced, .zhHans): return unplacedCount.map { "未落位 · \($0)" } ?? "未落位"
        case (.unplaced, .en): return unplacedCount.map { "Unplaced · \($0)" } ?? "Unplaced"
        case (.map, .zhHans), (.place, .zhHans): return "地图"
        case (.map, .en), (.place, .en): return "Map"
        }
    }

    static func placeKindColumnTitle(_ kind: PlaceKind, in language: AppLanguage) -> String {
        switch (kind, language) {
        case (.project, .zhHans): return "项目"
        case (.topic, .zhHans): return "主题"
        case (.person, .zhHans): return "人物"
        case (.project, .en): return "Projects"
        case (.topic, .en): return "Topics"
        case (.person, .en): return "People"
        }
    }

    static func placeMapEmpty(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "还没有位置。用 coding-rewind place add 创建。"
        case .en: return "No places yet. Create one with coding-rewind place add."
        }
    }

    static func backToMapButton(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "← 地图"
        case .en: return "← Map"
        }
    }

    static func browseEmpty(_ section: HUDSection, in language: AppLanguage) -> String {
        switch (section, language) {
        case (.place, .zhHans): return "该位置还没有片段。"
        case (.place, .en): return "No clips in this place yet."
        case (_, .zhHans): return "没有未落位的片段。"
        case (_, .en): return "No unplaced clips."
        }
    }

    static func placePickerPlaceholder(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "落位到…（回车确认，Esc 取消）"
        case .en: return "Place into… (Return to apply, Esc to cancel)"
        }
    }

    static func placePickerNoMatch(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "没有匹配的位置，可用 coding-rewind place add 新建。"
        case .en: return "No matching place. Create one with coding-rewind place add."
        }
    }

    static func addPlaceHelp(in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "落位 (⌘P)"
        case .en: return "Place (⌘P)"
        }
    }

    static func removePlaceLabel(title: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "移除位置 \(title)"
        case .en: return "Remove place \(title)"
        }
    }

    static func snippetStatusBadge(_ status: SnippetStatus, in language: AppLanguage) -> String {
        switch status {
        case .pending: return CardStatus.pending.badgeText(in: language)
        case .ready: return CardStatus.ready.badgeText(in: language)
        case .synthesized:
            switch language {
            case .zhHans: return "已归档"
            case .en: return "Archived"
            }
        }
    }
}

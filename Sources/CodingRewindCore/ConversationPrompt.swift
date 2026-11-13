// SPDX-License-Identifier: MIT

import Foundation

public enum ConversationPrompt {
    public static func buildPrompt(for cards: [RewindCard]) -> String {
        var sections: [String] = [
            "请围绕以下我在 Coding Rewind 暂存的灵感卡片展开分析与写作推演，保留关键原文论据并在引用处附上出处链接："
        ]
        for (index, card) in cards.enumerated() {
            var lines: [String] = []
            let heading = card.title ?? card.sourceTitle
            lines.append("### 卡片 \(index + 1)：\(heading)")
            if let session = card.sessionTopic, !session.isEmpty {
                lines.append("- 会话主题：\(session)")
            }
            if let ctx = card.contextSummary, !ctx.isEmpty {
                lines.append("- 上下文脉络：\(ctx)")
            }
            if let url = card.sourceURL, !url.isEmpty {
                lines.append("- 原文出处：[出处](\(url))（\(card.sourceTitle)）")
            } else {
                lines.append("- 原文出处：\(card.sourceTitle)")
            }
            lines.append("")
            let quoted = card.verbatimText
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            lines.append(quoted)
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

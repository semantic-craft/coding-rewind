// SPDX-License-Identifier: MIT

import Foundation

package enum ConversationContextSlicer {
    package static let maxRounds = 4
    package static let maxLeadCharacters = 300
    package static let maxTurnCharacters = 800
    package static let maxRecentTurnsCharacters = 4000

    package enum Role: String, Equatable, Sendable {
        case user = "User"
        case assistant = "Assistant"
    }

    package struct Message: Equatable, Sendable {
        package let role: Role
        package let matchText: String
        package let contextText: String
        package let truncatedByHost: Bool

        package init(
            role: Role,
            matchText: String,
            contextText: String? = nil,
            truncatedByHost: Bool = false
        ) {
            let normalizedMatch = ConversationContextSlicer.normalizeLineEndings(matchText)
            self.role = role
            self.matchText = normalizedMatch
            self.contextText = contextText.map(ConversationContextSlicer.normalizeLineEndings) ?? normalizedMatch
            self.truncatedByHost = truncatedByHost
        }
    }

    package enum AnchorMode: Equatable, Sendable {
        case explicitIndex(Int)
        case uniqueSubstring
    }

    package static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    package static func resolveAnchor(
        selectedText: String,
        in messages: [Message],
        mode: AnchorMode
    ) -> Int? {
        let selection = normalizeLineEndings(selectedText)
        guard !selection.isEmpty else { return nil }

        switch mode {
        case .explicitIndex(let index):
            guard messages.indices.contains(index),
                  messages[index].matchText.range(of: selection, options: .literal) != nil else {
                return nil
            }
            return index
        case .uniqueSubstring:
            let assistantMatches = messages.indices.filter {
                messages[$0].role == .assistant &&
                messages[$0].matchText.range(of: selection, options: .literal) != nil
            }
            if assistantMatches.count == 1 {
                return assistantMatches[0]
            }
            if assistantMatches.count > 1 {
                return nil
            }
            let userMatches = messages.indices.filter {
                messages[$0].role == .user &&
                messages[$0].matchText.range(of: selection, options: .literal) != nil
            }
            return userMatches.count == 1 ? userMatches[0] : nil
        }
    }

    package static func slice(
        selectedText: String,
        messages: [Message],
        anchor mode: AnchorMode,
        sessionTitle: String,
        sessionID: String? = nil,
        openingOverride: String?? = nil
    ) -> CaptureContext? {
        guard let anchor = resolveAnchor(selectedText: selectedText, in: messages, mode: mode) else {
            return nil
        }

        let throughAnchor = messages[...anchor]
        var roundStarts: [Int] = []
        for index in throughAnchor.indices where throughAnchor[index].role == .user {
            if index == throughAnchor.startIndex || throughAnchor[throughAnchor.index(before: index)].role != .user {
                roundStarts.append(index)
            }
        }
        let windowRounds = roundStarts.suffix(maxRounds)
        guard let firstRound = windowRounds.first, let lastRound = windowRounds.last else {
            return nil
        }

        let prompt: String
        if throughAnchor[anchor].role == .assistant {
            let promptMessage = throughAnchor[lastRound...].last {
                $0.role == .user && !$0.contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? throughAnchor[lastRound]
            prompt = formatTurnText(promptMessage)
        } else {
            prompt = ""
        }

        let openingText: String?
        switch openingOverride {
        case .some(let explicitOpening):
            openingText = explicitOpening.flatMap { formatLeadText($0, truncatedByHost: false) }
        case .none:
            let firstUserMessage = messages.first {
                $0.role == .user && !$0.contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            openingText = firstUserMessage.flatMap {
                formatLeadText($0.contextText, truncatedByHost: $0.truncatedByHost)
            }
        }

        var recentTurns = throughAnchor[firstRound...]
            .map { ConversationTurn(role: $0.role.rawValue, text: formatTurnText($0)) }
            .filter { !$0.text.isEmpty }
        while recentTurns.count > 1,
              recentTurns.map({ "\($0.role): \($0.text)" }).joined(separator: "\n").count > maxRecentTurnsCharacters {
            recentTurns.removeFirst()
        }
        return CaptureContext(
            sessionTitle: sessionTitle,
            sessionID: sessionID,
            lead: openingText.map(CaptureContextLead.sessionOpening),
            prompt: prompt,
            recentTurns: recentTurns
        )
    }

    package static func formatLeadText(_ rawText: String, truncatedByHost: Bool) -> String? {
        let cleaned = rawText
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxLeadCharacters {
            let prefix = String(cleaned.prefix(maxLeadCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MemosWireFormat.closeUnbalancedCodeFence(prefix + "…")
        }
        if truncatedByHost && !cleaned.hasSuffix("…") {
            return MemosWireFormat.closeUnbalancedCodeFence(cleaned + "…")
        }
        return MemosWireFormat.closeUnbalancedCodeFence(cleaned)
    }

    package static func formatTurnText(_ message: Message) -> String {
        let text = message.contextText
        if text.count > maxTurnCharacters || message.truncatedByHost {
            return MemosWireFormat.closeUnbalancedCodeFence(String(text.prefix(maxTurnCharacters)) + "…")
        }
        return MemosWireFormat.closeUnbalancedCodeFence(text)
    }
}

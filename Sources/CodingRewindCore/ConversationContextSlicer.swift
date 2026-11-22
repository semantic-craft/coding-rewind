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

    package static func stripMarkdownSyntax(_ text: String) -> String {
        let lines = normalizeLineEndings(text).split(separator: "\n", omittingEmptySubsequences: false)
        var cleanedLines: [String] = []
        cleanedLines.reserveCapacity(lines.count)
        var activeFence: (char: Character, count: Int)?

        for rawLine in lines {
            if let fence = activeFence {
                if isClosingFence(rawLine, char: fence.char, minCount: fence.count) {
                    activeFence = nil
                    continue
                }
                cleanedLines.append(String(rawLine))
                continue
            }
            if let openingFence = parseOpeningFence(rawLine) {
                activeFence = openingFence
                continue
            }
            var line = stripLeadingMarkdownMarkers(String(rawLine))
            line = unwrapMarkdownLinks(line)
            line = line
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
            line = stripSymmetricEmphasis(line)
            cleanedLines.append(line)
        }
        return cleanedLines.joined(separator: "\n")
    }

    private static func parseOpeningFence(_ rawLine: Substring) -> (char: Character, count: Int)? {
        let trimmed = rawLine.drop(while: { $0 == " " || $0 == "\t" })
        guard let fenceChar = trimmed.first, fenceChar == "`" || fenceChar == "~" else {
            return nil
        }
        let fencePrefix = trimmed.prefix(while: { $0 == fenceChar })
        guard fencePrefix.count >= 3 else {
            return nil
        }
        let afterFence = trimmed.dropFirst(fencePrefix.count)
        if fenceChar == "`", afterFence.contains("`") {
            return nil
        }
        return (fenceChar, fencePrefix.count)
    }

    private static func isClosingFence(_ rawLine: Substring, char: Character, minCount: Int) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minCount && trimmed.allSatisfy { $0 == char }
    }

    private static func stripLeadingMarkdownMarkers(_ rawLine: String) -> String {
        var slice = rawLine[...]
        while true {
            let trimmed = slice.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.first == ">" else { break }
            let afterMarker = trimmed.dropFirst()
            if afterMarker.first == " " || afterMarker.first == "\t" {
                slice = afterMarker.dropFirst()
            } else if afterMarker.isEmpty {
                slice = afterMarker
            } else {
                break
            }
        }
        let afterBlockquote = slice.drop(while: { $0 == " " || $0 == "\t" })
        if afterBlockquote.first == "#" {
            let withoutHashes = afterBlockquote.drop(while: { $0 == "#" })
            if withoutHashes.isEmpty || withoutHashes.first == " " || withoutHashes.first == "\t" {
                slice = withoutHashes.drop(while: { $0 == " " || $0 == "\t" })
            }
        }
        let afterHeading = slice.drop(while: { $0 == " " || $0 == "\t" })
        if let first = afterHeading.first, first == "-" || first == "*" || first == "+" {
            let afterMarker = afterHeading.dropFirst()
            if afterMarker.first == " " || afterMarker.first == "\t" {
                slice = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            }
        }
        return String(slice)
    }

    private static func stripSymmetricEmphasis(_ line: String) -> String {
        guard line.contains("*") else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "*" {
                let afterOpen = line.index(after: index)
                if afterOpen < line.endIndex, !line[afterOpen].isWhitespace {
                    var cursor = afterOpen
                    var closingIndex: String.Index?
                    while cursor < line.endIndex {
                        if line[cursor] == "*" {
                            let prev = line.index(before: cursor)
                            if !line[prev].isWhitespace {
                                closingIndex = cursor
                                break
                            }
                        }
                        cursor = line.index(after: cursor)
                    }
                    if let closingIndex {
                        result.append(contentsOf: line[afterOpen..<closingIndex])
                        index = line.index(after: closingIndex)
                        continue
                    }
                }
            }
            result.append(line[index])
            index = line.index(after: index)
        }
        return result
    }

    private static func unwrapMarkdownLinks(_ line: String) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let isImage = line[index] == "!"
            let bracketStart: String.Index
            if isImage {
                let next = line.index(after: index)
                guard next < line.endIndex, line[next] == "[" else {
                    result.append(line[index])
                    index = next
                    continue
                }
                bracketStart = next
            } else if line[index] == "[" {
                bracketStart = index
            } else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let labelStart = line.index(after: bracketStart)
            var cursor = labelStart
            var bracketDepth = 1
            var labelEnd: String.Index?
            while cursor < line.endIndex {
                let ch = line[cursor]
                if ch == "\\" {
                    let escaped = line.index(after: cursor)
                    cursor = escaped < line.endIndex ? line.index(after: escaped) : escaped
                    continue
                }
                if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" {
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        labelEnd = cursor
                        break
                    }
                }
                cursor = line.index(after: cursor)
            }

            guard let foundLabelEnd = labelEnd else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let parenStart = line.index(after: foundLabelEnd)
            guard parenStart < line.endIndex, line[parenStart] == "(" else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            var urlCursor = line.index(after: parenStart)
            var parenDepth = 1
            var urlEnd: String.Index?
            while urlCursor < line.endIndex {
                let ch = line[urlCursor]
                if ch == "\\" {
                    let escaped = line.index(after: urlCursor)
                    urlCursor = escaped < line.endIndex ? line.index(after: escaped) : escaped
                    continue
                }
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        urlEnd = urlCursor
                        break
                    }
                }
                urlCursor = line.index(after: urlCursor)
            }

            guard let foundURLEnd = urlEnd else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let innerLabel = String(line[labelStart..<foundLabelEnd])
            result.append(unwrapMarkdownLinks(innerLabel))
            index = line.index(after: foundURLEnd)
        }
        return result
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
            if userMatches.count == 1 {
                return userMatches[0]
            }
            if userMatches.count > 1 {
                return nil
            }

            let cleanSelection = stripMarkdownSyntax(selection)
            guard cleanSelection.count >= 4 else {
                return nil
            }
            let strippedMatches = messages.indices.filter { index in
                let raw = messages[index].matchText
                let stripped = stripMarkdownSyntax(raw)
                return stripped != raw && stripped.range(of: cleanSelection, options: .literal) != nil
            }
            return strippedMatches.count == 1 ? strippedMatches[0] : nil
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

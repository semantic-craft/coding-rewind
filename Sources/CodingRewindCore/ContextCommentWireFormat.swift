// SPDX-License-Identifier: MIT

import Foundation

extension MemosWireFormat {
    private struct CodeFenceState {
        let character: Character
        let length: Int
    }

    private static func updateCodeFenceState(_ state: inout CodeFenceState?, line: Substring) {
        var cursor = line.startIndex
        var leadingSpaces = 0
        while cursor < line.endIndex && line[cursor] == " " && leadingSpaces < 4 {
            leadingSpaces += 1
            cursor = line.index(after: cursor)
        }
        guard leadingSpaces <= 3, cursor < line.endIndex else { return }

        let marker = line[cursor]
        guard marker == "`" || marker == "~" else { return }

        var markerCount = 0
        while cursor < line.endIndex && line[cursor] == marker {
            markerCount += 1
            cursor = line.index(after: cursor)
        }
        guard markerCount >= 3 else { return }
        let remainder = line[cursor...]

        if let active = state {
            if marker == active.character,
               markerCount >= active.length,
               remainder.allSatisfy({ $0 == " " || $0 == "\t" }) {
                state = nil
            }
        } else {
            if marker == "`" && remainder.contains("`") {
                return
            }
            state = CodeFenceState(character: marker, length: markerCount)
        }
    }

    public static func closeUnbalancedCodeFence(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var fenceState: CodeFenceState?
        for line in lines {
            updateCodeFenceState(&fenceState, line: line)
        }
        guard let active = fenceState else {
            return text
        }
        let closingFence = String(repeating: active.character, count: active.length)
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            return text + closingFence
        }
        return text + "\n" + closingFence
    }

    public static func formatContextComment(_ context: CaptureContext) -> String {
        var headerLines: [String] = [contextCommentMarker]
        let singleLineTitle = context.sessionTitle
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !singleLineTitle.isEmpty {
            headerLines.append("Session Title: \(singleLineTitle)")
        }
        if let sessionID = context.sessionID {
            let singleLineID = sessionID
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !singleLineID.isEmpty {
                headerLines.append("Session ID: \(singleLineID)")
            }
        }
        if !context.prompt.isEmpty {
            headerLines.append("Prompt: \(closeUnbalancedCodeFence(context.prompt))")
        }

        var blocks: [String] = [headerLines.joined(separator: "\n")]
        switch context.lead {
        case .sessionOpening(let text) where !text.isEmpty:
            blocks.append("### Session Opening\n\(closeUnbalancedCodeFence(text))")
        case .pageLead(let text) where !text.isEmpty:
            blocks.append("### Page Lead\n\(closeUnbalancedCodeFence(text))")
        default:
            break
        }
        if !context.recentTurns.isEmpty {
            let turnsBlock = context.recentTurns
                .map { "\($0.role): \(closeUnbalancedCodeFence($0.text))" }
                .joined(separator: "\n")
            blocks.append("### Recent Turns\n\(turnsBlock)")
        }
        return blocks.joined(separator: "\n\n")
    }

    public static func parseMemoComments(
        _ comments: [MemoWireDTO],
        localNotes: [SnippetNote],
        includeContext: Bool = true,
        now: Date = Date()
    ) -> (context: CaptureContext?, notes: [SnippetNote]) {
        var conversationContext: CaptureContext?
        var collectedNotes = localNotes
        for comment in comments {
            if includeContext, conversationContext == nil,
               let parsedCtx = parseContextComment(comment.content) {
                conversationContext = parsedCtx
                continue
            }
            let fallbackDate = comment.createTime.flatMap(parseISO8601)
                ?? comment.updateTime.flatMap(parseISO8601)
                ?? now
            if let parsedNote = parseNoteComment(
                id: comment.name,
                rawComment: comment.content,
                fallbackCreatedAt: fallbackDate
            ) {
                collectedNotes.append(parsedNote)
            }
        }
        let sortedNotes = LocalNotesStore.sortAndDeduplicate(collectedNotes)
        return (includeContext ? conversationContext : nil, sortedNotes)
    }

    private enum ContextSection {
        case headers
        case sessionOpening
        case pageLead
        case promptSection
        case recentTurns
    }

    public static func parseContextComment(_ rawComment: String) -> CaptureContext? {
        let normalized = rawComment
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedLeading = normalized.drop(while: { $0.isWhitespace || $0.isNewline })
        guard let newlineIdx = trimmedLeading.firstIndex(of: "\n"),
              trimHorizontalWhitespace(trimmedLeading[..<newlineIdx]) == contextCommentMarker else {
            return nil
        }

        let afterMarkerLine = trimmedLeading[trimmedLeading.index(after: newlineIdx)...]
        let lines = afterMarkerLine.split(separator: "\n", omittingEmptySubsequences: false)

        var section: ContextSection = .headers
        var fenceState: CodeFenceState?

        var sawSessionTitleHeader = false
        var sawSessionIDHeader = false
        var sawHeaderPrompt = false
        var inHeaderPrompt = false

        var sessionTitle = ""
        var sessionID: String?
        var headerPromptLines: [Substring] = []
        var sectionPromptLines: [Substring] = []
        var sessionOpeningLines: [Substring] = []
        var pageLeadLines: [Substring] = []
        var recentTurns: [ConversationTurn] = []

        var currentRole: String?
        var currentTurnLines: [Substring] = []

        func flushTurn() {
            guard let role = currentRole else { return }
            let text = currentTurnLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                recentTurns.append(ConversationTurn(role: role, text: text))
            }
            currentRole = nil
            currentTurnLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            if fenceState == nil {
                let trimmedHeading = trimHorizontalWhitespace(rawLine)
                switch trimmedHeading {
                case "### Session Opening":
                    flushTurn()
                    inHeaderPrompt = false
                    section = .sessionOpening
                    continue
                case "### Page Lead":
                    flushTurn()
                    inHeaderPrompt = false
                    section = .pageLead
                    continue
                case "### Prompt":
                    flushTurn()
                    inHeaderPrompt = false
                    section = .promptSection
                    continue
                case "### Recent Turns":
                    flushTurn()
                    inHeaderPrompt = false
                    section = .recentTurns
                    continue
                default:
                    break
                }
            }

            switch section {
            case .headers:
                if fenceState == nil {
                    if !inHeaderPrompt && !sawSessionTitleHeader && rawLine.hasPrefix("Session Title:") {
                        sawSessionTitleHeader = true
                        inHeaderPrompt = false
                        sessionTitle = String(rawLine.dropFirst("Session Title:".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continue
                    }
                    if !inHeaderPrompt && !sawSessionIDHeader && rawLine.hasPrefix("Session ID:") {
                        sawSessionIDHeader = true
                        inHeaderPrompt = false
                        let parsedID = String(rawLine.dropFirst("Session ID:".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        sessionID = parsedID.isEmpty ? nil : parsedID
                        continue
                    }
                    if !sawHeaderPrompt && rawLine.hasPrefix("Prompt:") {
                        sawHeaderPrompt = true
                        inHeaderPrompt = true
                        var remainder = rawLine.dropFirst("Prompt:".count)
                        if remainder.first == " " {
                            remainder = remainder.dropFirst()
                        }
                        headerPromptLines.append(remainder)
                        updateCodeFenceState(&fenceState, line: remainder)
                        continue
                    }
                }
                if inHeaderPrompt {
                    headerPromptLines.append(rawLine)
                    updateCodeFenceState(&fenceState, line: rawLine)
                } else {
                    updateCodeFenceState(&fenceState, line: rawLine)
                }

            case .sessionOpening:
                sessionOpeningLines.append(rawLine)
                updateCodeFenceState(&fenceState, line: rawLine)

            case .pageLead:
                pageLeadLines.append(rawLine)
                updateCodeFenceState(&fenceState, line: rawLine)

            case .promptSection:
                sectionPromptLines.append(rawLine)
                updateCodeFenceState(&fenceState, line: rawLine)

            case .recentTurns:
                if fenceState == nil, let (role, firstLineBody) = parseTurnHeader(rawLine) {
                    flushTurn()
                    currentRole = role
                    currentTurnLines = [firstLineBody]
                    updateCodeFenceState(&fenceState, line: firstLineBody)
                } else {
                    if currentRole != nil {
                        currentTurnLines.append(rawLine)
                    }
                    updateCodeFenceState(&fenceState, line: rawLine)
                }
            }
        }
        flushTurn()

        let headerPrompt = headerPromptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionPrompt = sectionPromptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt = !headerPrompt.isEmpty ? headerPrompt : sectionPrompt

        let openingText = sessionOpeningLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pageLeadText = pageLeadLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLead: CaptureContextLead?
        if !openingText.isEmpty {
            resolvedLead = .sessionOpening(openingText)
        } else if !pageLeadText.isEmpty {
            resolvedLead = .pageLead(pageLeadText)
        } else {
            resolvedLead = nil
        }

        let context = CaptureContext(
            sessionTitle: sessionTitle,
            sessionID: sessionID,
            lead: resolvedLead,
            prompt: resolvedPrompt,
            recentTurns: recentTurns
        )
        return context.isEmpty ? nil : context
    }

    private static func parseTurnHeader(_ line: Substring) -> (role: String, body: Substring)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let rawRole = line[..<colonIndex]
        let lowered = rawRole.lowercased()
        guard lowered == "user" || lowered == "assistant" else {
            return nil
        }
        var remainder = line[line.index(after: colonIndex)...]
        if remainder.first == " " {
            remainder = remainder.dropFirst()
        }
        return (String(rawRole), remainder)
    }
}

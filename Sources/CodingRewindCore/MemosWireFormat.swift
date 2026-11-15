// SPDX-License-Identifier: MIT

import Foundation

public enum MemosWireFormat {
    public static func normalizeBaseURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty else {
            var fallback = trimmed
            while fallback.count > 1 && fallback.hasSuffix("/") {
                fallback.removeLast()
            }
            return fallback
        }
        var cleanPath = components.path
        while cleanPath.count > 1 && cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        if let range = cleanPath.range(
            of: #"/api(?:/v1)?(?:/memos)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            cleanPath.removeSubrange(range)
        }
        while cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        components.path = cleanPath
        components.query = nil
        components.fragment = nil
        return components.string ?? trimmed
    }

    public static func makeClientClipID(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince1970
        let epoch = seconds.isFinite && seconds > 0
            ? UInt64(min(seconds, Double(UInt64.max).nextDown))
            : 0
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        var candidate = String("rw-\(epoch)-\(suffix)".prefix(32))
        while candidate.hasSuffix("-") {
            candidate.removeLast()
        }
        return candidate
    }

    public static func isValidMemoID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty && bytes.count <= 36 else { return false }
        let isAlphaNum: (UInt8) -> Bool = { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        guard isAlphaNum(bytes[0]), isAlphaNum(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { isAlphaNum($0) || $0 == 0x2D }
    }

    public static func inferWebPlatform(urlString: String?, title: String?) -> String {
        let host = urlString.flatMap(URL.init(string:))?.host?.lowercased() ?? ""
        let loweredTitle = title?.lowercased() ?? ""
        if host.contains("chatgpt.com") || host.contains("openai.com") || loweredTitle.contains("chatgpt") {
            return "chatgpt"
        }
        if host.contains("claude.ai") || loweredTitle.contains("claude") {
            return "claude"
        }
        if host.contains("gemini.google.com") || loweredTitle.contains("gemini") {
            return "gemini"
        }
        return "macos"
    }

    public static func formatISO8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    public static func formatSourceLine(
        sourceTitle: String,
        sourcePlatform: String,
        sourceURL: String?,
        capturedAt: Date
    ) -> String {
        let safePlatform = sourcePlatform.isEmpty ? "macos" : sourcePlatform
        let singleLineTitle = (sourceTitle.isEmpty ? safePlatform : sourceTitle)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let effectiveTitle = singleLineTitle.trimmingCharacters(in: .whitespaces).isEmpty ? safePlatform : singleLineTitle
        let escapedTitle = effectiveTitle
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let sanitizedURL = sourceURL.map(sanitizeMarkdownURL) ?? ""
        let targetLink = !sanitizedURL.isEmpty ? sanitizedURL : "macos://\(safePlatform)"
        let iso = formatISO8601UTC(capturedAt)
        return "> **Source:** [\(escapedTitle)](\(targetLink)) · \(iso)"
    }

    public static func parseSourceLine(_ raw: String) -> (title: String, url: String?) {
        let mainPart: String
        if let sepRange = raw.range(of: " · ", options: .backwards),
           !raw[sepRange.upperBound...].contains("](") {
            mainPart = String(raw[..<sepRange.lowerBound])
        } else {
            mainPart = raw
        }

        if mainPart.hasPrefix("["),
           mainPart.hasSuffix(")"),
           let splitIndex = markdownLinkSplitIndex(in: mainPart) {
            let labelStart = mainPart.index(after: mainPart.startIndex)
            let linkStart = mainPart.index(splitIndex, offsetBy: 2)
            let linkEnd = mainPart.index(before: mainPart.endIndex)
            if splitIndex >= labelStart && linkStart <= linkEnd {
                let label = unescapeMarkdownLinkLabel(String(mainPart[labelStart..<splitIndex]))
                let link = String(mainPart[linkStart..<linkEnd])
                let exposedURL = link.hasPrefix("macos://") ? nil : link
                return (label, exposedURL)
            }
        }
        return (unescapeMarkdownLinkLabel(mainPart.trimmingCharacters(in: .whitespaces)), nil)
    }

    private static func sanitizeMarkdownURL(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "%20", options: .regularExpression)
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func markdownLinkSplitIndex(in linkMarkdown: String) -> String.Index? {
        guard linkMarkdown.hasPrefix("[") else { return nil }
        var cursor = linkMarkdown.index(after: linkMarkdown.startIndex)
        while cursor < linkMarkdown.endIndex {
            let ch = linkMarkdown[cursor]
            if ch == "\\" {
                let escaped = linkMarkdown.index(after: cursor)
                guard escaped < linkMarkdown.endIndex else { break }
                cursor = linkMarkdown.index(after: escaped)
                continue
            }
            if ch == "]" {
                let next = linkMarkdown.index(after: cursor)
                if next < linkMarkdown.endIndex, linkMarkdown[next] == "(" {
                    return cursor
                }
            }
            cursor = linkMarkdown.index(after: cursor)
        }
        return nil
    }

    private static func unescapeMarkdownLinkLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
    }

    public static func formatRawMemoContent(
        verbatimText: String,
        sourcePlatform: String,
        sourceTitle: String,
        sourceURL: String?,
        capturedAt: Date,
        hasContext: Bool
    ) throws -> String {
        let cleanedBody = verbatimText.replacingOccurrences(of: "\0", with: "")
        guard !cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        let safePlatform = sourcePlatform.isEmpty ? "macos" : sourcePlatform
        let tags = hasContext
            ? "#rewind/pending #rewind/has-ctx #source/\(safePlatform)"
            : "#rewind/pending #source/\(safePlatform)"
        let sourceLine = formatSourceLine(
            sourceTitle: sourceTitle,
            sourcePlatform: safePlatform,
            sourceURL: sourceURL,
            capturedAt: capturedAt
        )
        return "\(tags)\n\n\(sourceLine)\n\n\(cleanedBody)"
    }

    public static let contextCommentMarker = "<!-- rewind-context-v1 -->"

    public static func replacingWithSynthesizedTag(_ rawContent: String) -> String {
        let headerEnd = rawContent.firstIndex(where: \.isNewline) ?? rawContent.endIndex
        var emittedSynthesized = false
        let updatedHeader = headerTokens(rawContent).compactMap { token -> String? in
            switch token {
            case "#rewind/pending", "#rewind/ready", "#rewind/synthesized":
                guard !emittedSynthesized else { return nil }
                emittedSynthesized = true
                return "#rewind/synthesized"
            case "#rewind/has-ctx": return nil
            default: return String(token)
            }
        }.joined(separator: " ")
        return updatedHeader + rawContent[headerEnd...]
    }

    private static func headerTokens(_ rawContent: String) -> [Substring] {
        rawContent.prefix { !$0.isNewline }.split(whereSeparator: \.isWhitespace)
    }

    public static func parseMemo(
        id: String,
        rawContent: String,
        createdAt: Date,
        now: Date = Date(),
        hotWindow: TimeInterval = RewindCard.hotWindowSeconds,
        isOfflinePending: Bool = false
    ) -> RewindCard? {
        let tags = headerTokens(rawContent)
        let status: CardStatus? = tags.contains("#rewind/ready") ? .ready
            : tags.contains("#rewind/pending") ? .pending : nil
        guard let status,
              !tags.contains("#rewind/synthesized"),
              createdAt >= now.addingTimeInterval(-hotWindow) else {
            return nil
        }

        var sourcePlatform = "macos"
        for token in tags where token.hasPrefix("#source/") {
            sourcePlatform = String(token.dropFirst("#source/".count))
        }

        var cursor = nextLine(in: rawContent, from: rawContent.startIndex)?.nextStart ?? rawContent.endIndex

        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String] = []
        var sourceTitle = sourcePlatform
        var sourceURL: String?

        let metadataPrefixes = [
            "> **Title:**",
            "> **Session:**",
            "> **Context:**",
            "> **Keywords:**",
            "> **Source:**"
        ]

        var metadataCursor = cursor
        while let (line, afterLine) = nextLine(in: rawContent, from: metadataCursor),
              isHorizontalBlank(line) {
            metadataCursor = afterLine
        }

        if let (firstCandidate, _) = nextLine(in: rawContent, from: metadataCursor),
           metadataPrefixes.contains(where: { firstCandidate.hasPrefix($0) }) {
            cursor = metadataCursor
            while let (line, afterLine) = nextLine(in: rawContent, from: cursor) {
                guard let matched = metadataPrefixes.first(where: { line.hasPrefix($0) }) else {
                    break
                }
                let value = trimHorizontalWhitespace(line.dropFirst(matched.count))
                switch matched {
                case "> **Title:**":
                    title = value.isEmpty ? nil : value
                case "> **Session:**":
                    sessionTopic = value.isEmpty ? nil : value
                case "> **Context:**":
                    contextSummary = value.isEmpty ? nil : value
                case "> **Keywords:**":
                    keywords = value
                        .split(separator: ",")
                        .map { trimHorizontalWhitespace($0) }
                        .filter { !$0.isEmpty }
                case "> **Source:**":
                    let parsed = parseSourceLine(value)
                    if !parsed.title.isEmpty { sourceTitle = parsed.title }
                    sourceURL = parsed.url
                default:
                    break
                }
                cursor = afterLine
            }
        }

        if let (separatorLine, afterSeparator) = nextLine(in: rawContent, from: cursor),
           isHorizontalBlank(separatorLine) {
            cursor = afterSeparator
        }
        let verbatim = String(rawContent[cursor...])

        let normalizedID = id.hasPrefix("memos/") ? String(id.dropFirst("memos/".count)) : id
        return RewindCard(
            id: normalizedID,
            rawContent: rawContent,
            status: status,
            sourcePlatform: sourcePlatform,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            verbatimText: verbatim,
            createdAt: createdAt,
            isOfflinePending: isOfflinePending
        )
    }

    public static func parseSnippetRecord(
        id: String,
        rawContent: String,
        createdAt: Date,
        dataOrigin: SnippetDataOrigin,
        conversationContext: CaptureContext? = nil
    ) -> SnippetRecord? {
        let tags = headerTokens(rawContent)
        let status: SnippetStatus? = tags.contains("#rewind/synthesized") ? .synthesized
            : tags.contains("#rewind/ready") ? .ready
            : tags.contains("#rewind/pending") ? .pending : nil
        guard let status else {
            return nil
        }

        var sourcePlatform = "macos"
        for token in tags where token.hasPrefix("#source/") {
            let candidate = String(token.dropFirst("#source/".count))
            if !candidate.isEmpty {
                sourcePlatform = candidate
            }
        }

        var cursor = nextLine(in: rawContent, from: rawContent.startIndex)?.nextStart ?? rawContent.endIndex

        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String] = []
        var sourceTitle = sourcePlatform
        var sourceURL: String?

        let metadataPrefixes = [
            "> **Title:**",
            "> **Session:**",
            "> **Context:**",
            "> **Keywords:**",
            "> **Source:**"
        ]

        var metadataCursor = cursor
        while let (line, afterLine) = nextLine(in: rawContent, from: metadataCursor),
              isHorizontalBlank(line) {
            metadataCursor = afterLine
        }

        if let (firstCandidate, _) = nextLine(in: rawContent, from: metadataCursor),
           metadataPrefixes.contains(where: { firstCandidate.hasPrefix($0) }) {
            cursor = metadataCursor
            while let (line, afterLine) = nextLine(in: rawContent, from: cursor) {
                guard let matched = metadataPrefixes.first(where: { line.hasPrefix($0) }) else {
                    break
                }
                let value = trimHorizontalWhitespace(line.dropFirst(matched.count))
                switch matched {
                case "> **Title:**":
                    title = value.isEmpty ? nil : value
                case "> **Session:**":
                    sessionTopic = value.isEmpty ? nil : value
                case "> **Context:**":
                    contextSummary = value.isEmpty ? nil : value
                case "> **Keywords:**":
                    keywords = value
                        .split(separator: ",")
                        .map { trimHorizontalWhitespace($0) }
                        .filter { !$0.isEmpty }
                case "> **Source:**":
                    let parsed = parseSourceLine(value)
                    if !parsed.title.isEmpty { sourceTitle = parsed.title }
                    sourceURL = parsed.url
                default:
                    break
                }
                cursor = afterLine
            }
        }

        if let (separatorLine, afterSeparator) = nextLine(in: rawContent, from: cursor),
           isHorizontalBlank(separatorLine) {
            cursor = afterSeparator
        }
        let verbatim = String(rawContent[cursor...])
        let normalizedID = id.hasPrefix("memos/") ? String(id.dropFirst("memos/".count)) : id

        return SnippetRecord(
            id: normalizedID,
            status: status,
            sourcePlatform: sourcePlatform,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            verbatimText: verbatim,
            createdAt: createdAt,
            dataOrigin: dataOrigin,
            conversationContext: conversationContext
        )
    }

    public static func parseContextComment(_ rawComment: String) -> CaptureContext? {
        let normalized = rawComment
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedLeading = normalized.drop(while: { $0.isWhitespace || $0.isNewline })
        guard trimmedLeading.hasPrefix(contextCommentMarker) else {
            return nil
        }

        let afterMarkerLine: Substring
        if let newlineIdx = trimmedLeading.firstIndex(of: "\n") {
            afterMarkerLine = trimmedLeading[trimmedLeading.index(after: newlineIdx)...]
        } else {
            return nil
        }

        let lines = afterMarkerLine.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        var sessionTitle = ""

        while index < lines.count && lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) {
            index += 1
        }

        if index < lines.count, lines[index].hasPrefix("Session Title:") {
            sessionTitle = String(lines[index].dropFirst("Session Title:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
        }

        let recentTurnsHeaderIndex = lines[index...].firstIndex { line in
            trimHorizontalWhitespace(line) == "### Recent Turns"
        }

        let promptEndIndex = recentTurnsHeaderIndex ?? lines.count
        var promptLines = Array(lines[index..<promptEndIndex])
        while let first = promptLines.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) {
            promptLines.removeFirst()
        }

        var prompt = ""
        if let firstPromptLine = promptLines.first, firstPromptLine.hasPrefix("Prompt:") {
            var remainder = firstPromptLine.dropFirst("Prompt:".count)
            if remainder.first == " " {
                remainder = remainder.dropFirst()
            }
            promptLines[0] = remainder
            prompt = promptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var recentTurns: [ConversationTurn] = []
        if let headerIdx = recentTurnsHeaderIndex {
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

            for turnLine in lines[(headerIdx + 1)...] {
                if let (role, firstLineBody) = parseTurnHeader(turnLine) {
                    flushTurn()
                    currentRole = role
                    currentTurnLines = [firstLineBody]
                } else if currentRole != nil {
                    currentTurnLines.append(turnLine)
                }
            }
            flushTurn()
        }

        let context = CaptureContext(
            sessionTitle: sessionTitle,
            prompt: prompt,
            recentTurns: recentTurns
        )
        return context.isEmpty ? nil : context
    }

    private static func parseTurnHeader(_ line: Substring) -> (role: String, body: Substring)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let rawRole = line[..<colonIndex]
        let lowered = rawRole.lowercased()
        guard lowered == "user" || lowered == "assistant" || lowered == "system" else {
            return nil
        }
        var remainder = line[line.index(after: colonIndex)...]
        if remainder.first == " " {
            remainder = remainder.dropFirst()
        }
        return (String(rawRole), remainder)
    }

    private static func nextLine(in text: String, from start: String.Index) -> (line: Substring, nextStart: String.Index)? {
        guard start < text.endIndex else { return nil }
        var end = start
        while end < text.endIndex {
            let ch = text[end]
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                return (text[start..<end], text.index(after: end))
            }
            end = text.index(after: end)
        }
        return (text[start..<text.endIndex], text.endIndex)
    }

    private static func isHorizontalBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func trimHorizontalWhitespace(_ text: Substring) -> String {
        let isHorizontalSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard let first = text.firstIndex(where: { !isHorizontalSpace($0) }),
              let last = text.lastIndex(where: { !isHorizontalSpace($0) }) else {
            return ""
        }
        return String(text[first...last])
    }
}

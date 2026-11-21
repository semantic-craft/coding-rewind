// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum MemosWireFormat {
    public static func isLoopbackMemosHost(_ rawHost: String) -> Bool {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered == "localhost" || lowered == "localhost."
            || lowered.hasSuffix(".localhost") || lowered.hasSuffix(".localhost.") {
            return true
        }
        var addr4 = in_addr()
        if lowered.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return (UInt32(bigEndian: addr4.s_addr) & 0xFF00_0000) == 0x7F00_0000
        }
        let unbracketed: String
        if lowered.hasPrefix("[") && lowered.hasSuffix("]") && lowered.count >= 2 {
            unbracketed = String(lowered.dropFirst().dropLast())
        } else {
            unbracketed = lowered
        }
        var addr6 = in6_addr()
        if unbracketed.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            return bytes.count == 16 && bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
        }
        return false
    }

    public static func isAllowedMemosBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (components.user == nil || components.user?.isEmpty == true),
              (components.password == nil || components.password?.isEmpty == true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            return false
        }
        switch scheme {
        case "https":
            return true
        case "http":
            return isLoopbackMemosHost(host)
        default:
            return false
        }
    }
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

    public static func makeNoteCommentID(snippetID: String, now: Date = Date()) -> String {
        _ = snippetID
        let seconds = now.timeIntervalSince1970
        let epoch = seconds.isFinite && seconds > 0
            ? UInt64(min(seconds, Double(UInt64.max).nextDown))
            : 0
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        var candidate = String("rw-note-\(epoch)-\(suffix)".prefix(36))
        while candidate.hasSuffix("-") {
            candidate.removeLast()
        }
        return candidate
    }

    public static func sanitizeCustomTag(_ raw: String) -> String? {
        var cleaned = raw.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !cleaned.isEmpty,
              cleaned.rangeOfCharacter(from: forbidden) == nil else {
            return nil
        }
        let lowered = cleaned.lowercased()
        if lowered == "rewind" || lowered.hasPrefix("rewind/")
            || lowered == "source" || lowered.hasPrefix("source/") {
            return nil
        }
        return cleaned
    }

    public static func sanitizePlatformToken(_ raw: String, fallback: String) -> String {
        var cleaned = raw.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("#source/") {
            cleaned = String(cleaned.dropFirst("#source/".count))
        } else {
            while cleaned.hasPrefix("#") {
                cleaned.removeFirst()
            }
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !cleaned.isEmpty,
              !cleaned.contains("/"),
              cleaned.rangeOfCharacter(from: forbidden) == nil else {
            return fallback
        }
        return cleaned
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

    public static func normalizeSnippetID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("memos/") ? String(trimmed.dropFirst("memos/".count)) : trimmed
        let forbiddenScalars = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !stripped.isEmpty,
              !stripped.contains("/"),
              stripped != ".",
              stripped != "..",
              !stripped.contains(".."),
              stripped.rangeOfCharacter(from: forbiddenScalars) == nil else {
            throw RewindError.invalidClipID(raw)
        }
        return stripped
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

    public static func escapeMarkdownLinkLabel(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
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
        let escapedTitle = escapeMarkdownLinkLabel(effectiveTitle)
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
                let exposedURL = isAllowedParsedSourceLink(link) ? link : nil
                return (label, exposedURL)
            }
        }
        return (unescapeMarkdownLinkLabel(mainPart.trimmingCharacters(in: .whitespaces)), nil)
    }

    public static func sanitizeMarkdownURL(_ raw: String) -> String {
        let strippedControls = String(raw.unicodeScalars.filter { scalar in
            scalar.value > 0x1F && scalar.value != 0x7F
        })
        let trimmed = strippedControls.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let encoded = trimmed
            .replacingOccurrences(of: #"\s+"#, with: "%20", options: .regularExpression)
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        guard isValidAllowedSourceURL(encoded) else { return "" }
        return encoded
    }

    private static func isValidAllowedSourceURL(_ encoded: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "()"))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }),
              encoded.rangeOfCharacter(from: forbidden) == nil else {
            return false
        }
        let lower = encoded.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let parsed = URL(string: encoded) ?? URL(string: encoded, encodingInvalidCharacters: true),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = parsed.host, !host.isEmpty else {
                return false
            }
            return true
        }
        if lower.hasPrefix("conversation://") {
            let rest = String(encoded.dropFirst("conversation://".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !rest.isEmpty
        }
        if lower.hasPrefix("dsh-session://") {
            let rest = String(encoded.dropFirst("dsh-session://".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !rest.isEmpty
        }
        if lower.hasPrefix("file://") {
            guard (lower.hasPrefix("file:///") || lower.hasPrefix("file://localhost/")),
                  let parsed = URL(string: encoded) ?? URL(string: encoded, encodingInvalidCharacters: true),
                  parsed.scheme?.lowercased() == "file",
                  parsed.isFileURL,
                  !parsed.path.isEmpty else {
                return false
            }
            return true
        }
        return false
    }

    private static func isAllowedParsedSourceLink(_ link: String) -> Bool {
        guard !link.contains(")"),
              isValidAllowedSourceURL(link.replacingOccurrences(of: "(", with: "%28")) else {
            return false
        }
        let lower = link.lowercased()
        if lower.hasPrefix("file://") {
            return lower.hasPrefix("file:///") || lower.hasPrefix("file://localhost/")
        }
        return true
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
        guard label.contains("\\") else { return label }
        var result = String()
        result.reserveCapacity(label.count)
        var cursor = label.startIndex
        while cursor < label.endIndex {
            let ch = label[cursor]
            if ch == "\\" {
                let next = label.index(after: cursor)
                if next < label.endIndex {
                    let escaped = label[next]
                    if escaped == "\\" || escaped == "[" || escaped == "]" {
                        result.append(escaped)
                        cursor = label.index(after: next)
                        continue
                    }
                }
            }
            result.append(ch)
            cursor = label.index(after: cursor)
        }
        return result
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
    public static let noteCommentMarker = "<!-- rewind-note-v1 -->"

    private static func sanitizeSingleLineMetadata(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let singleLine = raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.isEmpty ? nil : singleLine
    }

    private static func sanitizeKeywords(_ rawKeywords: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for rawItem in rawKeywords {
            for piece in rawItem.split(separator: ",") {
                if let cleaned = sanitizeSingleLineMetadata(String(piece)),
                   seen.insert(cleaned.lowercased()).inserted {
                    result.append(cleaned)
                }
            }
        }
        return result
    }

    private static func deduplicateCustomTags(_ rawTags: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for rawTag in rawTags {
            if let cleaned = sanitizeCustomTag(rawTag),
               seen.insert(cleaned.lowercased()).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    public static func formatAgentCreatedContent(
        verbatimText: String,
        sourcePlatform: String = "agent",
        sourceTitle: String = "AI Synthesis",
        sourceURL: String? = nil,
        capturedAt: Date = Date(),
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String] = [],
        tags: [String] = []
    ) throws -> String {
        let cleanedBody = verbatimText.replacingOccurrences(of: "\0", with: "")
        guard !cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        for rawTag in tags where sanitizeCustomTag(rawTag) == nil {
            throw RewindError.invalidMetadataUpdate("Invalid custom tag '\(rawTag)'.")
        }

        let safePlatform = sanitizePlatformToken(sourcePlatform, fallback: "agent")
        let trimmedSourceTitle = sanitizeSingleLineMetadata(sourceTitle) ?? "AI Synthesis"
        let cleanTitle = sanitizeSingleLineMetadata(title)
        let cleanSession = sanitizeSingleLineMetadata(sessionTopic)
        let cleanContext = sanitizeSingleLineMetadata(contextSummary)
        let cleanKeywords = sanitizeKeywords(keywords)
        let customTags = deduplicateCustomTags(tags)

        let hasMetadataHeaders = cleanTitle != nil
            || cleanSession != nil
            || cleanContext != nil
            || !cleanKeywords.isEmpty

        let statusTag = hasMetadataHeaders ? "#rewind/ready" : "#rewind/pending"
        let tagTokens = [statusTag, "#source/\(safePlatform)"] + customTags.map { "#\($0)" }
        let tagLine = tagTokens.joined(separator: " ")

        var headerLines: [String] = []
        if let cleanTitle {
            headerLines.append("> **Title:** \(cleanTitle)")
        }
        if let cleanSession {
            headerLines.append("> **Session:** \(cleanSession)")
        }
        if let cleanContext {
            headerLines.append("> **Context:** \(cleanContext)")
        }
        if !cleanKeywords.isEmpty {
            headerLines.append("> **Keywords:** \(cleanKeywords.joined(separator: ", "))")
        }
        headerLines.append(
            formatSourceLine(
                sourceTitle: trimmedSourceTitle,
                sourcePlatform: safePlatform,
                sourceURL: sourceURL,
                capturedAt: capturedAt
            )
        )

        return "\(tagLine)\n\n\(headerLines.joined(separator: "\n"))\n\n\(cleanedBody)"
    }

    public static func updatingSnippetMetadata(
        rawContent: String,
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String]? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        archived: Bool? = nil
    ) -> String {
        let tokens = headerTokens(rawContent)
        let oldStatus: SnippetStatus = tokens.contains("#rewind/synthesized") ? .synthesized
            : tokens.contains("#rewind/ready") ? .ready
            : .pending
        let hadHasCtx = tokens.contains("#rewind/has-ctx")

        var sourcePlatform = "macos"
        var existingCustomTags: [String] = []
        var seenExistingTags: Set<String> = []
        for token in tokens {
            if token.hasPrefix("#source/") {
                let candidate = String(token.dropFirst("#source/".count))
                if !candidate.isEmpty {
                    sourcePlatform = candidate
                }
            } else if token.hasPrefix("#"),
                      !token.hasPrefix("#rewind/"),
                      let custom = sanitizeCustomTag(String(token)),
                      seenExistingTags.insert(custom.lowercased()).inserted {
                existingCustomTags.append(custom)
            }
        }

        var cursor = nextLine(in: rawContent, from: rawContent.startIndex)?.nextStart ?? rawContent.endIndex
        var existingTitle: String?
        var existingSession: String?
        var existingContext: String?
        var existingKeywords: [String] = []
        var existingSourceLine: String?

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
                    existingTitle = value.isEmpty ? nil : value
                case "> **Session:**":
                    existingSession = value.isEmpty ? nil : value
                case "> **Context:**":
                    existingContext = value.isEmpty ? nil : value
                case "> **Keywords:**":
                    existingKeywords = value
                        .split(separator: ",")
                        .map { trimHorizontalWhitespace($0) }
                        .filter { !$0.isEmpty }
                case "> **Source:**":
                    existingSourceLine = trimHorizontalWhitespace(line)
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
        let verbatimSlice = rawContent[cursor...]

        let effectiveTitle = title != nil ? sanitizeSingleLineMetadata(title) : existingTitle
        let effectiveSession = sessionTopic != nil ? sanitizeSingleLineMetadata(sessionTopic) : existingSession
        let effectiveContext = contextSummary != nil ? sanitizeSingleLineMetadata(contextSummary) : existingContext
        let effectiveKeywords = keywords.map(sanitizeKeywords) ?? existingKeywords

        let removeSet = Set(removeTags.compactMap { sanitizeCustomTag($0)?.lowercased() })
        var mergedTags = existingCustomTags.filter { !removeSet.contains($0.lowercased()) }
        var seenMerged = Set(mergedTags.map { $0.lowercased() })
        for rawAdd in addTags {
            if let cleaned = sanitizeCustomTag(rawAdd),
               seenMerged.insert(cleaned.lowercased()).inserted {
                mergedTags.append(cleaned)
            }
        }

        let hasMetadataHeaders = effectiveTitle != nil
            || effectiveSession != nil
            || effectiveContext != nil
            || !effectiveKeywords.isEmpty

        let newStatus: SnippetStatus
        switch archived {
        case .some(true):
            newStatus = .synthesized
        case .some(false):
            newStatus = (oldStatus == .pending && !hasMetadataHeaders) ? .pending : .ready
        case .none:
            newStatus = (oldStatus == .pending && hasMetadataHeaders) ? .ready : oldStatus
        }

        var outTagTokens: [String] = ["#rewind/\(newStatus.rawValue)"]
        if newStatus == .pending && hadHasCtx {
            outTagTokens.append("#rewind/has-ctx")
        }
        outTagTokens.append("#source/\(sourcePlatform)")
        outTagTokens.append(contentsOf: mergedTags.map { "#\($0)" })
        let tagLine = outTagTokens.joined(separator: " ")

        var metaLines: [String] = []
        if let effectiveTitle {
            metaLines.append("> **Title:** \(effectiveTitle)")
        }
        if let effectiveSession {
            metaLines.append("> **Session:** \(effectiveSession)")
        }
        if let effectiveContext {
            metaLines.append("> **Context:** \(effectiveContext)")
        }
        if !effectiveKeywords.isEmpty {
            metaLines.append("> **Keywords:** \(effectiveKeywords.joined(separator: ", "))")
        }
        if let existingSourceLine {
            metaLines.append(existingSourceLine)
        }

        if metaLines.isEmpty {
            return "\(tagLine)\n\n" + verbatimSlice
        }
        return "\(tagLine)\n\n\(metaLines.joined(separator: "\n"))\n\n" + verbatimSlice
    }

    public static func formatNoteComment(
        note: String,
        author: String? = nil,
        createdAt: Date = Date()
    ) throws -> String {
        let cleanedNote = note.replacingOccurrences(of: "\0", with: "")
        guard !cleanedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.invalidMetadataUpdate("Note text must not be empty.")
        }
        let effectiveAuthor = sanitizeSingleLineMetadata(author) ?? "agent"
        let iso = formatISO8601UTC(createdAt)
        return "\(noteCommentMarker)\nCreated At: \(iso)\nAuthor: \(effectiveAuthor)\n\n\(cleanedNote)"
    }

    public static func parseNoteComment(
        id: String,
        rawComment: String,
        fallbackCreatedAt: Date = Date()
    ) -> SnippetNote? {
        let cleaned = rawComment.replacingOccurrences(of: "\0", with: "")
        var cursor = cleaned.startIndex
        while let (line, afterLine) = nextLine(in: cleaned, from: cursor),
              isHorizontalBlank(line) {
            cursor = afterLine
        }
        guard let (markerLine, afterMarker) = nextLine(in: cleaned, from: cursor),
              trimHorizontalWhitespace(markerLine) == noteCommentMarker else {
            return nil
        }
        cursor = afterMarker

        var parsedCreatedAt: Date?
        var parsedAuthor: String?
        while let (line, afterLine) = nextLine(in: cleaned, from: cursor) {
            if line.hasPrefix("Created At:") {
                let rawDate = trimHorizontalWhitespace(line.dropFirst("Created At:".count))
                parsedCreatedAt = parseISO8601(rawDate)
                cursor = afterLine
            } else if line.hasPrefix("Author:") {
                let rawAuthor = trimHorizontalWhitespace(line.dropFirst("Author:".count))
                if !rawAuthor.isEmpty {
                    parsedAuthor = rawAuthor
                }
                cursor = afterLine
            } else {
                break
            }
        }

        if let (separatorLine, afterSeparator) = nextLine(in: cleaned, from: cursor),
           isHorizontalBlank(separatorLine) {
            cursor = afterSeparator
        }
        let content = String(cleaned[cursor...])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = trimmedID.hasPrefix("memos/") ? String(trimmedID.dropFirst("memos/".count)) : trimmedID
        return SnippetNote(
            id: normalizedID.isEmpty ? "note" : normalizedID,
            author: parsedAuthor ?? "agent",
            content: content,
            createdAt: parsedCreatedAt ?? fallbackCreatedAt
        )
    }

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

    static func headerTokens(_ rawContent: String) -> [Substring] {
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
        guard createdAt >= now.addingTimeInterval(-hotWindow),
              let record = parseSnippetRecord(
                  id: id,
                  rawContent: rawContent,
                  createdAt: createdAt,
                  dataOrigin: isOfflinePending ? .offlinePending : .remote
              ) else {
            return nil
        }
        let cardStatus: CardStatus
        switch record.status {
        case .pending:
            cardStatus = .pending
        case .ready:
            cardStatus = .ready
        case .synthesized:
            return nil
        }
        return RewindCard(
            id: record.id,
            rawContent: rawContent,
            status: cardStatus,
            sourcePlatform: record.sourcePlatform,
            title: record.title,
            sessionTopic: record.sessionTopic,
            contextSummary: record.contextSummary,
            keywords: record.keywords,
            sourceTitle: record.sourceTitle,
            sourceURL: record.sourceURL,
            verbatimText: record.verbatimText,
            createdAt: record.createdAt,
            isOfflinePending: isOfflinePending
        )
    }

    public static func parseSnippetRecord(
        id: String,
        rawContent: String,
        createdAt: Date,
        dataOrigin: SnippetDataOrigin,
        conversationContext: CaptureContext? = nil,
        notes: [SnippetNote] = []
    ) -> SnippetRecord? {
        let tags = headerTokens(rawContent)
        let status: SnippetStatus? = tags.contains("#rewind/synthesized") ? .synthesized
            : tags.contains("#rewind/ready") ? .ready
            : tags.contains("#rewind/pending") ? .pending : nil
        guard let status else {
            return nil
        }

        var sourcePlatform = "macos"
        var customTags: [String] = []
        var seenCustomTags: Set<String> = []
        for token in tags {
            if token.hasPrefix("#source/") {
                let candidate = String(token.dropFirst("#source/".count))
                if !candidate.isEmpty {
                    sourcePlatform = candidate
                }
            } else if token.hasPrefix("#"),
                      !token.hasPrefix("#rewind/"),
                      let custom = sanitizeCustomTag(String(token)),
                      seenCustomTags.insert(custom.lowercased()).inserted {
                customTags.append(custom)
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
            conversationContext: conversationContext,
            tags: customTags,
            notes: notes
        )
    }

    static func nextLine(in text: String, from start: String.Index) -> (line: Substring, nextStart: String.Index)? {
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

    static func isHorizontalBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    static func trimHorizontalWhitespace(_ text: Substring) -> String {
        let isHorizontalSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard let first = text.firstIndex(where: { !isHorizontalSpace($0) }),
              let last = text.lastIndex(where: { !isHorizontalSpace($0) }) else {
            return ""
        }
        return String(text[first...last])
    }
}

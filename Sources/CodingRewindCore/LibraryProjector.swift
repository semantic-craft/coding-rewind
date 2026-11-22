// SPDX-License-Identifier: MIT

import Foundation

public struct ParsedLibraryQuery: Equatable, Sendable {
    public var sourceFilter: CaptureSourceKind?
    public var rawSourceFilter: String?
    public var placeFilter: String?
    public var statusFilter: SnippetStatus?
    public var hasInvalidStatusFilter: Bool = false
    public var isUnplacedOnly: Bool = false
    public var isArchivedOnly: Bool = false
    public var isCodeOnly: Bool = false
    public var freeTextTerms: [String] = []

    public init() {}
}

public enum LibraryProjector {
    private struct RawClipEntry {
        var id: String
        var status: SnippetStatus
        var sourcePlatform: String
        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String]
        var places: [PlaceRef]
        var customTags: [String]
        var sourceTitle: String
        var sourceURL: String?
        var verbatimMarkdown: String
        var createdAt: Date
        var isQueuedOffline: Bool
        var isInHotCards: Bool
        var recordContext: CaptureContext?
        var recordNotes: [SnippetNote]
    }

    public static func parseQuery(_ raw: String) -> ParsedLibraryQuery {
        var parsed = ParsedLibraryQuery()
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        for token in tokens {
            let lowered = token.lowercased()
            if lowered.hasPrefix("source:") {
                let value = String(lowered.dropFirst("source:".count))
                if value.isEmpty {
                    parsed.freeTextTerms.append(lowered)
                } else {
                    parsed.rawSourceFilter = value
                    parsed.sourceFilter = CaptureSourceKind(sourcePlatform: value)
                }
            } else if lowered.hasPrefix("place:") {
                let value = String(lowered.dropFirst("place:".count))
                if value.isEmpty {
                    parsed.freeTextTerms.append(lowered)
                } else {
                    parsed.placeFilter = value
                }
            } else if lowered.hasPrefix("status:") {
                let value = String(lowered.dropFirst("status:".count))
                switch value {
                case "ready":
                    parsed.statusFilter = .ready
                case "pending":
                    parsed.statusFilter = .pending
                case "synthesized", "archived":
                    parsed.statusFilter = .synthesized
                case "":
                    parsed.freeTextTerms.append(lowered)
                default:
                    parsed.hasInvalidStatusFilter = true
                }
            } else if lowered == "is:unplaced" {
                parsed.isUnplacedOnly = true
            } else if lowered == "is:archived" {
                parsed.isArchivedOnly = true
            } else if lowered == "is:code" {
                parsed.isCodeOnly = true
            } else {
                parsed.freeTextTerms.append(lowered)
            }
        }
        return parsed
    }

    public static func project(
        hotCards: [RewindCard],
        libraryRecords: [SnippetRecord],
        placeRecords: [SnippetRecord] = [],
        activePlaces: [PlaceRecord],
        cachedDetails: [String: CardDetail] = [:],
        detailStates: [String: CardDetailLoadState] = [:],
        scope: LibraryScope = .all,
        searchText: String = "",
        focusedClipID: String? = nil,
        triagedInSessionCount: Int = 0,
        archivedClipIDs: Set<String> = [],
        now: Date = Date()
    ) -> LibraryWorkspaceProjection {
        let onlyActivePlaces = activePlaces.filter { !$0.archived }.sorted { $0.ref < $1.ref }
        let activePlaceByRef = Dictionary(uniqueKeysWithValues: onlyActivePlaces.map { ($0.ref, $0) })

        let mergedEntries = mergeEntries(
            hotCards: hotCards,
            libraryRecords: libraryRecords,
            placeRecords: placeRecords,
            archivedClipIDs: archivedClipIDs
        )

        var baseItems: [LibraryClipItem] = []
        baseItems.reserveCapacity(mergedEntries.count)
        var effectiveContextsByID: [String: CaptureContext] = [:]
        var effectiveNotesByID: [String: [SnippetNote]] = [:]

        for entry in mergedEntries {
            let cached = cachedDetails[entry.id]
            let context = cached?.context ?? entry.recordContext
            if let context {
                effectiveContextsByID[entry.id] = context
            }
            let notes = LocalNotesStore.sortAndDeduplicate((cached?.notes ?? []) + entry.recordNotes)
            if !notes.isEmpty {
                effectiveNotesByID[entry.id] = notes
            }
            let item = makeBaseClipItem(from: entry, context: context)
            baseItems.append(item)
        }

        baseItems.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }

        var sessionPlacesByKey: [SessionGroupKey: [PlaceRef]] = [:]
        for item in baseItems where !item.sessionKey.isSyntheticFallback && !item.places.isEmpty {
            var existing = sessionPlacesByKey[item.sessionKey] ?? []
            for ref in item.places where activePlaceByRef[ref] != nil && !existing.contains(ref) {
                existing.append(ref)
            }
            sessionPlacesByKey[item.sessionKey] = existing
        }

        let allItems = baseItems.map { item -> LibraryClipItem in
            guard item.places.isEmpty && item.status != .synthesized else {
                return item
            }
            let suggestions = suggestPlaces(
                for: item,
                sessionPlaces: sessionPlacesByKey[item.sessionKey] ?? [],
                activePlaces: onlyActivePlaces,
                activePlaceByRef: activePlaceByRef
            )
            return withSuggestions(item, suggestedPlaces: suggestions)
        }

        let hotEntryIDs = Set(mergedEntries.filter(\.isInHotCards).map(\.id))
        let scopeCounts = computeScopeCounts(
            items: allItems,
            hotEntryIDs: hotEntryIDs,
            activePlaces: onlyActivePlaces,
            now: now
        )
        let remainingUnplacedCount = scopeCounts[.unplacedInbox] ?? 0

        let scopedItems = allItems.filter { item in
            matchesScope(item, scope: scope, hotEntryIDs: hotEntryIDs, now: now)
        }

        let parsedQuery = parseQuery(searchText)
        let visibleItems: [LibraryClipItem]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visibleItems = scopedItems
        } else {
            visibleItems = scopedItems.compactMap { item in
                matchSearch(
                    item: item,
                    query: parsedQuery,
                    context: effectiveContextsByID[item.id],
                    notes: effectiveNotesByID[item.id] ?? [],
                    activePlaceByRef: activePlaceByRef
                )
            }
        }

        let inspectedItem: LibraryClipItem?
        if let focusedClipID, let matched = visibleItems.first(where: { $0.id == focusedClipID }) {
            inspectedItem = matched
        } else {
            inspectedItem = visibleItems.first
        }

        let inspectedDetailState: CardDetailLoadState
        if let inspectedItem {
            if let explicit = detailStates[inspectedItem.id] {
                inspectedDetailState = explicit
            } else if let cached = cachedDetails[inspectedItem.id] {
                inspectedDetailState = .loaded(cached)
            } else if effectiveContextsByID[inspectedItem.id] != nil || !(effectiveNotesByID[inspectedItem.id] ?? []).isEmpty {
                inspectedDetailState = .loaded(
                    CardDetail(
                        context: effectiveContextsByID[inspectedItem.id],
                        notes: effectiveNotesByID[inspectedItem.id] ?? [],
                        isCompleteFromServer: false
                    )
                )
            } else {
                inspectedDetailState = .idle
            }
        } else {
            inspectedDetailState = .idle
        }

        let relatedPlaceItems: [LibraryClipItem]
        if let inspectedItem {
            let targetRefs = Set(
                !inspectedItem.places.isEmpty
                    ? inspectedItem.places
                    : inspectedItem.suggestedPlaces.map(\.place.ref)
            )
            if targetRefs.isEmpty {
                relatedPlaceItems = []
            } else {
                relatedPlaceItems = Array(
                    allItems
                        .filter { candidate in
                            candidate.id != inspectedItem.id
                                && candidate.places.contains(where: { targetRefs.contains($0) })
                        }
                        .prefix(4)
                )
            }
        } else {
            relatedPlaceItems = []
        }

        let sessionBundles = buildSessionBundles(
            from: visibleItems,
            contextsByID: effectiveContextsByID
        )

        return LibraryWorkspaceProjection(
            visibleItems: visibleItems,
            sessionBundles: sessionBundles,
            inspectedItem: inspectedItem,
            inspectedDetailState: inspectedDetailState,
            relatedPlaceItems: relatedPlaceItems,
            triageProgress: TriageProgressSnapshot(
                remainingUnplacedCount: remainingUnplacedCount,
                triagedInSessionCount: triagedInSessionCount
            ),
            scopeCounts: scopeCounts
        )
    }

    package static func synthesizeRewindCard(from record: SnippetRecord) -> RewindCard {
        let rawContent = buildSynthesizedRawContent(
            status: record.status,
            sourcePlatform: record.sourcePlatform,
            places: record.places,
            customTags: record.tags,
            title: record.title,
            sessionTopic: record.sessionTopic,
            contextSummary: record.contextSummary,
            keywords: record.keywords,
            sourceTitle: record.sourceTitle,
            sourceURL: record.sourceURL,
            verbatimText: record.verbatimText,
            createdAt: record.createdAt
        )
        return RewindCard(
            id: record.id,
            rawContent: rawContent,
            status: record.status == .pending ? .pending : .ready,
            sourcePlatform: record.sourcePlatform,
            title: record.title,
            sessionTopic: record.sessionTopic,
            contextSummary: record.contextSummary,
            keywords: record.keywords,
            sourceTitle: record.sourceTitle,
            sourceURL: record.sourceURL,
            verbatimText: record.verbatimText,
            createdAt: record.createdAt,
            isOfflinePending: record.dataOrigin == .offlinePending
        )
    }

    private static func buildSynthesizedRawContent(
        status: SnippetStatus,
        sourcePlatform: String,
        places: [PlaceRef],
        customTags: [String],
        title: String?,
        sessionTopic: String?,
        contextSummary: String?,
        keywords: [String],
        sourceTitle: String,
        sourceURL: String?,
        verbatimText: String,
        createdAt: Date
    ) -> String {
        let safePlatform = MemosWireFormat.sanitizePlatformToken(sourcePlatform, fallback: "macos")
        var tagTokens = ["#rewind/\(status.rawValue)", "#source/\(safePlatform)"]
        var seenTags = Set(tagTokens.map { $0.lowercased() })
        for ref in places {
            let token = "#\(ref.tag)"
            if seenTags.insert(token.lowercased()).inserted {
                tagTokens.append(token)
            }
        }
        for rawTag in customTags {
            if let cleaned = MemosWireFormat.sanitizeCustomTag(rawTag) {
                let token = "#\(cleaned)"
                if seenTags.insert(token.lowercased()).inserted {
                    tagTokens.append(token)
                }
            }
        }
        var headerLines: [String] = []
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerLines.append("> **Title:** \(title)")
        }
        if let sessionTopic, !sessionTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerLines.append("> **Session:** \(sessionTopic)")
        }
        if let contextSummary, !contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerLines.append("> **Context:** \(contextSummary)")
        }
        if !keywords.isEmpty {
            headerLines.append("> **Keywords:** \(keywords.joined(separator: ", "))")
        }
        headerLines.append(
            MemosWireFormat.formatSourceLine(
                sourceTitle: sourceTitle,
                sourcePlatform: safePlatform,
                sourceURL: sourceURL,
                capturedAt: createdAt
            )
        )
        return "\(tagTokens.joined(separator: " "))\n\n\(headerLines.joined(separator: "\n"))\n\n\(verbatimText)"
    }

    private static func mergeEntries(
        hotCards: [RewindCard],
        libraryRecords: [SnippetRecord],
        placeRecords: [SnippetRecord],
        archivedClipIDs: Set<String>
    ) -> [RawClipEntry] {
        var entriesByID: [String: RawClipEntry] = [:]

        for record in libraryRecords {
            entriesByID[record.id] = entry(from: record)
        }

        for record in placeRecords {
            let incoming = entry(from: record)
            if let existing = entriesByID[record.id] {
                entriesByID[record.id] = mergeRecordEntry(existing: existing, newer: incoming)
            } else {
                entriesByID[record.id] = incoming
            }
        }

        for card in hotCards {
            let cardCustomTags = extractCustomTags(from: card)
            if var existing = entriesByID[card.id] {
                existing.isInHotCards = true
                existing.isQueuedOffline = card.isOfflinePending
                if existing.status == .synthesized && archivedClipIDs.contains(card.id) {
                    existing.status = .synthesized
                } else {
                    existing.status = card.status == .ready ? .ready : .pending
                }
                existing.title = card.title ?? existing.title
                existing.sessionTopic = card.sessionTopic ?? existing.sessionTopic
                existing.contextSummary = card.contextSummary ?? existing.contextSummary
                if !card.keywords.isEmpty { existing.keywords = card.keywords }
                existing.places = card.places
                if card.isOfflinePending || !cardCustomTags.isEmpty || card.rawContent.hasPrefix("#rewind/") {
                    existing.customTags = cardCustomTags
                }
                entriesByID[card.id] = existing
            } else {
                entriesByID[card.id] = RawClipEntry(
                    id: card.id,
                    status: card.status == .ready ? .ready : .pending,
                    sourcePlatform: card.sourcePlatform,
                    title: card.title,
                    sessionTopic: card.sessionTopic,
                    contextSummary: card.contextSummary,
                    keywords: card.keywords,
                    places: card.places,
                    customTags: cardCustomTags,
                    sourceTitle: card.sourceTitle,
                    sourceURL: card.sourceURL,
                    verbatimMarkdown: card.verbatimText,
                    createdAt: card.createdAt,
                    isQueuedOffline: card.isOfflinePending,
                    isInHotCards: true,
                    recordContext: nil,
                    recordNotes: []
                )
            }
        }

        return Array(entriesByID.values)
    }

    private static func entry(from record: SnippetRecord) -> RawClipEntry {
        var customTags: [String] = []
        var seen: Set<String> = []
        for tag in record.tags where PlaceRef(tag: tag) == nil {
            if seen.insert(tag.lowercased()).inserted {
                customTags.append(tag)
            }
        }
        return RawClipEntry(
            id: record.id,
            status: record.status,
            sourcePlatform: record.sourcePlatform,
            title: record.title,
            sessionTopic: record.sessionTopic,
            contextSummary: record.contextSummary,
            keywords: record.keywords,
            places: record.places,
            customTags: customTags,
            sourceTitle: record.sourceTitle,
            sourceURL: record.sourceURL,
            verbatimMarkdown: record.verbatimText,
            createdAt: record.createdAt,
            isQueuedOffline: record.dataOrigin == .offlinePending,
            isInHotCards: false,
            recordContext: record.conversationContext,
            recordNotes: record.notes
        )
    }

    private static func mergeRecordEntry(existing: RawClipEntry, newer: RawClipEntry) -> RawClipEntry {
        var merged = newer
        if existing.status == .synthesized && newer.status != .synthesized {
            merged.status = .synthesized
        }
        if merged.title == nil { merged.title = existing.title }
        if merged.sessionTopic == nil { merged.sessionTopic = existing.sessionTopic }
        if merged.contextSummary == nil { merged.contextSummary = existing.contextSummary }
        if merged.keywords.isEmpty { merged.keywords = existing.keywords }
        if merged.places.isEmpty { merged.places = existing.places }
        if merged.customTags.isEmpty { merged.customTags = existing.customTags }
        if merged.recordContext == nil { merged.recordContext = existing.recordContext }
        merged.recordNotes = LocalNotesStore.sortAndDeduplicate(existing.recordNotes + newer.recordNotes)
        return merged
    }

    private static func extractCustomTags(from card: RewindCard) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for token in MemosWireFormat.headerTokens(card.rawContent) {
            if token.hasPrefix("#"),
               !token.hasPrefix("#rewind/"),
               !token.hasPrefix("#source/"),
               let cleaned = MemosWireFormat.sanitizeCustomTag(String(token)),
               PlaceRef(tag: cleaned) == nil,
               seen.insert(cleaned.lowercased()).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    private static func makeBaseClipItem(from entry: RawClipEntry, context: CaptureContext?) -> LibraryClipItem {
        let locator = SourceLocator.parse(sourceURL: entry.sourceURL)
        let sessionKey = deriveSessionGroupKey(
            sourcePlatform: entry.sourcePlatform,
            sourceTitle: entry.sourceTitle,
            createdAt: entry.createdAt,
            locator: locator,
            context: context
        )
        let resolvedTitle: String
        if let rawTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty {
            resolvedTitle = rawTitle
        } else {
            resolvedTitle = collapseSingleLine(entry.verbatimMarkdown, maxChars: 80) ?? entry.sourceTitle
        }
        let eyebrow = collapseSingleLine(context?.prompt, maxChars: 100)
            ?? collapseSingleLine(entry.contextSummary, maxChars: 100)
            ?? collapseSingleLine(entry.sessionTopic, maxChars: 100)
        let (codePreviewLines, isCodeDominant) = extractCodePreview(from: entry.verbatimMarkdown)

        return LibraryClipItem(
            id: entry.id,
            source: CaptureSourceKind(sourcePlatform: entry.sourcePlatform),
            sourcePlatform: entry.sourcePlatform,
            sourceTitle: entry.sourceTitle,
            sourceURL: entry.sourceURL,
            sourceLocator: locator,
            sessionKey: sessionKey,
            sessionTopic: entry.sessionTopic,
            contextSummary: entry.contextSummary,
            keywords: entry.keywords,
            title: resolvedTitle,
            precedingPromptEyebrow: eyebrow,
            verbatimMarkdown: entry.verbatimMarkdown,
            codePreviewLines: codePreviewLines,
            isCodeDominant: isCodeDominant,
            places: entry.places,
            customTags: entry.customTags,
            suggestedPlaces: [],
            hitSlot: nil,
            status: entry.status,
            isQueuedOffline: entry.isQueuedOffline,
            createdAt: entry.createdAt
        )
    }

    private static func deriveSessionGroupKey(
        sourcePlatform: String,
        sourceTitle: String,
        createdAt: Date,
        locator: SourceLocator?,
        context: CaptureContext?
    ) -> SessionGroupKey {
        if let locator {
            switch locator {
            case .antigravitySession(let id):
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty {
                    return SessionGroupKey(rawValue: "sid:\(trimmed)", isSyntheticFallback: false)
                }
            case .dshSession(let id):
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty {
                    return SessionGroupKey(rawValue: "sid:\(trimmed)", isSyntheticFallback: false)
                }
            case .web(let url, let extractedSessionID):
                if let sid = extractedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
                    return SessionGroupKey(rawValue: "sid:\(sid.lowercased())", isSyntheticFallback: false)
                }
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let host = (components?.host ?? url.host ?? "").lowercased()
                var path = components?.path ?? url.path
                while path.count > 1 && path.hasSuffix("/") {
                    path.removeLast()
                }
                if path.contains("/app/") || path.contains("/c/") {
                    return SessionGroupKey(rawValue: "web:\(host)\(path)", isSyntheticFallback: false)
                }
            }
        }
        if let sid = context?.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            return SessionGroupKey(rawValue: "sid:\(sid.lowercased())", isSyntheticFallback: false)
        }
        let dayBucket = utcDayBucket(createdAt)
        return SessionGroupKey(
            rawValue: "fallback:\(sourcePlatform):\(sourceTitle):\(dayBucket)",
            isSyntheticFallback: true
        )
    }

    private static func utcDayBucket(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func collapseSingleLine(_ raw: String?, maxChars: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxChars else { return collapsed }
        let prefix = String(collapsed.prefix(max(1, maxChars - 1))).trimmingCharacters(in: .whitespaces)
        return "\(prefix)…"
    }

    private static func extractCodePreview(from verbatimMarkdown: String) -> (String, Bool) {
        let normalized = verbatimMarkdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var fenceStartIndex: Int?
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenceStartIndex = idx
                break
            }
        }

        if let start = fenceStartIndex {
            var codeLines: [String] = []
            for line in lines.dropFirst(start + 1) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    break
                }
                if !trimmed.isEmpty {
                    codeLines.append(line)
                    if codeLines.count == 5 {
                        break
                    }
                }
            }
            if !codeLines.isEmpty {
                return (codeLines.joined(separator: "\n"), true)
            }
        }

        let codeKeywordPrefixes = [
            "func ", "struct ", "class ", "let ", "const ", "def ", "import ", "return "
        ]
        var codeLikeCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if line.hasPrefix("  ") || line.hasPrefix("\t")
                || codeKeywordPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                codeLikeCount += 1
            }
        }

        if codeLikeCount >= 2 {
            let preview = Array(
                lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(5)
            ).joined(separator: "\n")
            return (preview, true)
        }

        let proseLines = Array(
            lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(4)
        )
        return (proseLines.joined(separator: "\n"), false)
    }

    private static func suggestPlaces(
        for item: LibraryClipItem,
        sessionPlaces: [PlaceRef],
        activePlaces: [PlaceRecord],
        activePlaceByRef: [PlaceRef: PlaceRecord]
    ) -> [SuggestedPlaceCandidate] {
        var candidates: [SuggestedPlaceCandidate] = []
        var seenRefs: Set<PlaceRef> = []

        for ref in sessionPlaces {
            guard let place = activePlaceByRef[ref], seenRefs.insert(ref).inserted else { continue }
            candidates.append(SuggestedPlaceCandidate(place: place, reason: .sameSessionInherited))
            if candidates.count == 2 {
                return candidates
            }
        }

        let haystack = [
            item.title,
            item.sessionTopic ?? "",
            item.contextSummary ?? "",
            item.keywords.joined(separator: " "),
            item.sourceTitle,
            item.verbatimMarkdown
        ].joined(separator: "\n").lowercased()

        let keywordTokens = (item.keywords + [item.title, item.sessionTopic ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        for place in activePlaces {
            guard !seenRefs.contains(place.ref) else { continue }
            let needles = ([place.title, place.ref.slug.rawValue] + place.aliases)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            let directSubstringMatch = needles.contains(where: { haystack.contains($0) })
            let fuzzyTokenMatch = keywordTokens.contains { token in
                if let score = place.fuzzyScore(token), score <= 1 {
                    return true
                }
                return false
            }

            if directSubstringMatch || fuzzyTokenMatch {
                seenRefs.insert(place.ref)
                candidates.append(SuggestedPlaceCandidate(place: place, reason: .keywordAlias))
                if candidates.count == 2 {
                    break
                }
            }
        }

        return candidates
    }

    private static func withSuggestions(
        _ item: LibraryClipItem,
        suggestedPlaces: [SuggestedPlaceCandidate],
        hitSlot: SearchHitSlot? = nil
    ) -> LibraryClipItem {
        LibraryClipItem(
            id: item.id,
            source: item.source,
            sourcePlatform: item.sourcePlatform,
            sourceTitle: item.sourceTitle,
            sourceURL: item.sourceURL,
            sourceLocator: item.sourceLocator,
            sessionKey: item.sessionKey,
            sessionTopic: item.sessionTopic,
            contextSummary: item.contextSummary,
            keywords: item.keywords,
            title: item.title,
            precedingPromptEyebrow: item.precedingPromptEyebrow,
            verbatimMarkdown: item.verbatimMarkdown,
            codePreviewLines: item.codePreviewLines,
            isCodeDominant: item.isCodeDominant,
            places: item.places,
            customTags: item.customTags,
            suggestedPlaces: suggestedPlaces,
            hitSlot: hitSlot ?? item.hitSlot,
            status: item.status,
            isQueuedOffline: item.isQueuedOffline,
            createdAt: item.createdAt
        )
    }

    private static func computeScopeCounts(
        items: [LibraryClipItem],
        hotEntryIDs: Set<String>,
        activePlaces: [PlaceRecord],
        now: Date
    ) -> [LibraryScope: Int] {
        var counts: [LibraryScope: Int] = [
            .all: 0,
            .unplacedInbox: 0,
            .hot72Hours: 0,
            .archived: 0
        ]
        for kind in CaptureSourceKind.allCases {
            counts[.source(kind)] = 0
        }
        for place in activePlaces {
            counts[.place(place.ref)] = 0
        }

        for item in items {
            if item.status == .synthesized {
                counts[.archived, default: 0] += 1
            } else {
                counts[.all, default: 0] += 1
                if item.places.isEmpty {
                    counts[.unplacedInbox, default: 0] += 1
                }
                if hotEntryIDs.contains(item.id) || now.timeIntervalSince(item.createdAt) <= RewindCard.hotWindowSeconds {
                    counts[.hot72Hours, default: 0] += 1
                }
                if let source = item.source {
                    counts[.source(source), default: 0] += 1
                }
            }
            for ref in item.places where counts[.place(ref)] != nil {
                counts[.place(ref), default: 0] += 1
            }
        }
        return counts
    }

    private static func matchesScope(
        _ item: LibraryClipItem,
        scope: LibraryScope,
        hotEntryIDs: Set<String>,
        now: Date
    ) -> Bool {
        switch scope {
        case .all:
            return item.status != .synthesized
        case .unplacedInbox:
            return item.status != .synthesized && item.places.isEmpty
        case .hot72Hours:
            return item.status != .synthesized
                && (hotEntryIDs.contains(item.id) || now.timeIntervalSince(item.createdAt) <= RewindCard.hotWindowSeconds)
        case .archived:
            return item.status == .synthesized
        case .source(let kind):
            return item.status != .synthesized && item.source == kind
        case .place(let ref):
            return item.places.contains(ref)
        }
    }

    private static func matchSearch(
        item: LibraryClipItem,
        query: ParsedLibraryQuery,
        context: CaptureContext?,
        notes: [SnippetNote],
        activePlaceByRef: [PlaceRef: PlaceRecord]
    ) -> LibraryClipItem? {
        if query.hasInvalidStatusFilter {
            return nil
        }
        if let rawSource = query.rawSourceFilter {
            if let sourceKind = query.sourceFilter {
                guard item.source == sourceKind else { return nil }
            } else {
                guard item.sourcePlatform.lowercased() == rawSource else { return nil }
            }
        }
        if let placeFilter = query.placeFilter {
            let matchedPlace: Bool
            if let exactRef = PlaceRef(tag: placeFilter) {
                matchedPlace = item.places.contains(exactRef)
            } else {
                matchedPlace = item.places.contains { ref in
                    ref.slug.rawValue == placeFilter || ref.tag == placeFilter
                }
            }
            guard matchedPlace else { return nil }
        }
        if let statusFilter = query.statusFilter {
            guard item.status == statusFilter else { return nil }
        }
        if query.isUnplacedOnly {
            guard item.status != .synthesized && item.places.isEmpty else { return nil }
        }
        if query.isArchivedOnly {
            guard item.status == .synthesized else { return nil }
        }
        if query.isCodeOnly {
            guard item.isCodeDominant else { return nil }
        }

        let terms = query.freeTextTerms
        guard !terms.isEmpty else {
            return withSuggestions(item, suggestedPlaces: item.suggestedPlaces, hitSlot: nil)
        }

        let placeStrings = item.places.flatMap { ref -> [String] in
            var values = [ref.tag, ref.slug.rawValue]
            if let record = activePlaceByRef[ref] {
                values.append(record.title)
                values.append(contentsOf: record.aliases)
            }
            return values
        }
        let metadataHaystack = (
            [
                item.title,
                item.sessionTopic ?? "",
                item.contextSummary ?? "",
                item.sourceTitle,
                item.sourcePlatform
            ]
            + item.keywords
            + item.customTags
            + placeStrings
        ).joined(separator: "\n").lowercased()

        let verbatimHaystack = item.verbatimMarkdown.lowercased()

        let promptContextHaystack: String = {
            guard let context else { return "" }
            var parts = [context.prompt, context.sessionTitle]
            if let opening = context.sessionOpening {
                parts.append(opening)
            }
            if let lead = context.pageLead {
                parts.append(lead)
            }
            parts.append(contentsOf: context.recentTurns.map(\.text))
            return parts.joined(separator: "\n").lowercased()
        }()

        let agentNoteHaystack = notes.map(\.content).joined(separator: "\n").lowercased()

        let slots: [(SearchHitSlot, String)] = [
            (.metadata, metadataHaystack),
            (.verbatimBody, verbatimHaystack),
            (.promptContext, promptContextHaystack),
            (.agentNote, agentNoteHaystack)
        ]

        for (slot, haystack) in slots {
            if terms.allSatisfy({ haystack.contains($0) }) {
                return withSuggestions(item, suggestedPlaces: item.suggestedPlaces, hitSlot: slot)
            }
        }

        let combinedHaystack = slots.map(\.1).joined(separator: "\n")
        guard terms.allSatisfy({ combinedHaystack.contains($0) }) else {
            return nil
        }
        let fallbackSlot = slots.first(where: { _, haystack in
            terms.contains(where: { haystack.contains($0) })
        })?.0 ?? .metadata
        return withSuggestions(item, suggestedPlaces: item.suggestedPlaces, hitSlot: fallbackSlot)
    }

    private static func buildSessionBundles(
        from visibleItems: [LibraryClipItem],
        contextsByID: [String: CaptureContext]
    ) -> [LibrarySessionBundle] {
        var grouped: [SessionGroupKey: [LibraryClipItem]] = [:]
        for item in visibleItems {
            grouped[item.sessionKey, default: []].append(item)
        }

        var bundles: [LibrarySessionBundle] = []
        bundles.reserveCapacity(grouped.count)

        for (key, rawClips) in grouped {
            let clips = rawClips.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            }
            guard let first = clips.first else { continue }

            let source = clips.compactMap(\.source).first
            let sourcePlatform = first.sourcePlatform
            let sessionTitle = clips.compactMap { clip -> String? in
                if let topic = clip.sessionTopic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
                    return topic
                }
                if let ctxTitle = contextsByID[clip.id]?.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                   !ctxTitle.isEmpty {
                    return ctxTitle
                }
                return nil
            }.first ?? first.sourceTitle

            let sessionOpening = clips.compactMap { clip -> String? in
                if case .sessionOpening(let text) = contextsByID[clip.id]?.lead, !text.isEmpty {
                    return text
                }
                return nil
            }.first

            var uniquePlaces: [PlaceRef] = []
            var seenPlaces: Set<PlaceRef> = []
            for clip in clips {
                for ref in clip.places where seenPlaces.insert(ref).inserted {
                    uniquePlaces.append(ref)
                }
            }

            let latestClipAt = clips.map(\.createdAt).max() ?? first.createdAt
            bundles.append(
                LibrarySessionBundle(
                    key: key,
                    source: source,
                    sourcePlatform: sourcePlatform,
                    sessionTitle: sessionTitle,
                    sessionOpening: sessionOpening,
                    places: uniquePlaces,
                    clips: clips,
                    latestClipAt: latestClipAt
                )
            )
        }

        return bundles.sorted { lhs, rhs in
            if lhs.latestClipAt != rhs.latestClipAt {
                return lhs.latestClipAt > rhs.latestClipAt
            }
            return lhs.key.rawValue < rhs.key.rawValue
        }
    }
}

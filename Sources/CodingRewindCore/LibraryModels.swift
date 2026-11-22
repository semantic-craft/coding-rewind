// SPDX-License-Identifier: MIT

import Foundation

public enum CaptureSourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case geminiWeb = "gemini"
    case antigravity = "antigravity"
    case chatGPTApp = "chatgpt"

    public init?(sourcePlatform: String) {
        switch sourcePlatform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini":
            self = .geminiWeb
        case "antigravity":
            self = .antigravity
        case "chatgpt":
            self = .chatGPTApp
        default:
            return nil
        }
    }
}

public enum SearchHitSlot: String, Codable, Equatable, Hashable, Sendable {
    case metadata
    case verbatimBody
    case promptContext
    case agentNote
}

public enum LibraryScope: Equatable, Hashable, Sendable {
    case all
    case unplacedInbox
    case hot72Hours
    case archived
    case source(CaptureSourceKind)
    case place(PlaceRef)
}

public enum LibraryLayoutMode: String, CaseIterable, Codable, Hashable, Sendable {
    case bentoCards
    case sessionTimeline
}

public struct SessionGroupKey: Hashable, Codable, Sendable {
    public let rawValue: String
    public let isSyntheticFallback: Bool

    public init(rawValue: String, isSyntheticFallback: Bool) {
        self.rawValue = rawValue
        self.isSyntheticFallback = isSyntheticFallback
    }
}

public struct SuggestedPlaceCandidate: Equatable, Hashable, Sendable {
    public enum MatchReason: Equatable, Hashable, Sendable {
        case keywordAlias
        case sameSessionInherited
    }

    public let place: PlaceRecord
    public let reason: MatchReason

    public init(place: PlaceRecord, reason: MatchReason) {
        self.place = place
        self.reason = reason
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(place.ref)
        hasher.combine(place.title)
        hasher.combine(place.aliases)
        hasher.combine(place.externalRef)
        hasher.combine(place.archived)
        hasher.combine(reason)
    }
}

public struct LibraryClipItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: CaptureSourceKind?
    public let sourcePlatform: String
    public let sourceTitle: String
    public let sourceURL: String?
    public let sourceLocator: SourceLocator?
    public let sessionKey: SessionGroupKey
    public let sessionTopic: String?
    public let contextSummary: String?
    public let keywords: [String]
    public let title: String
    public let precedingPromptEyebrow: String?
    public let verbatimMarkdown: String
    public let codePreviewLines: String
    public let isCodeDominant: Bool
    public let places: [PlaceRef]
    public let customTags: [String]
    public let suggestedPlaces: [SuggestedPlaceCandidate]
    public let hitSlot: SearchHitSlot?
    public let status: SnippetStatus
    public let isQueuedOffline: Bool
    public let createdAt: Date

    public init(
        id: String,
        source: CaptureSourceKind?,
        sourcePlatform: String,
        sourceTitle: String,
        sourceURL: String?,
        sourceLocator: SourceLocator?,
        sessionKey: SessionGroupKey,
        sessionTopic: String?,
        contextSummary: String?,
        keywords: [String],
        title: String,
        precedingPromptEyebrow: String?,
        verbatimMarkdown: String,
        codePreviewLines: String,
        isCodeDominant: Bool,
        places: [PlaceRef],
        customTags: [String],
        suggestedPlaces: [SuggestedPlaceCandidate],
        hitSlot: SearchHitSlot?,
        status: SnippetStatus,
        isQueuedOffline: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.source = source
        self.sourcePlatform = sourcePlatform
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourceLocator = sourceLocator
        self.sessionKey = sessionKey
        self.sessionTopic = sessionTopic
        self.contextSummary = contextSummary
        self.keywords = keywords
        self.title = title
        self.precedingPromptEyebrow = precedingPromptEyebrow
        self.verbatimMarkdown = verbatimMarkdown
        self.codePreviewLines = codePreviewLines
        self.isCodeDominant = isCodeDominant
        self.places = places
        self.customTags = customTags
        self.suggestedPlaces = suggestedPlaces
        self.hitSlot = hitSlot
        self.status = status
        self.isQueuedOffline = isQueuedOffline
        self.createdAt = createdAt
    }
}

public struct LibrarySessionBundle: Identifiable, Equatable, Sendable {
    public var id: SessionGroupKey { key }
    public let key: SessionGroupKey
    public let source: CaptureSourceKind?
    public let sourcePlatform: String
    public let sessionTitle: String
    public let sessionOpening: String?
    public let places: [PlaceRef]
    public let clips: [LibraryClipItem]
    public let latestClipAt: Date

    public init(
        key: SessionGroupKey,
        source: CaptureSourceKind?,
        sourcePlatform: String,
        sessionTitle: String,
        sessionOpening: String?,
        places: [PlaceRef],
        clips: [LibraryClipItem],
        latestClipAt: Date
    ) {
        self.key = key
        self.source = source
        self.sourcePlatform = sourcePlatform
        self.sessionTitle = sessionTitle
        self.sessionOpening = sessionOpening
        self.places = places
        self.clips = clips
        self.latestClipAt = latestClipAt
    }
}

public struct TriageProgressSnapshot: Equatable, Sendable {
    public let remainingUnplacedCount: Int
    public let triagedInSessionCount: Int

    public init(remainingUnplacedCount: Int, triagedInSessionCount: Int) {
        self.remainingUnplacedCount = remainingUnplacedCount
        self.triagedInSessionCount = triagedInSessionCount
    }
}

public struct LibraryWorkspaceProjection: Equatable, Sendable {
    public let visibleItems: [LibraryClipItem]
    public let sessionBundles: [LibrarySessionBundle]
    public let inspectedItem: LibraryClipItem?
    public let inspectedDetailState: CardDetailLoadState
    public let relatedPlaceItems: [LibraryClipItem]
    public let triageProgress: TriageProgressSnapshot
    public let scopeCounts: [LibraryScope: Int]

    public init(
        visibleItems: [LibraryClipItem],
        sessionBundles: [LibrarySessionBundle],
        inspectedItem: LibraryClipItem?,
        inspectedDetailState: CardDetailLoadState,
        relatedPlaceItems: [LibraryClipItem],
        triageProgress: TriageProgressSnapshot,
        scopeCounts: [LibraryScope: Int]
    ) {
        self.visibleItems = visibleItems
        self.sessionBundles = sessionBundles
        self.inspectedItem = inspectedItem
        self.inspectedDetailState = inspectedDetailState
        self.relatedPlaceItems = relatedPlaceItems
        self.triageProgress = triageProgress
        self.scopeCounts = scopeCounts
    }
}

public enum LibraryUserIntent: Equatable, Sendable {
    case selectScope(LibraryScope)
    case setLayoutMode(LibraryLayoutMode)
    case focusClip(String?)
    case stepFocus(delta: Int)
    case toggleChecked(String)
    case clearChecked
    case acceptSuggestedPlaces(clipID: String, refs: [PlaceRef], advanceFocus: Bool)
    case openPlacePicker(clipID: String)
    case removePlace(clipID: String, ref: PlaceRef)
    case archiveClips([String])
    case unarchiveClips([String])
    case requestDelete([String], immediate: Bool)
    case appendNote(clipID: String, text: String)
    case triggerSourceAction(LibraryClipItem)
    case stageAndOpenHandoff(clipIDs: [String])
}

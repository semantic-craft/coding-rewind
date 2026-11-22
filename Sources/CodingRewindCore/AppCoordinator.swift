// SPDX-License-Identifier: MIT

import Foundation
import Observation

public protocol SelectionCapturing: Sendable {
    func captureFrontmostSelection() async throws -> CapturedSelection
}

public enum SelectionCaptureOutcome: Equatable, Sendable {
    case ignoredBusy
    case saved(cardID: String, sourceTitle: String)
    case queuedOffline(cardID: String)
    case failed(RewindError)
}

public enum StatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case ready
    case pending

    public func label(in language: AppLanguage) -> String {
        L10n.statusFilterLabel(self, in: language)
    }

    public var label: String {
        label(in: .zhHans)
    }
}

public struct MenuStatusSnapshot: Equatable, Sendable {
    public enum ConnectionState: Equatable, Sendable {
        case configured(hostSummary: String, baseURL: URL)
        case unconfigured
    }

    public enum AttentionIssue: Equatable, Hashable, Sendable {
        case accessibilityPermission
        case activeHostPlugin(ConversationHost)
    }

    public struct RecentCardItem: Equatable, Sendable, Identifiable {
        public let id: String
        public let titlePreview: String
        public let sourcePlatform: String
        public let isChecked: Bool

        public init(id: String, titlePreview: String, sourcePlatform: String, isChecked: Bool) {
            self.id = id
            self.titlePreview = titlePreview
            self.sourcePlatform = sourcePlatform
            self.isChecked = isChecked
        }
    }

    public let isHUDVisible: Bool
    public let hotCardCount: Int
    public let checkedCardCount: Int
    public let pendingOutboxCount: Int
    public let connection: ConnectionState
    public let isPluginReady: Bool
    public let isDSHPluginReady: Bool
    public let pluginSummary: String
    public let isAccessibilityTrusted: Bool
    public let recentCards: [RecentCardItem]
    public let conversationHost: ConversationHost
    public let language: AppLanguage

    public init(
        isHUDVisible: Bool,
        hotCardCount: Int,
        checkedCardCount: Int,
        pendingOutboxCount: Int,
        connection: ConnectionState,
        isPluginReady: Bool,
        isDSHPluginReady: Bool = false,
        pluginSummary: String,
        isAccessibilityTrusted: Bool,
        recentCards: [RecentCardItem],
        conversationHost: ConversationHost = .antigravity,
        language: AppLanguage = .zhHans
    ) {
        self.isHUDVisible = isHUDVisible
        self.hotCardCount = hotCardCount
        self.checkedCardCount = checkedCardCount
        self.pendingOutboxCount = pendingOutboxCount
        self.connection = connection
        self.isPluginReady = isPluginReady
        self.isDSHPluginReady = isDSHPluginReady
        self.pluginSummary = pluginSummary
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.recentCards = recentCards
        self.conversationHost = conversationHost
        self.language = language
    }

    public var headerTitle: String {
        L10n.menuHeaderTitle(hotCardCount: hotCardCount, pendingOutboxCount: pendingOutboxCount, in: language)
    }

    public var headerSubtitle: String {
        L10n.menuHeaderSubtitle(connection: connection, in: language)
    }

    public var toggleHUDTitle: String {
        L10n.menuToggleHUDTitle(isHUDVisible: isHUDVisible, in: language)
    }

    public var attentionIssues: [AttentionIssue] {
        var issues: [AttentionIssue] = []
        if !isAccessibilityTrusted {
            issues.append(.accessibilityPermission)
        }
        switch conversationHost {
        case .antigravity where !isPluginReady:
            issues.append(.activeHostPlugin(.antigravity))
        case .dsh where !isDSHPluginReady:
            issues.append(.activeHostPlugin(.dsh))
        case .antigravity, .dsh:
            break
        }
        return issues
    }

    public var attentionTitle: String? {
        L10n.menuAttentionTitle(issues: attentionIssues, in: language)
    }
}

public enum ConnectionCheckOutcome: Equatable, Sendable {
    case localOnly
    case missingToken
    case verified
    case failed(RewindError)
}

public struct PendingDeleteConfirmation: Equatable, Sendable {
    public let cardIDs: [String]
    public let allOfflinePending: Bool

    public init(cardIDs: [String], allOfflinePending: Bool) {
        self.cardIDs = cardIDs
        self.allOfflinePending = allOfflinePending
    }
}

public struct CardDetail: Equatable, Sendable {
    public let context: CaptureContext?
    public let notes: [SnippetNote]
    public let isCompleteFromServer: Bool

    public init(
        context: CaptureContext? = nil,
        notes: [SnippetNote] = [],
        isCompleteFromServer: Bool
    ) {
        self.context = context
        self.notes = notes
        self.isCompleteFromServer = isCompleteFromServer
    }
}

public enum CardDetailLoadState: Equatable, Sendable {
    case idle
    case loading(partial: CardDetail?)
    case loaded(CardDetail)
    case failed(partial: CardDetail?, message: String)
}

public struct ConversationDraft: Equatable, Sendable {
    public var cardIDs: [String]
    public var text: String
    public var isEdited: Bool
    public var targetHost: ConversationHost?

    public init(
        cardIDs: [String],
        text: String,
        isEdited: Bool = false,
        targetHost: ConversationHost? = nil
    ) {
        self.cardIDs = cardIDs
        self.text = text
        self.isEdited = isEdited
        self.targetHost = targetHost
    }
}

@MainActor
@Observable
public final class AppCoordinator {
    private struct ConversationHostChannel {
        let store: ConversationHandoffStore
        let requiresExplicitConversationOpen: Bool
        let readinessFailure: @MainActor () -> BannerNotice?
        let dispatch: @MainActor (ConversationHandoffStore) async throws -> Void
    }

    public let paths: StoragePaths
    public var environment: [String: String] {
        didSet {
            aiAccessMode = paths.resolveAIAccessMode(environment: environment)
        }
    }
    public let memosClient: MemosClient
    public let outbox: OfflineOutbox
    public let hotCache: HotCache
    public private(set) var language: AppLanguage
    public private(set) var aiAccessMode: AIAccessMode
    private var mcpBinaryStateRevision = 0
    private let hostChannels: [ConversationHost: ConversationHostChannel]
    public var conversationHost: ConversationHost = .antigravity {
        didSet {
            do { try AtomicFile.writeData(JSONEncoder().encode(conversationHost), to: conversationHostURL) }
            catch { setErrorBanner(error) }
        }
    }
    private var conversationHostURL: URL { paths.dataDirectoryURL.appendingPathComponent("conversation-host.json") }
    public private(set) var activeConversationHost: ConversationHost?
    public private(set) var confirmedConversation: ConversationReference?
    public private(set) var conversationDraft: ConversationDraft?
    @ObservationIgnored private var stashedEditedDraft: ConversationDraft?
    public var effectiveConversationHost: ConversationHost {
        activeConversationHost ?? conversationDraft?.targetHost ?? conversationHost
    }
    public var hasActiveHandoffConversation: Bool {
        if activeConversationHost != nil || canEndUnarchivedConversation || canEndUnconfirmedConversation {
            return true
        }
        return (try? activeConversation()) != nil
    }
    public var conversationActionTitle: String {
        L10n.conversationActionTitle(
            isLaunching: isLaunchingConversation,
            canEndUnarchived: canEndUnarchivedConversation,
            hasActiveConversation: activeConversationHost != nil,
            hasConfirmedConversation: confirmedConversation != nil,
            in: language
        )
    }
    public private(set) var isLaunchingConversation = false
    public private(set) var canEndUnconfirmedConversation = false
    public private(set) var canEndUnarchivedConversation = false
    public internal(set) var pendingDeleteConfirmation: PendingDeleteConfirmation?
    public private(set) var isMutatingCards = false
    public private(set) var lockedConversationCardIDs: Set<String> = []
    var deletedClipIDs: Set<String> = []
    var archivedClipIDs: Set<String> = []
    private var inFlightCaptureEntries: [String: OutboxEntry] = [:]
    private var pendingRemoteDeletesURL: URL {
        paths.dataDirectoryURL.appendingPathComponent("pending-remote-deletes.json", isDirectory: false)
    }
    private var pendingRemoteDeleteIDs: Set<String> = []
    private let antigravityContext: AntigravityCaptureContext
    private let dshBinaryURLProvider: @Sendable () -> URL?
    private let dshActionRunner: @Sendable (String) async -> Bool
    public var capturer: any SelectionCapturing

    public private(set) var isCapturingSelection = false
    private var activeExternalCaptureCount = 0
    private var latestRefreshRequest = 0
    private var localCardsRevision = 0
    public var markSynthesizedOnLaunch = false
    private struct RefreshTicket {
        let request: Int
        let localRevision: Int
    }
    public private(set) var cards: [RewindCard] = []
    public var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                pendingDeleteConfirmation = nil
                reconcileInspectedCardVisibility()
            }
        }
    }
    public var statusFilter: StatusFilter = .all {
        didSet {
            if oldValue != statusFilter {
                pendingDeleteConfirmation = nil
                reconcileInspectedCardVisibility()
            }
        }
    }
    public var hudSection: HUDSection = .hot {
        didSet {
            if oldValue != hudSection {
                pendingDeleteConfirmation = nil
                placePicker = nil
                reconcileInspectedCardVisibility()
            }
        }
    }
    public internal(set) var places: [PlaceRecord] = []
    public internal(set) var libraryRecords: [SnippetRecord]?
    public internal(set) var placeRecords: [SnippetRecord] = []
    public internal(set) var placePicker: PlacePickerState?
    public var focusedRecordID: String?
    @ObservationIgnored var libraryRevision = 0
    public var libraryScope: LibraryScope = .all {
        didSet {
            if oldValue != libraryScope {
                pendingDeleteConfirmation = nil
            }
        }
    }
    public var libraryLayoutMode: LibraryLayoutMode = .bentoCards
    public var librarySearchText: String = "" {
        didSet {
            if oldValue != librarySearchText {
                pendingDeleteConfirmation = nil
            }
        }
    }
    public var libraryFocusedClipID: String?
    public var isLibraryInspectorPresented: Bool = true
    public internal(set) var triagedInSessionCount: Int = 0
    public var checkedCardIDs: Set<String> = []
    public var focusedCardID: String?
    public private(set) var inspectedCardID: String?
    var cardDetailStates: [String: CardDetailLoadState] = [:]
    @ObservationIgnored var cachedCardDetails: [String: CardDetail] = [:]
    @ObservationIgnored private var activeDetailTask: Task<Void, Never>?
    @ObservationIgnored private var activeDetailTaskGeneration: UInt64 = 0
    private var activeBannerNotice: BannerNotice?
    private var isUpdatingBannerFromNotice = false
    private var lastPluginInstallFailureNotice: BannerNotice?
    private var lastDSHPluginInstallFailureNotice: BannerNotice?
    public var bannerMessage: String? {
        didSet {
            if !isUpdatingBannerFromNotice && bannerMessage == nil {
                activeBannerNotice = nil
            }
        }
    }
    public var isErrorBanner: Bool = false
    public var pluginStatusText: String = ""
    public var dshPluginStatusText: String = ""

    public var onOpenURL: (@MainActor (URL) -> Bool)?
    public var onCopyText: (@MainActor (String) -> Void) = { _ in }
    public var onWakeHost: (@MainActor (ConversationHost) -> Void)?
    public var onActivateHostApp: (@MainActor (ConversationHost) -> Bool)?
    public var onOpenConversation: (@MainActor (ConversationReference) -> Bool)?

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memosClient: MemosClient = MemosClient(),
        capturer: any SelectionCapturing,
        antigravityContext: AntigravityCaptureContext = AntigravityCaptureContext(),
        language: AppLanguage = .zhHans,
        dshBinaryURLProvider: (@Sendable () -> URL?)? = nil,
        dshReadinessCheck: (@MainActor () -> Bool)? = nil,
        dshActionRunner: (@Sendable (String) async -> Bool)? = nil
    ) throws {
        self.paths = paths
        self.environment = environment
        self.memosClient = memosClient
        self.outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        self.hotCache = HotCache(fileURL: paths.hotCacheFileURL)
        self.language = language
        self.aiAccessMode = paths.resolveAIAccessMode(environment: environment)
        let resolvedBinaryProvider: @Sendable () -> URL? = dshBinaryURLProvider ?? {
            DSHIntegration.resolveDSHBinaryURL(environment: environment)
        }
        self.dshBinaryURLProvider = resolvedBinaryProvider
        self.dshActionRunner = dshActionRunner ?? { sessionID in
            guard let actionStore = try? DSHActionStore(dataDirectoryURL: paths.dataDirectoryURL) else {
                return false
            }
            return await actionStore.openSession(sessionID: sessionID)
        }
        let antigravityStore = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .antigravity)
        let dshStore = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .dsh)
        self.hostChannels = [
            .antigravity: ConversationHostChannel(
                store: antigravityStore,
                requiresExplicitConversationOpen: ConversationHost.antigravity.requiresExplicitConversationOpen,
                readinessFailure: {
                    if !AntigravityIntegration.repairReasons(
                        dataDirectoryURL: paths.dataDirectoryURL,
                        configDirectoryURL: paths.antigravityConfigDirectoryURL
                    ).isEmpty {
                        return .needsAntigravityPlugin
                    }
                    return nil
                },
                dispatch: { _ in }
            ),
            .dsh: ConversationHostChannel(
                store: dshStore,
                requiresExplicitConversationOpen: ConversationHost.dsh.requiresExplicitConversationOpen,
                readinessFailure: {
                    if let dshReadinessCheck {
                        return dshReadinessCheck() ? nil : .needsDSHPlugin
                    }
                    let reasons = DSHIntegration.repairReasons(
                        dataDirectoryURL: paths.dataDirectoryURL,
                        dshHomeURL: paths.dshHomeDirectoryURL,
                        dshBinaryURL: resolvedBinaryProvider()
                    )
                    return reasons.isEmpty ? nil : .needsDSHPlugin
                },
                dispatch: { _ in }
            )
        ]
        self.antigravityContext = antigravityContext
        self.capturer = capturer
        if FileManager.default.fileExists(atPath: pendingRemoteDeletesURL.path),
           let pendingData = try? Data(contentsOf: pendingRemoteDeletesURL),
           let pendingIDs = try? JSONDecoder().decode([String].self, from: pendingData) {
            pendingRemoteDeleteIDs = Set(pendingIDs)
            deletedClipIDs.formUnion(pendingRemoteDeleteIDs)
        }
        self.cards = Self.mergeCards(
            cached: hotCache.loadCards().filter { !deletedClipIDs.contains($0.id) },
            pendingOutbox: activeOutboxEntries()
        )
        self.focusedCardID = self.cards.first?.id
        self.places = PlacesCache(fileURL: paths.placesCacheFileURL).load()
        if FileManager.default.fileExists(atPath: conversationHostURL.path) {
            let hostData = try Data(contentsOf: conversationHostURL)
            let rawHostString = try? JSONDecoder().decode(String.self, from: hostData)
            let decodedHost = try JSONDecoder().decode(ConversationHost.self, from: hostData)
            conversationHost = decodedHost
            if rawHostString == "codex" {
                try AtomicFile.writeData(JSONEncoder().encode(decodedHost), to: conversationHostURL)
            }
        }
        if let (host, _, current, receipt) = try activeConversation(clearingTerminalFailures: true) {
            activeConversationHost = host
            checkedCardIDs = Set(current.cardIDs)
            if receipt?.state == .succeeded, let id = receipt?.conversationId {
                confirmedConversation = ConversationReference(host: host, id: id)
            }
            canEndUnconfirmedConversation = receipt?.state == .unknown
            canEndUnarchivedConversation = receipt?.state == .succeeded && current.markSynthesized && !current.archiveCardIDs.isEmpty
            lockedConversationCardIDs = canEndUnarchivedConversation ? Set(current.archiveCardIDs) : Set(current.cardIDs)
            setBanner(
                canEndUnarchivedConversation ? .resumeUnarchivedStartup : .resumePendingStartup,
                isError: false
            )
        }
        refreshPluginStatus()
        refreshDSHPluginStatus()
    }

    public func setLanguage(_ language: AppLanguage) {
        self.language = language
        aiAccessMode = paths.resolveAIAccessMode(environment: environment)
        try? AntigravityPluginInstaller(paths: paths).refreshLocalizedMetadataIfInstalled(language: language)
        if let failureNotice = lastPluginInstallFailureNotice {
            pluginStatusText = L10n.banner(failureNotice, in: language)
        } else {
            refreshPluginStatus()
        }
        if let dshFailureNotice = lastDSHPluginInstallFailureNotice {
            dshPluginStatusText = L10n.banner(dshFailureNotice, in: language)
        } else {
            refreshDSHPluginStatus()
        }
        if let activeBannerNotice {
            isUpdatingBannerFromNotice = true
            bannerMessage = L10n.banner(activeBannerNotice, in: language)
            isUpdatingBannerFromNotice = false
        }
        refreshUneditedConversationDraftIfNeeded()
    }

    public func recordStartupWarning(_ message: String) {
        setBanner(.custom(message), isError: true)
    }

    public var filteredCards: [RewindCard] {
        guard hudSection == .hot else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cards.filter { card in
            switch statusFilter {
            case .all: break
            case .ready: if card.status != .ready { return false }
            case .pending: if card.status != .pending { return false }
            }
            guard !query.isEmpty else { return true }
            let haystack = [
                card.title ?? "",
                card.sessionTopic ?? "",
                card.contextSummary ?? "",
                card.keywords.joined(separator: " "),
                card.sourceTitle,
                card.verbatimText
            ].joined(separator: "\n").lowercased()
            return haystack.contains(query) || placesMatch(card.places, query: query)
        }
    }

    public func toggleCheck(for cardID: String) {
        pendingDeleteConfirmation = nil
        if checkedCardIDs.contains(cardID) {
            checkedCardIDs.remove(cardID)
        } else {
            checkedCardIDs.insert(cardID)
        }
    }

    public func toggleFocusedCardCheck() {
        guard hudSection == .hot else { return }
        let targetID = focusedCardID ?? filteredCards.first?.id
        if let targetID {
            toggleCheck(for: targetID)
        }
    }

    public func focusAndCheckCard(id: String) {
        guard cards.contains(where: { $0.id == id }) else { return }
        pendingDeleteConfirmation = nil
        dismissConversationDraft()
        focusedCardID = id
        checkedCardIDs.insert(id)
    }

    public func isCardLocked(_ cardID: String) -> Bool {
        lockedConversationCardIDs.contains(cardID)
    }

    func resolvableCardsForHandoff() -> [RewindCard] {
        var result = cards
        var seen = Set(cards.map(\.id))
        for record in (libraryRecords ?? []) + placeRecords {
            guard !deletedClipIDs.contains(record.id),
                  seen.insert(record.id).inserted else {
                continue
            }
            result.append(LibraryProjector.synthesizeRewindCard(from: record))
        }
        return result
    }

    public var checkedActionableCardIDs: [String] {
        resolvableCardsForHandoff().map(\.id).filter { checkedCardIDs.contains($0) }
    }

    public var targetActionCardIDs: [String] {
        let checked = checkedActionableCardIDs
        if !checked.isEmpty {
            return checked
        }
        if let inspected = inspectedCardID, filteredCards.contains(where: { $0.id == inspected }) {
            return [inspected]
        }
        if let focused = focusedCardID, filteredCards.contains(where: { $0.id == focused }) {
            return [focused]
        }
        return filteredCards.first.map { [$0.id] } ?? []
    }

    public func cancelDeleteConfirmation() {
        pendingDeleteConfirmation = nil
    }

    func reconcilePendingDeleteConfirmation(idRemapping: [String: String] = [:]) {
        guard let current = pendingDeleteConfirmation else { return }
        var visibleByID = Dictionary(uniqueKeysWithValues: filteredCards.map { ($0.id, $0) })
        if libraryRecords != nil || !placeRecords.isEmpty {
            let libraryVisibleIDs = Set(libraryProjection.visibleItems.map(\.id))
            let hotIDs = Set(cards.map(\.id))
            for card in resolvableCardsForHandoff() where libraryVisibleIDs.contains(card.id) {
                if !hotIDs.contains(card.id) || hudSection != .hot || libraryFocusedClipID != nil {
                    visibleByID[card.id] = visibleByID[card.id] ?? card
                }
            }
        }
        var seen: Set<String> = []
        var updatedCards: [RewindCard] = []
        for rawID in current.cardIDs {
            let resolvedID = idRemapping[rawID] ?? rawID
            guard let card = visibleByID[resolvedID],
                  seen.insert(resolvedID).inserted else {
                continue
            }
            updatedCards.append(card)
        }
        if updatedCards.isEmpty {
            pendingDeleteConfirmation = nil
        } else {
            pendingDeleteConfirmation = PendingDeleteConfirmation(
                cardIDs: updatedCards.map(\.id),
                allOfflinePending: updatedCards.allSatisfy(\.isOfflinePending)
            )
        }
    }

    public func menuStatusSnapshot(isHUDVisible: Bool, isAccessibilityTrusted: Bool) -> MenuStatusSnapshot {
        let connection: MenuStatusSnapshot.ConnectionState
        if let baseURL = paths.resolveMemosBaseURL(environment: environment),
           let host = baseURL.host,
           !host.isEmpty {
            let scheme = baseURL.scheme?.lowercased()
            let defaultPort: Int? = (scheme == "https") ? 443 : (scheme == "http" ? 80 : nil)
            let hostSummary: String
            if let port = baseURL.port, port != defaultPort {
                hostSummary = "\(host):\(port)"
            } else {
                hostSummary = host
            }
            connection = .configured(hostSummary: hostSummary, baseURL: baseURL)
        } else {
            connection = .unconfigured
        }

        let reasons = AntigravityIntegration.repairReasons(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        )
        let isPluginReady = reasons.isEmpty
        let isDSHPluginReady = DSHIntegration.repairReasons(
            dataDirectoryURL: paths.dataDirectoryURL,
            dshHomeURL: paths.dshHomeDirectoryURL,
            dshBinaryURL: dshBinaryURLProvider()
        ).isEmpty
        let pluginSummary = isPluginReady
            ? L10n.pluginInstalledSummary(in: language)
            : L10n.pluginNeedsRepairSummary(firstReason: reasons.first, in: language)

        let checkedCount = cards.reduce(into: 0) { count, card in
            if checkedCardIDs.contains(card.id) {
                count += 1
            }
        }
        let pendingCount = outbox.loadEntries().count
        let recent = cards.prefix(5).map { card in
            MenuStatusSnapshot.RecentCardItem(
                id: card.id,
                titlePreview: Self.makeMenuPreviewText(for: card),
                sourcePlatform: card.sourcePlatform,
                isChecked: checkedCardIDs.contains(card.id)
            )
        }

        return MenuStatusSnapshot(
            isHUDVisible: isHUDVisible,
            hotCardCount: cards.count,
            checkedCardCount: checkedCount,
            pendingOutboxCount: pendingCount,
            connection: connection,
            isPluginReady: isPluginReady,
            isDSHPluginReady: isDSHPluginReady,
            pluginSummary: pluginSummary,
            isAccessibilityTrusted: isAccessibilityTrusted,
            recentCards: recent,
            conversationHost: effectiveConversationHost,
            language: language
        )
    }

    private static func makeMenuPreviewText(for card: RewindCard, maxCharacters: Int = 36) -> String {
        let rawSource: String
        if let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            rawSource = title
        } else {
            rawSource = card.verbatimText
        }
        let collapsed = rawSource
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxCharacters else {
            return collapsed
        }
        let prefix = String(collapsed.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces)
        return "\(prefix)…"
    }

    @discardableResult
    public func captureSelection() async -> SelectionCaptureOutcome {
        guard !isCapturingSelection else { return .ignoredBusy }
        isCapturingSelection = true
        defer {
            localCardsRevision += 1
            isCapturingSelection = false
        }
        do {
            let selection = try await capturer.captureFrontmostSelection()
            let (platform, sourceTitle, sourceURL, context) = await buildProvenance(from: selection)
            return await ingestClip(
                verbatimText: selection.text,
                platform: platform,
                sourceTitle: sourceTitle,
                sourceURL: sourceURL,
                context: context,
                capturedAt: selection.capturedAt
            )
        } catch {
            let rewindError = (error as? RewindError) ?? .ioError(error.localizedDescription)
            setBanner(.rewindError(rewindError), isError: true)
            return .failed(rewindError)
        }
    }

    public func captureExternalDSHRequest(_ request: DSHCaptureBridgeRequest) async -> DSHCaptureBridgeReceipt {
        let nowMs: () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000.0).rounded()) }
        let cleanedText = request.text.replacingOccurrences(of: "\0", with: "")
        guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DSHCaptureBridgeReceipt(
                captureId: request.captureId,
                state: .failed,
                clipId: nil,
                error: RewindError.emptySelection.localizedDescription(in: language),
                updatedAtMs: nowMs()
            )
        }

        activeExternalCaptureCount += 1
        defer {
            localCardsRevision += 1
            activeExternalCaptureCount -= 1
        }

        let cleanedSessionID = DSHCaptureContext.sanitizeSessionID(request.sessionId)
        let cleanedTitle = request.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTitle = (cleanedTitle?.isEmpty == false) ? cleanedTitle! : "DSH"
        let sourceURL = cleanedSessionID.map { "dsh-session://\($0)" }
        let context: CaptureContext?
        if let messages = request.messages, !messages.isEmpty {
            context = DSHCaptureContext.sliceContext(
                selectedText: cleanedText,
                messages: messages,
                sessionTitle: sourceTitle,
                sessionID: cleanedSessionID
            )
        } else {
            context = nil
        }
        let capturedAt = request.createdAtMs > 0
            ? Date(timeIntervalSince1970: Double(request.createdAtMs) / 1000.0)
            : Date()

        let outcome = await ingestClip(
            verbatimText: cleanedText,
            platform: "dsh",
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            context: context,
            capturedAt: capturedAt
        )
        switch outcome {
        case .saved(let cardID, _):
            return DSHCaptureBridgeReceipt(
                captureId: request.captureId,
                state: .saved,
                clipId: cardID,
                error: nil,
                updatedAtMs: nowMs()
            )
        case .queuedOffline(let cardID):
            return DSHCaptureBridgeReceipt(
                captureId: request.captureId,
                state: .queuedOffline,
                clipId: cardID,
                error: nil,
                updatedAtMs: nowMs()
            )
        case .failed(let rewindError):
            return DSHCaptureBridgeReceipt(
                captureId: request.captureId,
                state: .failed,
                clipId: nil,
                error: rewindError.localizedDescription(in: language),
                updatedAtMs: nowMs()
            )
        case .ignoredBusy:
            return DSHCaptureBridgeReceipt(
                captureId: request.captureId,
                state: .failed,
                clipId: nil,
                error: "busy",
                updatedAtMs: nowMs()
            )
        }
    }

    private func ingestClip(
        verbatimText: String,
        platform: String,
        sourceTitle: String,
        sourceURL: String?,
        context: CaptureContext?,
        capturedAt: Date
    ) async -> SelectionCaptureOutcome {
        var provisionalCardID: String?
        let previousFocusedCardID = focusedCardID
        do {
            let hasContext = (context?.isEmpty == false)
            let clientClipId = MemosWireFormat.makeClientClipID(now: capturedAt)
            deletedClipIDs.remove(clientClipId)
            archivedClipIDs.remove(clientClipId)
            let rawContent = try MemosWireFormat.formatRawMemoContent(
                verbatimText: verbatimText,
                sourcePlatform: platform,
                sourceTitle: sourceTitle,
                sourceURL: sourceURL,
                capturedAt: capturedAt,
                hasContext: hasContext
            )
            let commentContent = hasContext ? context?.formattedCommentMarkdown() : nil
            let entry = OutboxEntry(
                clientClipId: clientClipId,
                memoContent: rawContent,
                commentContent: commentContent,
                createdAt: capturedAt
            )
            inFlightCaptureEntries[clientClipId] = entry
            defer { inFlightCaptureEntries.removeValue(forKey: clientClipId) }

            if let localCard = MemosWireFormat.parseMemo(
                id: clientClipId,
                rawContent: rawContent,
                createdAt: capturedAt,
                now: max(Date(), capturedAt),
                isOfflinePending: true
            ) {
                provisionalCardID = localCard.id
                updateLocalCards { cards in
                    cards.removeAll { $0.id == localCard.id }
                    cards.insert(localCard, at: 0)
                }
                checkedCardIDs.insert(localCard.id)
                focusedCardID = localCard.id
            }

            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                try outbox.enqueue(entry)
                setBanner(.savedOfflineNeedsConfig, isError: false)
                return .queuedOffline(cardID: clientClipId)
            }

            do {
                if let flushed = (try? await outbox.flush(using: memosClient, baseURL: baseURL, token: token))?.flushed,
                   !flushed.isEmpty {
                    let liveFlushed = await reconcileFlushedOutboxItems(flushed, baseURL: baseURL, token: token)
                    applyFlushedOutboxItems(liveFlushed)
                }
                if deletedClipIDs.contains(clientClipId) {
                    return .failed(.emptySelection)
                }
                if archivedClipIDs.contains(clientClipId) {
                    return .saved(cardID: clientClipId, sourceTitle: sourceTitle)
                }
                let deletedBeforeCreate = deletedClipIDs
                let archivedBeforeCreate = archivedClipIDs
                let saved = try await memosClient.createClip(
                    clientClipId: clientClipId,
                    content: rawContent,
                    contextComment: commentContent,
                    baseURL: baseURL,
                    token: token,
                    fallbackCreatedAt: capturedAt
                )
                let deletedDuringCreate = deletedClipIDs.contains(clientClipId)
                    || (!deletedBeforeCreate.contains(saved.id) && deletedClipIDs.contains(saved.id))
                if deletedDuringCreate {
                    deletedClipIDs.insert(saved.id)
                    removeSupersededProvisionalCard(clientClipId: clientClipId, savedID: saved.id)
                    await deleteMemoOrQueuePending(id: saved.id, baseURL: baseURL, token: token)
                    return .failed(.emptySelection)
                }
                let archivedDuringCreate = archivedClipIDs.contains(clientClipId)
                    || (!archivedBeforeCreate.contains(saved.id) && archivedClipIDs.contains(saved.id))
                if archivedDuringCreate {
                    archivedClipIDs.insert(saved.id)
                    removeSupersededProvisionalCard(clientClipId: clientClipId, savedID: saved.id)
                    return .saved(cardID: saved.id, sourceTitle: sourceTitle)
                }
                inFlightCaptureEntries.removeValue(forKey: clientClipId)
                deletedClipIDs.remove(saved.id)
                archivedClipIDs.remove(saved.id)
                clearPendingRemoteDelete(saved.id)
                updateLocalCards { cards in
                    cards.removeAll { $0.id == clientClipId || $0.id == saved.id }
                    cards.insert(saved, at: 0)
                }
                checkedCardIDs.remove(clientClipId)
                checkedCardIDs.insert(saved.id)
                focusedCardID = saved.id
                let idRemap = (saved.id == clientClipId) ? [:] : [clientClipId: saved.id]
                if saved.id != clientClipId {
                    try? LocalNotesStore(fileURL: paths.localNotesFileURL).remapCardID(from: clientClipId, to: saved.id)
                    removeObsoleteLocalRecordID(clientClipId, replacedBy: saved.id)
                }
                remapCardDetailState(from: clientClipId, to: saved.id)
                reconcilePendingDeleteConfirmation(idRemapping: idRemap)
                reconcileConversationDraftState(idRemapping: idRemap)
                reconcileInspectedCardVisibility()
                if inspectedCardID == saved.id, cachedCardDetails[saved.id]?.isCompleteFromServer != true {
                    reloadCardDetail(id: saved.id)
                }
                setBanner(.savedClip(sourceTitle: sourceTitle), isError: false)
                return .saved(cardID: saved.id, sourceTitle: sourceTitle)
            } catch {
                if deletedClipIDs.contains(clientClipId) {
                    return .failed(.emptySelection)
                }
                if archivedClipIDs.contains(clientClipId) {
                    return .saved(cardID: clientClipId, sourceTitle: sourceTitle)
                }
                try outbox.enqueue(entry)
                setBanner(.savedOfflineTemporaryFailure, isError: false)
                return .queuedOffline(cardID: clientClipId)
            }
        } catch {
            if let provisionalCardID {
                checkedCardIDs.remove(provisionalCardID)
                updateLocalCards { cards in
                    cards.removeAll { $0.id == provisionalCardID }
                }
                if focusedCardID == provisionalCardID {
                    focusedCardID = cards.contains(where: { $0.id == previousFocusedCardID })
                        ? previousFocusedCardID
                        : cards.first?.id
                }
                reconcilePendingDeleteConfirmation()
                reconcileConversationDraftState()
            }
            let rewindError = (error as? RewindError) ?? .ioError(error.localizedDescription)
            setBanner(.rewindError(rewindError), isError: true)
            return .failed(rewindError)
        }
    }

    public func refresh() async {
        latestRefreshRequest += 1
        let ticket = RefreshTicket(request: latestRefreshRequest, localRevision: localCardsRevision)
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment) else {
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: cards, pendingOutbox: activeOutboxEntries())
            if focusedCardID == nil {
                focusedCardID = cards.first?.id
            }
            reconcilePendingDeleteConfirmation()
            reconcileConversationDraftState()
            reconcileInspectedCardVisibility()
            pruneRemovedCardDetails()
            if let currentInspected = inspectedCardID {
                reloadCardDetail(id: currentInspected)
            }
            return
        }
        do {
            let (flushed, _) = try await outbox.flush(using: memosClient, baseURL: baseURL, token: token)
            if !flushed.isEmpty {
                let liveFlushed = await reconcileFlushedOutboxItems(flushed, baseURL: baseURL, token: token)
                if !liveFlushed.isEmpty {
                    applyFlushedOutboxItems(liveFlushed)
                }
            }
            await drainPendingRemoteDeletes(baseURL: baseURL, token: token)
            let remoteCards = try await memosClient.listHotClips(baseURL: baseURL, token: token)
                .filter { !deletedClipIDs.contains($0.id) && !archivedClipIDs.contains($0.id) }
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: remoteCards, pendingOutbox: activeOutboxEntries())
            try? hotCache.saveCards(cards)
            if focusedCardID == nil {
                focusedCardID = cards.first?.id
            }
            reconcilePendingDeleteConfirmation()
            reconcileConversationDraftState()
            invalidateAndReconcileCardDetailsAfterRefresh()
        } catch {
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: cards, pendingOutbox: activeOutboxEntries())
            reconcilePendingDeleteConfirmation()
            reconcileConversationDraftState()
            reconcileInspectedCardVisibility()
            pruneRemovedCardDetails()
            setBanner(.syncFailedShowingLocal, isError: true)
        }
    }

    private func activeOutboxEntries() -> [OutboxEntry] {
        outbox.loadEntries().filter {
            !deletedClipIDs.contains($0.clientClipId) && !archivedClipIDs.contains($0.clientClipId)
        }
    }

    private func recordPendingRemoteDelete(_ id: String) {
        deletedClipIDs.insert(id)
        guard pendingRemoteDeleteIDs.insert(id).inserted else { return }
        persistPendingRemoteDeletes()
    }

    private func clearPendingRemoteDelete(_ id: String) {
        guard pendingRemoteDeleteIDs.remove(id) != nil else { return }
        persistPendingRemoteDeletes()
    }

    private func persistPendingRemoteDeletes() {
        if pendingRemoteDeleteIDs.isEmpty {
            if FileManager.default.fileExists(atPath: pendingRemoteDeletesURL.path) {
                try? FileManager.default.removeItem(at: pendingRemoteDeletesURL)
            }
            return
        }
        if let data = try? JSONEncoder().encode(pendingRemoteDeleteIDs.sorted()) {
            try? AtomicFile.writeData(data, to: pendingRemoteDeletesURL, permissions: 0o600)
        }
    }

    private func removeSupersededProvisionalCard(clientClipId: String, savedID: String) {
        let ids: Set<String> = [clientClipId, savedID]
        guard cards.contains(where: { ids.contains($0.id) })
            || !checkedCardIDs.isDisjoint(with: ids) else {
            return
        }
        removeCardsFromCoordinatorState(ids)
    }

    private func deleteMemoOrQueuePending(id: String, baseURL: URL, token: String) async {
        do {
            _ = try await memosClient.deleteMemo(id: id, baseURL: baseURL, token: token)
            clearPendingRemoteDelete(id)
        } catch RewindError.invalidClipID {
            clearPendingRemoteDelete(id)
        } catch {
            recordPendingRemoteDelete(id)
        }
    }

    private func drainPendingRemoteDeletes(baseURL: URL, token: String) async {
        for id in pendingRemoteDeleteIDs.sorted() {
            await deleteMemoOrQueuePending(id: id, baseURL: baseURL, token: token)
        }
    }

    private func reconcileFlushedOutboxItems(
        _ flushed: [(clientClipId: String, card: RewindCard)],
        baseURL: URL,
        token: String
    ) async -> [(clientClipId: String, card: RewindCard)] {
        var remaining = flushed
        while true {
            var nextLive: [(clientClipId: String, card: RewindCard)] = []
            var staleDeleted: [(clientClipId: String, card: RewindCard)] = []
            for item in remaining {
                if archivedClipIDs.contains(item.clientClipId) || archivedClipIDs.contains(item.card.id) {
                    continue
                }
                if deletedClipIDs.contains(item.clientClipId) || deletedClipIDs.contains(item.card.id) {
                    staleDeleted.append(item)
                } else {
                    nextLive.append(item)
                }
            }
            guard !staleDeleted.isEmpty else {
                return nextLive
            }
            for item in staleDeleted {
                deletedClipIDs.insert(item.card.id)
                await deleteMemoOrQueuePending(id: item.card.id, baseURL: baseURL, token: token)
            }
            remaining = nextLive
        }
    }

    private func applyFlushedOutboxItems(_ flushed: [(clientClipId: String, card: RewindCard)]) {
        let activeFlushed = flushed.filter {
            !deletedClipIDs.contains($0.clientClipId)
            && !deletedClipIDs.contains($0.card.id)
            && !archivedClipIDs.contains($0.clientClipId)
            && !archivedClipIDs.contains($0.card.id)
        }
        guard !activeFlushed.isEmpty else {
            reconcilePendingDeleteConfirmation()
            return
        }
        let localNotesStore = LocalNotesStore(fileURL: paths.localNotesFileURL)
        var remappedIDs: [String: String] = [:]
        var flushedTargetIDs: Set<String> = []
        for item in activeFlushed {
            remappedIDs[item.clientClipId] = item.card.id
            flushedTargetIDs.insert(item.card.id)
            if item.clientClipId != item.card.id {
                try? localNotesStore.remapCardID(from: item.clientClipId, to: item.card.id)
                removeObsoleteLocalRecordID(item.clientClipId, replacedBy: item.card.id)
            }
            if checkedCardIDs.remove(item.clientClipId) != nil {
                checkedCardIDs.insert(item.card.id)
            }
            if focusedCardID == item.clientClipId {
                focusedCardID = item.card.id
            }
            if lockedConversationCardIDs.contains(item.clientClipId) {
                lockedConversationCardIDs.insert(item.card.id)
            }
            remapCardDetailState(from: item.clientClipId, to: item.card.id)
        }
        let pendingEntries = activeOutboxEntries()
        let flushedIDs = Set(activeFlushed.flatMap { [$0.clientClipId, $0.card.id] })
        let updated = cards.filter {
            !flushedIDs.contains($0.id)
            && !deletedClipIDs.contains($0.id)
            && !archivedClipIDs.contains($0.id)
        } + activeFlushed.map(\.card)
        cards = Self.mergeCards(cached: updated, pendingOutbox: pendingEntries)
        try? hotCache.saveCards(cards)
        if focusedCardID == nil {
            focusedCardID = cards.first?.id
        }
        reconcilePendingDeleteConfirmation(idRemapping: remappedIDs)
        reconcileConversationDraftState(idRemapping: remappedIDs)
        reconcileInspectedCardVisibility()
        if let currentInspected = inspectedCardID,
           flushedTargetIDs.contains(currentInspected),
           cachedCardDetails[currentInspected]?.isCompleteFromServer != true {
            reloadCardDetail(id: currentInspected)
        }
    }

    private func canPublishRefresh(_ ticket: RefreshTicket) -> Bool {
        ticket.request == latestRefreshRequest
            && ticket.localRevision == localCardsRevision
            && !isCapturingSelection
            && activeExternalCaptureCount == 0
    }

    @discardableResult
    public func openConversationDraft(in requestedHost: ConversationHost? = nil) -> Bool {
        guard !isLaunchingConversation, !isMutatingCards, !hasActiveHandoffConversation else {
            return false
        }
        pendingDeleteConfirmation = nil
        closeCardPreview()
        let selected = resolvableCardsForHandoff().filter { checkedCardIDs.contains($0.id) }
        guard !selected.isEmpty else {
            setBanner(.selectAtLeastOneCard, isError: true)
            return false
        }
        let effectiveAIAccessMode = paths.resolveAIAccessMode(environment: environment)
        aiAccessMode = effectiveAIAccessMode
        let selectedIDs = selected.map(\.id)
        if var existing = conversationDraft, existing.cardIDs == selectedIDs, existing.isEdited {
            if let requestedHost {
                existing.targetHost = requestedHost
            }
            conversationDraft = existing
            stashedEditedDraft = existing
            bannerMessage = nil
            isErrorBanner = false
            return true
        }
        if var stashed = stashedEditedDraft, stashed.cardIDs == selectedIDs, stashed.isEdited {
            if let requestedHost {
                stashed.targetHost = requestedHost
            }
            conversationDraft = stashed
            stashedEditedDraft = stashed
            bannerMessage = nil
            isErrorBanner = false
            return true
        }
        stashedEditedDraft = nil
        let prompt = ConversationPrompt.buildPrompt(
            for: selected,
            language: language,
            aiAccessMode: effectiveAIAccessMode
        )
        conversationDraft = ConversationDraft(
            cardIDs: selectedIDs,
            text: prompt,
            isEdited: false,
            targetHost: requestedHost
        )
        bannerMessage = nil
        isErrorBanner = false
        return true
    }

    public func updateConversationDraftText(_ text: String) {
        guard var draft = conversationDraft, draft.text != text else { return }
        draft.text = text
        draft.isEdited = true
        conversationDraft = draft
        stashedEditedDraft = draft
    }

    public func selectConversationDraftHost(_ host: ConversationHost) {
        conversationHost = host
        if var draft = conversationDraft {
            draft.targetHost = host
            conversationDraft = draft
            if draft.isEdited {
                stashedEditedDraft = draft
            }
        }
    }

    public func resetConversationDraft() {
        guard let draft = conversationDraft else { return }
        stashedEditedDraft = nil
        let allCards = resolvableCardsForHandoff()
        let checked = allCards.filter { checkedCardIDs.contains($0.id) }
        let targetCards: [RewindCard]
        if !checked.isEmpty {
            targetCards = checked
        } else {
            let idSet = Set(draft.cardIDs)
            targetCards = allCards.filter { idSet.contains($0.id) }
        }
        guard !targetCards.isEmpty else {
            conversationDraft = nil
            setBanner(.selectAtLeastOneCard, isError: true)
            return
        }
        let effectiveAIAccessMode = paths.resolveAIAccessMode(environment: environment)
        aiAccessMode = effectiveAIAccessMode
        let prompt = ConversationPrompt.buildPrompt(
            for: targetCards,
            language: language,
            aiAccessMode: effectiveAIAccessMode
        )
        conversationDraft = ConversationDraft(
            cardIDs: targetCards.map(\.id),
            text: prompt,
            isEdited: false,
            targetHost: draft.targetHost
        )
    }

    public func dismissConversationDraft() {
        if let draft = conversationDraft, draft.isEdited {
            stashedEditedDraft = draft
        }
        if conversationDraft != nil {
            conversationDraft = nil
        }
    }

    @discardableResult
    public func copyConversationDraftAndWakeHost(in requestedHost: ConversationHost? = nil) -> Bool {
        guard !isLaunchingConversation, let draft = conversationDraft else { return false }
        let cleaned = draft.text.replacingOccurrences(of: "\0", with: "")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setBanner(.emptyConversationDraft, isError: true)
            return false
        }
        let host = activeConversationHost ?? requestedHost ?? draft.targetHost ?? conversationHost
        onCopyText(cleaned)
        conversationDraft = nil
        stashedEditedDraft = nil
        let wokeHost: Bool
        if let onActivateHostApp {
            wokeHost = onActivateHostApp(host)
        } else if let onWakeHost {
            onWakeHost(host)
            wokeHost = true
        } else {
            wokeHost = false
        }
        setBanner(
            wokeHost ? .copiedDraftAndWokeHost(host) : .copiedDraftHostUnavailable(host),
            isError: !wokeHost
        )
        return wokeHost
    }

    @discardableResult
    public func sendConversationDraft(
        in requestedHost: ConversationHost? = nil,
        waitSeconds: TimeInterval = 40
    ) async -> ConversationLaunchResult? {
        guard let draft = conversationDraft else { return nil }
        return await launchChecked(
            in: requestedHost ?? draft.targetHost,
            customPrompt: draft.text,
            waitSeconds: waitSeconds
        )
    }

    @discardableResult
    public func launchChecked(
        in requestedHost: ConversationHost? = nil,
        customPrompt: String? = nil,
        waitSeconds: TimeInterval = 40
    ) async -> ConversationLaunchResult? {
        guard !isLaunchingConversation, !isMutatingCards else { return nil }
        pendingDeleteConfirmation = nil
        isLaunchingConversation = true
        canEndUnconfirmedConversation = false
        canEndUnarchivedConversation = false
        defer { isLaunchingConversation = false }
        do {
            let current: CurrentConversation
            let host: ConversationHost
            let channel: ConversationHostChannel
            if let (existingHost, _, existing, _) = try activeConversation() {
                host = existingHost
                channel = hostChannel(for: existingHost)
                current = existing
            } else {
                host = requestedHost ?? conversationDraft?.targetHost ?? conversationHost
                channel = hostChannel(for: host)
                let allCards = resolvableCardsForHandoff()
                let promptToSend: String
                let targetCardIDs: [String]
                if let customPrompt {
                    let sanitized = customPrompt.replacingOccurrences(of: "\0", with: "")
                    guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setBanner(.emptyConversationDraft, isError: true)
                        return nil
                    }
                    let liveIDSet = Set(allCards.map(\.id))
                    if let draft = conversationDraft {
                        targetCardIDs = draft.cardIDs.filter { liveIDSet.contains($0) }
                        guard !targetCardIDs.isEmpty || draft.isEdited else {
                            conversationDraft = nil
                            setBanner(.selectAtLeastOneCard, isError: true)
                            return nil
                        }
                    } else {
                        targetCardIDs = allCards.filter { checkedCardIDs.contains($0.id) }.map(\.id)
                        guard !targetCardIDs.isEmpty else {
                            setBanner(.selectAtLeastOneCard, isError: true)
                            return nil
                        }
                    }
                    promptToSend = sanitized
                } else {
                    let selected = allCards.filter { checkedCardIDs.contains($0.id) }
                    guard !selected.isEmpty else {
                        setBanner(.selectAtLeastOneCard, isError: true)
                        return nil
                    }
                    let effectiveAIAccessMode = paths.resolveAIAccessMode(environment: environment)
                    aiAccessMode = effectiveAIAccessMode
                    promptToSend = ConversationPrompt.buildPrompt(
                        for: selected,
                        language: language,
                        aiAccessMode: effectiveAIAccessMode
                    )
                    targetCardIDs = selected.map(\.id)
                }
                if let failureBanner = channel.readinessFailure() {
                    setBanner(failureBanner, isError: true)
                    return nil
                }
                current = try channel.store.submit(
                    prompt: promptToSend,
                    cardIDs: targetCardIDs,
                    markSynthesized: markSynthesizedOnLaunch && !targetCardIDs.isEmpty
                )
                conversationDraft = nil
                stashedEditedDraft = nil
            }
            let store = channel.store
            activeConversationHost = host
            lockedConversationCardIDs = Set(current.cardIDs)
            setBanner(.waitingForHostConfirmation(host), isError: false)
            onWakeHost?(host)
            try await channel.dispatch(store)
            let deadline = Date().addingTimeInterval(max(0, waitSeconds))
            repeat {
                if let receipt = try store.receipt(for: current.requestId), receipt.state != .dispatching {
                    switch receipt.state {
                    case .succeeded:
                        guard let conversationID = receipt.conversationId else {
                            throw RewindError.ioError(L10n.missingReceiptConversationIDDetail(in: language))
                        }
                        let reference = ConversationReference(host: host, id: conversationID)
                        confirmedConversation = reference
                        let opened = !channel.requiresExplicitConversationOpen || onOpenConversation?(reference) == true
                        if current.markSynthesized && !current.archiveCardIDs.isEmpty {
                            canEndUnarchivedConversation = true
                            let remainingIDs = Set(current.archiveCardIDs)
                            let selected = resolvableCardsForHandoff().filter { remainingIDs.contains($0.id) }
                            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                                lockedConversationCardIDs = remainingIDs
                                setBanner(.sentArchiveBlockedUnconfigured, isError: true)
                                return .succeeded(reference)
                            }
                            var failed = selected.count != remainingIDs.count
                            for card in selected {
                                if card.isOfflinePending { failed = true; continue }
                                do {
                                    try await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
                                    archivedClipIDs.insert(card.id)
                                    try store.recordArchivedCard(card.id, requestId: current.requestId)
                                    checkedCardIDs.remove(card.id)
                                    updateLocalCards { $0.removeAll { $0.id == card.id } }
                                    markSnippetRecordsArchived(ids: [card.id])
                                } catch { failed = true }
                            }
                            try hotCache.saveCards(cards)
                            if failed {
                                lockedConversationCardIDs = Set((try? store.current()?.archiveCardIDs) ?? current.archiveCardIDs)
                                setBanner(.sentPartialArchiveFailure, isError: true)
                                return .succeeded(reference)
                            }
                        }
                        canEndUnarchivedConversation = false
                        checkedCardIDs.subtract(current.cardIDs)
                        if opened {
                            try store.clearCurrent(requestId: current.requestId)
                            activeConversationHost = nil
                            lockedConversationCardIDs = []
                        }
                        setBanner(
                            opened
                                ? .sentToNewConversation(count: max(1, current.cardIDs.count), host: host)
                                : .sentOpenConversationFailed(host),
                            isError: !opened
                        )
                        return .succeeded(reference)
                    case .rejected, .expired:
                        try store.clearCurrent(requestId: current.requestId)
                        activeConversationHost = nil
                        lockedConversationCardIDs = []
                        setBanner(
                            receipt.state == .expired ? .requestExpired(host) : .hostRejected(host),
                            isError: true
                        )
                        return .failed(state: receipt.state)
                    case .unknown:
                        canEndUnconfirmedConversation = true
                        setBanner(.deliveryUnconfirmed(host), isError: true)
                        return .failed(state: .unknown)
                    case .dispatching: break
                    }
                }
                if Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled
            setBanner(.stillWaitingForReceipt, isError: true)
            return .failed(state: .unknown)
        } catch {
            setErrorBanner(error)
            return nil
        }
    }

    public func endUnconfirmedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let (_, store, current, receipt) = try activeConversation(clearingTerminalFailures: true),
                  receipt?.state == .unknown else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try store.clearCurrent(requestId: current.requestId)
            activeConversationHost = nil
            lockedConversationCardIDs = []
            canEndUnconfirmedConversation = false
            setBanner(.clearedUnconfirmedRequest, isError: false)
        } catch { setErrorBanner(error) }
    }

    public func endUnarchivedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let (_, store, current, receipt) = try activeConversation(clearingTerminalFailures: true), current.markSynthesized,
                  receipt?.state == .succeeded else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try store.clearCurrent(requestId: current.requestId)
            activeConversationHost = nil
            lockedConversationCardIDs = []
            canEndUnarchivedConversation = false
            setBanner(.retainedUnarchivedCards, isError: false)
        } catch { setErrorBanner(error) }
    }

    public func reopenConfirmedConversation() {
        guard let reference = confirmedConversation else { return }
        guard onOpenConversation?(reference) == true else {
            setBanner(.reopenConversationFailed, isError: true)
            return
        }
        do {
            if let (host, store, current, receipt) = try activeConversation(clearingTerminalFailures: true), host == reference.host,
               (!current.markSynthesized || current.archiveCardIDs.isEmpty),
               receipt?.conversationId == reference.id {
                try store.clearCurrent(requestId: current.requestId)
                activeConversationHost = nil
                lockedConversationCardIDs = []
            }
            setBanner(.openedConversation(reference.host), isError: false)
        } catch { setErrorBanner(error) }
    }

    public func handoffStore(for host: ConversationHost) -> ConversationHandoffStore {
        hostChannel(for: host).store
    }

    private func hostChannel(for host: ConversationHost) -> ConversationHostChannel {
        guard let channel = hostChannels[host] else {
            preconditionFailure("Missing host channel for \(host)")
        }
        return channel
    }

    private func activeConversation(
        clearingTerminalFailures: Bool = false
    ) throws -> (ConversationHost, ConversationHandoffStore, CurrentConversation, ConversationReceipt?)? {
        var live: [(ConversationHost, ConversationHandoffStore, CurrentConversation, ConversationReceipt?)] = []
        var terminal: [(ConversationHost, ConversationHandoffStore, CurrentConversation, ConversationReceipt?)] = []
        for host in ConversationHost.allCases {
            let store = handoffStore(for: host)
            guard let current = try store.current() else { continue }
            let receipt = try store.receipt(for: current.requestId)
            if receipt?.state.isTerminalFailure == true {
                terminal.append((host, store, current, receipt))
            } else {
                live.append((host, store, current, receipt))
            }
        }
        if clearingTerminalFailures || !live.isEmpty {
            for (_, store, current, _) in terminal {
                try store.clearCurrent(requestId: current.requestId)
            }
            return live.min { $0.2.expiresAt < $1.2.expiresAt }
        }
        return terminal.min { $0.2.expiresAt < $1.2.expiresAt }
    }

    public func requestDeleteCards(ids: [String], bypassConfirmation: Bool = false) async {
        guard let targets = prepareCardMutationTargets(ids: ids) else { return }
        if !bypassConfirmation {
            pendingDeleteConfirmation = PendingDeleteConfirmation(
                cardIDs: targets.map(\.id),
                allOfflinePending: targets.allSatisfy(\.isOfflinePending)
            )
            return
        }

        pendingDeleteConfirmation = nil
        isMutatingCards = true
        defer { isMutatingCards = false }

        let baseURL = paths.resolveMemosBaseURL(environment: environment)
        let token = KeychainTokenStore.resolveToken(environment: environment)
        let isQAMode = environment[StoragePaths.qaEnvironmentKey] == "1"

        var deletedCount = 0
        var failedCount = 0
        var sawUnconfiguredSyncedFailure = false
        var lastError: (any Error)?

        for card in targets {
            let isPending = card.isOfflinePending || outbox.loadEntries().contains { $0.clientClipId == card.id }
            do {
                try Task.checkCancellation()
                if isPending {
                    if let baseURL, let token {
                        do {
                            _ = try await memosClient.deleteMemo(id: card.id, baseURL: baseURL, token: token)
                        } catch RewindError.networkFailure {
                            try Task.checkCancellation()
                        }
                    } else if isQAMode && baseURL != nil {
                        throw RewindError.missingCredentials
                    }
                } else {
                    guard let baseURL, let token else {
                        sawUnconfiguredSyncedFailure = true
                        failedCount += 1
                        continue
                    }
                    _ = try await memosClient.deleteMemo(id: card.id, baseURL: baseURL, token: token)
                }

                try outbox.removeEntry(clientClipId: card.id)
                _ = try? hotCache.removeCard(id: card.id)
                _ = try? LocalNotesStore(fileURL: paths.localNotesFileURL).removeNotes(for: card.id)
                deletedClipIDs.insert(card.id)
                removeCardsFromCoordinatorState([card.id])
                deletedCount += 1
            } catch {
                lastError = error
                failedCount += 1
            }
        }

        if failedCount == 0 {
            setBanner(.deletedClips(count: deletedCount), isError: false)
        } else if deletedCount > 0 {
            setBanner(.partialDeleteClipsFailure(succeeded: deletedCount, failed: failedCount), isError: true)
        } else if sawUnconfiguredSyncedFailure && lastError == nil {
            setBanner(.deleteCardBlockedOfflineOrUnconfigured, isError: true)
        } else if let lastError {
            setErrorBanner(lastError)
        } else {
            setBanner(.deleteCardBlockedOfflineOrUnconfigured, isError: true)
        }
    }

    public func requestDeleteTargetCards(bypassConfirmation: Bool = false) async {
        await requestDeleteCards(ids: targetActionCardIDs, bypassConfirmation: bypassConfirmation)
    }

    public func confirmPendingDelete() async {
        guard let pending = pendingDeleteConfirmation else { return }
        await requestDeleteCards(ids: pending.cardIDs, bypassConfirmation: true)
    }

    public func archiveCards(ids: [String]) async {
        guard let targets = prepareCardMutationTargets(ids: ids) else { return }
        pendingDeleteConfirmation = nil

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment) else {
            setBanner(.archiveCardBlockedOfflineOrUnconfigured, isError: true)
            return
        }

        isMutatingCards = true
        defer { isMutatingCards = false }

        var archivedCount = 0
        var failedCount = 0
        var lastError: (any Error)?

        for card in targets {
            do {
                let cardToArchive: RewindCard
                if let entry = outbox.loadEntries().first(where: { $0.clientClipId == card.id }) ?? inFlightCaptureEntries[card.id] {
                    cardToArchive = try await memosClient.createClip(
                        clientClipId: entry.clientClipId,
                        content: entry.memoContent,
                        contextComment: entry.commentContent,
                        baseURL: baseURL,
                        token: token,
                        fallbackCreatedAt: entry.createdAt
                    )
                } else if card.isOfflinePending {
                    cardToArchive = try await memosClient.createClip(
                        clientClipId: card.id,
                        content: card.rawContent,
                        contextComment: nil,
                        baseURL: baseURL,
                        token: token,
                        fallbackCreatedAt: card.createdAt
                    )
                } else {
                    cardToArchive = card
                }

                try await memosClient.markSynthesized(card: cardToArchive, baseURL: baseURL, token: token)
                archivedClipIDs.insert(card.id)
                archivedClipIDs.insert(cardToArchive.id)
                _ = try? outbox.removeEntry(clientClipId: card.id)
                _ = try? hotCache.removeCard(id: card.id)
                var removedIDs: Set<String> = [card.id]
                if cardToArchive.id != card.id {
                    _ = try? hotCache.removeCard(id: cardToArchive.id)
                    removeObsoleteLocalRecordID(card.id, replacedBy: cardToArchive.id)
                    removedIDs.insert(cardToArchive.id)
                }
                removeCardsFromCoordinatorState(removedIDs)
                archivedCount += 1
            } catch {
                lastError = error
                failedCount += 1
            }
        }

        if failedCount == 0 {
            setBanner(.archivedClips(count: archivedCount), isError: false)
        } else if archivedCount > 0 {
            setBanner(.partialArchiveClipsFailure(succeeded: archivedCount, failed: failedCount), isError: true)
        } else if let lastError {
            setErrorBanner(lastError)
        }
    }

    public func archiveTargetCards() async {
        await archiveCards(ids: targetActionCardIDs)
    }

    public func markCardSynthesized(_ card: RewindCard) async {
        await archiveCards(ids: [card.id])
    }

    func prepareCardMutationTargets(ids: [String]) -> [RewindCard]? {
        guard !isMutatingCards else { return nil }
        let requested = Set(ids)
        var seen: Set<String> = []
        let targets = resolvableCardsForHandoff().filter { requested.contains($0.id) && seen.insert($0.id).inserted }
        guard !targets.isEmpty else {
            pendingDeleteConfirmation = nil
            return nil
        }
        if targets.contains(where: { lockedConversationCardIDs.contains($0.id) }) {
            pendingDeleteConfirmation = nil
            setBanner(.cardsLockedByActiveConversation, isError: true)
            return nil
        }
        return targets
    }

    func removeCardsFromCoordinatorState(_ removedIDs: Set<String>) {
        let previousFilteredIDs = filteredCards.map(\.id)
        checkedCardIDs.subtract(removedIDs)
        for removedID in removedIDs {
            cachedCardDetails.removeValue(forKey: removedID)
            if cardDetailStates[removedID] != nil {
                cardDetailStates.removeValue(forKey: removedID)
            }
        }
        if let currentInspected = inspectedCardID, removedIDs.contains(currentInspected) {
            closeCardPreview()
        }
        let updateRecords: ([SnippetRecord]) -> [SnippetRecord] = { records in
            records.compactMap { record in
                if self.deletedClipIDs.contains(record.id) {
                    return nil
                }
                if self.archivedClipIDs.contains(record.id) && record.status != .synthesized {
                    return SnippetRecord(
                        id: record.id,
                        status: .synthesized,
                        sourcePlatform: record.sourcePlatform,
                        title: record.title,
                        sessionTopic: record.sessionTopic,
                        contextSummary: record.contextSummary,
                        keywords: record.keywords,
                        sourceTitle: record.sourceTitle,
                        sourceURL: record.sourceURL,
                        verbatimText: record.verbatimText,
                        createdAt: record.createdAt,
                        dataOrigin: record.dataOrigin,
                        conversationContext: record.conversationContext,
                        tags: record.tags,
                        notes: record.notes
                    )
                }
                if removedIDs.contains(record.id) && !self.archivedClipIDs.contains(record.id) {
                    return nil
                }
                return record
            }
        }
        libraryRecords = libraryRecords.map(updateRecords)
        placeRecords = updateRecords(placeRecords)
        updateLocalCards { $0.removeAll { removedIDs.contains($0.id) } }
        focusedCardID = nextFocusedCardID(afterRemoving: removedIDs, previousFilteredIDs: previousFilteredIDs)
        if let currentLibraryFocused = libraryFocusedClipID, removedIDs.contains(currentLibraryFocused) {
            let visibleIDs = libraryProjection.visibleItems.map(\.id)
            libraryFocusedClipID = visibleIDs.first(where: { !removedIDs.contains($0) }) ?? visibleIDs.first
        }
        reconcilePendingDeleteConfirmation()
        reconcileConversationDraftState()
    }

    private func nextFocusedCardID(
        afterRemoving removedIDs: Set<String>,
        previousFilteredIDs: [String]
    ) -> String? {
        guard let currentFocused = focusedCardID else { return nil }
        guard removedIDs.contains(currentFocused) else {
            return cards.contains(where: { $0.id == currentFocused }) ? currentFocused : filteredCards.first?.id
        }
        let currentFilteredSet = Set(filteredCards.map(\.id))
        if let oldIndex = previousFilteredIDs.firstIndex(of: currentFocused) {
            if let after = previousFilteredIDs[(oldIndex + 1)...].first(where: { !removedIDs.contains($0) && currentFilteredSet.contains($0) }) {
                return after
            }
            if let before = previousFilteredIDs[..<oldIndex].last(where: { !removedIDs.contains($0) && currentFilteredSet.contains($0) }) {
                return before
            }
        }
        return filteredCards.first?.id
    }

    public var connectionSettings: ConnectionSettingsState {
        ConnectionSettingsState(paths: paths, environment: environment)
    }

    public func saveCredentials(memosURL: String, token: String) throws {
        let settings = connectionSettings
        if !settings.isURLManaged {
            try paths.saveMemosURLString(memosURL)
        }
        if !settings.isTokenManaged && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try KeychainTokenStore.saveToken(token, environment: environment)
            environment.removeValue(forKey: KeychainTokenStore.disableKeychainFallbackEnvironmentKey)
        }
        setBanner(.savedConnectionSettings, isError: false)
    }

    /// Saves the settings first, then probes the server only when both a URL and an access token exist.
    public func saveAndVerifyConnection(memosURL: String, token: String) async throws -> ConnectionCheckOutcome {
        try saveCredentials(memosURL: memosURL, token: token)
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            return .localOnly
        }
        guard let accessToken = KeychainTokenStore.resolveToken(environment: environment) else {
            return .missingToken
        }
        do {
            try await memosClient.verifyConnection(baseURL: baseURL, token: accessToken)
        } catch {
            return .failed((error as? RewindError) ?? .networkFailure(error.localizedDescription))
        }
        await refresh()
        return .verified
    }

    @discardableResult
    public func openURL(_ url: URL) -> Bool {
        guard onOpenURL?(url) == true else {
            setBanner(.openURLFailed(url.absoluteString), isError: true)
            return false
        }
        return true
    }

    @discardableResult
    public func openSource(for card: RewindCard) async -> Bool {
        await openSource(locator: card.sourceLocator)
    }

    @discardableResult
    public func openSource(locator: SourceLocator?) async -> Bool {
        guard let locator else { return false }
        switch locator {
        case .web(let url, _):
            return openURL(url)
        case .antigravitySession(let sessionID):
            copySessionID(sessionID)
            return true
        case .dshSession(let sessionID):
            let opened = await dshActionRunner(sessionID)
            if opened {
                if onActivateHostApp?(.dsh) != true {
                    onWakeHost?(.dsh)
                }
                setBanner(.openedDSHConversation, isError: false)
                return true
            }
            onCopyText(sessionID)
            setBanner(.copiedDSHSessionFallback(sessionID), isError: false)
            return false
        }
    }

    public func performSourceAction(for card: RewindCard) {
        guard let locator = card.sourceLocator else { return }
        switch locator {
        case .web(let url, _):
            openURL(url)
        case .antigravitySession(let sessionID):
            copySessionID(sessionID)
        case .dshSession:
            Task { @MainActor [weak self] in
                _ = await self?.openSource(for: card)
            }
        }
    }

    public func copySessionID(_ sessionID: String) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCopyText(trimmed)
        setBanner(.copiedSessionID(trimmed), isError: false)
    }

    public func copyClipText(_ text: String) {
        onCopyText(text)
        setBanner(.copiedClipText, isError: false)
    }

    public func wakeAntigravity() {
        onWakeHost?(.antigravity)
    }

    public func wakeDSH() {
        onWakeHost?(.dsh)
    }

    public var inspectedCard: RewindCard? {
        guard let inspectedCardID else { return nil }
        return filteredCards.first(where: { $0.id == inspectedCardID })
    }

    public func cardDetailState(for id: String) -> CardDetailLoadState {
        cardDetailStates[id] ?? .idle
    }

    public func toggleCardPreview(id: String) {
        if inspectedCardID == id {
            closeCardPreview()
            return
        }
        guard filteredCards.contains(where: { $0.id == id }) else { return }
        dismissConversationDraft()
        focusedCardID = id
        inspectedCardID = id
        if let cached = cachedCardDetails[id], cached.isCompleteFromServer {
            cancelActiveDetailTask()
            cardDetailStates[id] = .loaded(cached)
            return
        }
        reloadCardDetail(id: id)
    }

    public func toggleFocusedCardPreview() {
        if inspectedCardID != nil {
            closeCardPreview()
            return
        }
        let targetID: String?
        if let focused = focusedCardID, filteredCards.contains(where: { $0.id == focused }) {
            targetID = focused
        } else {
            targetID = filteredCards.first?.id
        }
        guard let targetID else { return }
        toggleCardPreview(id: targetID)
    }

    public func reloadCardDetail(id: String) {
        let matchedRecord = (libraryRecords ?? []).first(where: { $0.id == id })
            ?? placeRecords.first(where: { $0.id == id })
        guard let card = cards.first(where: { $0.id == id })
            ?? matchedRecord.map(LibraryProjector.synthesizeRewindCard(from:)) else { return }
        cancelActiveDetailTask()

        let outboxEntry = inFlightCaptureEntries[id]
            ?? outbox.loadEntries().first(where: { $0.clientClipId == id })
        let localContext = outboxEntry?.commentContent.flatMap(MemosWireFormat.parseContextComment)
            ?? matchedRecord?.conversationContext
        let localNotes = LocalNotesStore(fileURL: paths.localNotesFileURL).loadNotes(for: id)
        let existingCached = cachedCardDetails[id]
        let mergedContext = localContext ?? existingCached?.context
        let mergedNotes = LocalNotesStore.sortAndDeduplicate(
            (existingCached?.notes ?? []) + localNotes + (matchedRecord?.notes ?? [])
        )

        let baseURL = paths.resolveMemosBaseURL(environment: environment)
        let token = KeychainTokenStore.resolveToken(environment: environment)

        if card.isOfflinePending || outboxEntry != nil || baseURL == nil || token == nil {
            let localDetail = CardDetail(
                context: mergedContext,
                notes: mergedNotes,
                isCompleteFromServer: false
            )
            cachedCardDetails[id] = localDetail
            cardDetailStates[id] = .loaded(localDetail)
            return
        }

        guard let baseURL, let token else { return }
        let partial: CardDetail?
        if existingCached != nil || mergedContext != nil || !mergedNotes.isEmpty {
            partial = CardDetail(
                context: mergedContext,
                notes: mergedNotes,
                isCompleteFromServer: false
            )
        } else {
            partial = nil
        }
        cardDetailStates[id] = .loading(partial: partial)

        activeDetailTaskGeneration &+= 1
        let generation = activeDetailTaskGeneration
        let client = memosClient
        let recordNotes = matchedRecord?.notes ?? []
        activeDetailTask = Task { @MainActor [weak self] in
            do {
                let comments = try await client.listMemoComments(id: id, baseURL: baseURL, token: token)
                guard let self,
                      !Task.isCancelled,
                      self.activeDetailTaskGeneration == generation,
                      (self.inspectedCardID == id || self.libraryFocusedClipID == id || self.libraryProjection.inspectedItem?.id == id) else {
                    return
                }
                let latestLocalNotes = LocalNotesStore(fileURL: self.paths.localNotesFileURL).loadNotes(for: id)
                let parsed = MemosWireFormat.parseMemoComments(comments, localNotes: latestLocalNotes)
                let detail = CardDetail(
                    context: parsed.context ?? localContext,
                    notes: LocalNotesStore.sortAndDeduplicate(parsed.notes + recordNotes),
                    isCompleteFromServer: true
                )
                self.cachedCardDetails[id] = detail
                self.cardDetailStates[id] = .loaded(detail)
                self.activeDetailTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.activeDetailTaskGeneration == generation,
                      (self.inspectedCardID == id || self.libraryFocusedClipID == id || self.libraryProjection.inspectedItem?.id == id) else {
                    return
                }
                let message: String
                if let rewindError = error as? RewindError {
                    message = rewindError.localizedDescription(in: self.language)
                } else {
                    message = error.localizedDescription
                }
                self.cardDetailStates[id] = .failed(partial: partial, message: message)
                self.activeDetailTask = nil
            }
        }
    }

    public func closeCardPreview() {
        cancelActiveDetailTask()
        if inspectedCardID != nil {
            inspectedCardID = nil
        }
    }

    public func dismissTransientHUDState() {
        cancelActiveDetailTask()
        if pendingDeleteConfirmation != nil {
            pendingDeleteConfirmation = nil
        }
        dismissConversationDraft()
        if inspectedCardID != nil {
            inspectedCardID = nil
        }
        placePicker = nil
    }

    private func remapAndDeduplicateCardIDs(_ rawIDs: [String], idRemapping: [String: String]) -> [String] {
        var seen: Set<String> = []
        var remapped: [String] = []
        for rawID in rawIDs {
            let resolved = idRemapping[rawID] ?? rawID
            if seen.insert(resolved).inserted {
                remapped.append(resolved)
            }
        }
        return remapped
    }

    func reconcileConversationDraftState(idRemapping: [String: String] = [:]) {
        let allCards = resolvableCardsForHandoff()
        let liveIDSet = Set(allCards.map(\.id))
        if var stashed = stashedEditedDraft {
            let mapped = remapAndDeduplicateCardIDs(stashed.cardIDs, idRemapping: idRemapping)
                .filter { liveIDSet.contains($0) }
            if mapped.isEmpty {
                stashedEditedDraft = nil
            } else {
                stashed.cardIDs = mapped
                stashedEditedDraft = stashed
            }
        }
        guard var draft = conversationDraft else { return }
        let mappedIDs = remapAndDeduplicateCardIDs(draft.cardIDs, idRemapping: idRemapping)
        let liveIDs = mappedIDs.filter { liveIDSet.contains($0) }
        if draft.isEdited {
            draft.cardIDs = liveIDs
            conversationDraft = draft
            if !liveIDs.isEmpty {
                stashedEditedDraft = draft
            } else {
                stashedEditedDraft = nil
            }
            return
        }
        let targetIDSet = Set(liveIDs)
        let targetCards = allCards.filter { targetIDSet.contains($0.id) }
        guard !targetCards.isEmpty else {
            conversationDraft = nil
            return
        }
        let effectiveAIAccessMode = paths.resolveAIAccessMode(environment: environment)
        aiAccessMode = effectiveAIAccessMode
        let prompt = ConversationPrompt.buildPrompt(
            for: targetCards,
            language: language,
            aiAccessMode: effectiveAIAccessMode
        )
        conversationDraft = ConversationDraft(
            cardIDs: targetCards.map(\.id),
            text: prompt,
            isEdited: false,
            targetHost: draft.targetHost
        )
    }

    private func refreshUneditedConversationDraftIfNeeded() {
        guard let draft = conversationDraft, !draft.isEdited else { return }
        reconcileConversationDraftState()
    }

    private func cancelActiveDetailTask() {
        activeDetailTaskGeneration &+= 1
        activeDetailTask?.cancel()
        activeDetailTask = nil
        for (id, state) in cardDetailStates {
            if case .loading(let partial) = state {
                cardDetailStates[id] = partial.map { .loaded($0) } ?? .idle
            }
        }
    }

    func remapCardDetailState(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        if let cached = cachedCardDetails.removeValue(forKey: oldID) {
            cachedCardDetails[newID] = cached
        }
        if let existingState = cardDetailStates.removeValue(forKey: oldID) {
            cardDetailStates[newID] = existingState
        }
        if inspectedCardID == oldID {
            inspectedCardID = newID
        }
        if libraryFocusedClipID == oldID {
            libraryFocusedClipID = newID
        }
    }

    private func reconcileInspectedCardVisibility() {
        guard let currentInspected = inspectedCardID else { return }
        if !filteredCards.contains(where: { $0.id == currentInspected }) {
            closeCardPreview()
        }
    }

    private func pruneRemovedCardDetails() {
        var validIDs = Set(cards.map(\.id))
        validIDs.formUnion((libraryRecords ?? []).map(\.id))
        validIDs.formUnion(placeRecords.map(\.id))
        for key in Array(cachedCardDetails.keys) where !validIDs.contains(key) {
            cachedCardDetails.removeValue(forKey: key)
        }
        for key in Array(cardDetailStates.keys) where !validIDs.contains(key) {
            cardDetailStates.removeValue(forKey: key)
        }
    }

    private func invalidateAndReconcileCardDetailsAfterRefresh() {
        reconcileInspectedCardVisibility()
        pruneRemovedCardDetails()
        let preservedIDs = Set([inspectedCardID, libraryFocusedClipID].compactMap { $0 })
        guard !preservedIDs.isEmpty else {
            cachedCardDetails.removeAll()
            cardDetailStates.removeAll()
            return
        }
        for key in Array(cachedCardDetails.keys) where !preservedIDs.contains(key) {
            cachedCardDetails.removeValue(forKey: key)
        }
        for key in Array(cardDetailStates.keys) where !preservedIDs.contains(key) {
            cardDetailStates.removeValue(forKey: key)
        }
        if let currentInspected = inspectedCardID {
            reloadCardDetail(id: currentInspected)
        } else if let focused = libraryFocusedClipID {
            reloadCardDetail(id: focused)
        }
    }

    public var isAIAccessManagedByEnvironment: Bool {
        paths.isAIAccessManagedByEnvironment(environment: environment)
    }

    public var isMCPBinaryInstalled: Bool {
        _ = mcpBinaryStateRevision
        return FileManager.default.isExecutableFile(
            atPath: AntigravityIntegration.stableCLIBinaryURL(in: paths.dataDirectoryURL).path
        )
    }

    public var mcpServiceStatusText: String {
        L10n.mcpServiceStatusSummary(
            isInstalled: isMCPBinaryInstalled,
            mode: aiAccessMode,
            in: language
        )
    }

    public func setAIAccessMode(_ mode: AIAccessMode) {
        guard !isAIAccessManagedByEnvironment else {
            aiAccessMode = paths.resolveAIAccessMode(environment: environment)
            setBanner(.aiAccessManagedByEnvironment, isError: false)
            return
        }
        do {
            try paths.saveAIAccessMode(mode)
            aiAccessMode = mode
            refreshUneditedConversationDraftIfNeeded()
            setBanner(.savedAIAccessMode(mode), isError: false)
        } catch {
            setErrorBanner(error)
        }
    }

    public func mcpClientConfigurationJSON() -> String {
        StoragePaths.standardMCPConfigurationJSON(
            executablePath: AntigravityIntegration.stableCLIBinaryURL(in: paths.dataDirectoryURL).path
        )
    }

    public func refreshAllSettingsState() {
        aiAccessMode = paths.resolveAIAccessMode(environment: environment)
        refreshPluginStatus()
        refreshDSHPluginStatus()
    }

    public func refreshDSHPluginStatus() {
        lastDSHPluginInstallFailureNotice = nil
        let reasons = DSHIntegration.repairReasons(
            dataDirectoryURL: paths.dataDirectoryURL,
            dshHomeURL: paths.dshHomeDirectoryURL,
            dshBinaryURL: dshBinaryURLProvider()
        )
        if reasons.isEmpty {
            dshPluginStatusText = L10n.dshPluginInstalledSummary(in: language)
        } else {
            dshPluginStatusText = L10n.dshPluginNeedsRepairSummary(firstReason: reasons.first, in: language)
        }
    }

    public func recordDSHPluginInstallResult(success: Bool, detail: String? = nil) {
        if success {
            lastDSHPluginInstallFailureNotice = nil
            let reasons = DSHIntegration.repairReasons(
                dataDirectoryURL: paths.dataDirectoryURL,
                dshHomeURL: paths.dshHomeDirectoryURL,
                dshBinaryURL: dshBinaryURLProvider()
            )
            if reasons.isEmpty {
                dshPluginStatusText = L10n.dshPluginInstallRestartHint(in: language)
                setBanner(.dshPluginInstalled, isError: false)
            } else {
                dshPluginStatusText = L10n.dshPluginNeedsRepairSummary(firstReason: reasons.first, in: language)
                setBanner(.dshPluginNeedsRepair(reasons.first), isError: false)
            }
        } else {
            let notice: BannerNotice = .dshPluginInstallFailedMessage(detail ?? "")
            lastDSHPluginInstallFailureNotice = notice
            dshPluginStatusText = L10n.banner(notice, in: language)
            setBanner(notice, isError: true)
        }
    }

    public func recordDSHPluginInstallFailure(_ error: any Error) {
        let notice: BannerNotice
        if let rewindError = error as? RewindError {
            notice = .dshPluginInstallFailedRewind(rewindError)
        } else {
            notice = .dshPluginInstallFailedMessage(error.localizedDescription)
        }
        lastDSHPluginInstallFailureNotice = notice
        dshPluginStatusText = L10n.banner(notice, in: language)
        setBanner(notice, isError: true)
    }

    public func installOrRepairPlugin(sourceCLIBinaryURL: URL? = nil, sourceSidecarURL: URL? = nil) {
        defer { mcpBinaryStateRevision &+= 1 }
        do {
            try AntigravityIntegration.installOrRepair(
                dataDirectoryURL: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                sourceCLIBinaryURL: sourceCLIBinaryURL,
                sourceSidecarBinaryURL: sourceSidecarURL,
                language: language
            )
            lastPluginInstallFailureNotice = nil
            let reasons = AntigravityIntegration.repairReasons(
                dataDirectoryURL: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL
            )
            if reasons.isEmpty {
                pluginStatusText = L10n.pluginInstalledSummary(in: language)
                setBanner(.pluginInstalled, isError: false)
            } else {
                pluginStatusText = L10n.pluginNeedsRepairSummary(firstReason: reasons.first, in: language)
                setBanner(.pluginNeedsRepair(reasons.first), isError: false)
            }
        } catch {
            let notice: BannerNotice
            if let rewindError = error as? RewindError {
                notice = .pluginInstallFailedRewind(rewindError)
            } else {
                notice = .pluginInstallFailedMessage(error.localizedDescription)
            }
            lastPluginInstallFailureNotice = notice
            pluginStatusText = L10n.banner(notice, in: language)
            setBanner(notice, isError: true)
        }
    }

    public func refreshPluginStatus() {
        mcpBinaryStateRevision &+= 1
        aiAccessMode = paths.resolveAIAccessMode(environment: environment)
        lastPluginInstallFailureNotice = nil
        let reasons = AntigravityIntegration.repairReasons(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        )
        if reasons.isEmpty {
            pluginStatusText = L10n.pluginInstalledSummary(in: language)
        } else {
            pluginStatusText = L10n.pluginNeedsRepairSummary(firstReason: reasons.first, in: language)
        }
    }

    private func buildProvenance(
        from selection: CapturedSelection
    ) async -> (platform: String, title: String, url: String?, context: CaptureContext?) {
        if let native = selection.nativeChat {
            let context = native.snapshot.flatMap {
                NativeConversationContext.resolve(
                    selectedText: native.renderedSelection ?? selection.text,
                    snapshot: $0,
                    sessionTitle: native.title,
                    backlink: native.backlink
                )
            }
            return (native.host.rawValue, native.title, native.backlink?.absoluteString, context)
        }
        if selection.bundleIdentifier == CapturedSelection.antigravityBundleIdentifier {
            let windowTitle = selection.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Antigravity"
            guard let conversationID = selection.antigravityConversationID else {
                return ("antigravity", title, nil, nil)
            }
            let context = await antigravityContext.resolve(
                conversationID: conversationID,
                selectedText: selection.text,
                sessionTitle: title
            )
            return ("antigravity", title, conversationID.backlink, context)
        }
        if selection.bundleIdentifier == CapturedSelection.dshBundleIdentifier {
            let resolution = DSHCaptureContext.resolve(
                selectedText: selection.text,
                fallbackTitle: selection.windowTitle,
                dataDirectoryURL: paths.dataDirectoryURL,
                now: selection.capturedAt
            )
            let sourceURL = resolution.sessionID.map { "dsh-session://\($0)" }
            return ("dsh", resolution.sourceTitle, sourceURL, resolution.context)
        }
        let browserPrefixes = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.brave.Browser"
        ]
        if browserPrefixes.contains(where: { selection.bundleIdentifier.hasPrefix($0) }) {
            let platform = MemosWireFormat.inferWebPlatform(urlString: selection.documentURL, title: selection.windowTitle)
            let cleanTitle = Self.stripBrowserSuffix(selection.windowTitle) ?? selection.appName
            return (platform, cleanTitle, selection.documentURL, nil)
        }
        let title = selection.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("macos", (title?.isEmpty == false) ? (title ?? selection.appName) : selection.appName, nil, nil)
    }

    private static func stripBrowserSuffix(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        for suffix in [" - ChatGPT", " - Claude", " - Google Chrome", " - Brave", " — Mozilla Firefox"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return title.isEmpty ? nil : title
    }

    func updateLocalCards(_ change: (inout [RewindCard]) -> Void) {
        localCardsRevision += 1
        change(&cards)
        try? hotCache.saveCards(cards)
    }

    static func mergeCards(cached: [RewindCard], pendingOutbox: [OutboxEntry]) -> [RewindCard] {
        var byID: [String: RewindCard] = [:]
        for card in cached {
            byID[card.id] = card
        }
        for entry in pendingOutbox where byID[entry.clientClipId] == nil {
            if let parsed = MemosWireFormat.parseMemo(
                id: entry.clientClipId,
                rawContent: entry.memoContent,
                createdAt: entry.createdAt,
                now: max(Date(), entry.createdAt),
                isOfflinePending: true
            ) {
                byID[parsed.id] = parsed
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    func setBanner(_ notice: BannerNotice, isError: Bool) {
        activeBannerNotice = notice
        isUpdatingBannerFromNotice = true
        bannerMessage = L10n.banner(notice, in: language)
        isUpdatingBannerFromNotice = false
        isErrorBanner = isError
    }

    func setErrorBanner(_ error: any Error) {
        if let rewindError = error as? RewindError {
            setBanner(.rewindError(rewindError), isError: true)
        } else {
            setBanner(.custom(error.localizedDescription), isError: true)
        }
    }
}

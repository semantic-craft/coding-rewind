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
        L10n.menuHeaderSubtitle(connection: connection, isPluginReady: isPluginReady, in: language)
    }

    public var toggleHUDTitle: String {
        L10n.menuToggleHUDTitle(isHUDVisible: isHUDVisible, in: language)
    }

    public var launchTitle: String {
        L10n.menuLaunchTitle(checkedCardCount: checkedCardCount, in: language)
    }
}

public enum ConnectionCheckOutcome: Equatable, Sendable {
    case localOnly
    case missingToken
    case verified
    case failed(RewindError)
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
    public var environment: [String: String]
    public let memosClient: MemosClient
    public let outbox: OfflineOutbox
    public let hotCache: HotCache
    public private(set) var language: AppLanguage
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
    public var effectiveConversationHost: ConversationHost { activeConversationHost ?? conversationHost }
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
    private let antigravityContext: AntigravityCaptureContext
    public var capturer: any SelectionCapturing

    public private(set) var isCapturingSelection = false
    private var latestRefreshRequest = 0
    private var localCardsRevision = 0
    public var markSynthesizedOnLaunch = false
    private struct RefreshTicket {
        let request: Int
        let localRevision: Int
    }
    public private(set) var cards: [RewindCard] = []
    public var searchText: String = ""
    public var statusFilter: StatusFilter = .all
    public var checkedCardIDs: Set<String> = []
    public var focusedCardID: String?
    private var activeBannerNotice: BannerNotice?
    private var isUpdatingBannerFromNotice = false
    private var lastPluginInstallFailureNotice: BannerNotice?
    public var bannerMessage: String? {
        didSet {
            if !isUpdatingBannerFromNotice && bannerMessage == nil {
                activeBannerNotice = nil
            }
        }
    }
    public var isErrorBanner: Bool = false
    public var pluginStatusText: String = ""

    public var onOpenURL: (@MainActor (URL) -> Void)?
    public var onWakeHost: (@MainActor (ConversationHost) -> Void)?
    public var onOpenConversation: (@MainActor (ConversationReference) -> Bool)?

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memosClient: MemosClient = MemosClient(),
        capturer: any SelectionCapturing,
        antigravityContext: AntigravityCaptureContext = AntigravityCaptureContext(),
        language: AppLanguage = .zhHans,
        codexDelivery: (@Sendable (ConversationRequest) async -> (ConversationReceipt.State, String?))? = nil
    ) throws {
        self.paths = paths
        self.environment = environment
        self.memosClient = memosClient
        self.outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        self.hotCache = HotCache(fileURL: paths.hotCacheFileURL)
        self.language = language
        let antigravityStore = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .antigravity)
        let codexStore = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .codex)
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
            .codex: ConversationHostChannel(
                store: codexStore,
                requiresExplicitConversationOpen: ConversationHost.codex.requiresExplicitConversationOpen,
                readinessFailure: {
                    codexDelivery == nil ? .needsCodexInstalled : nil
                },
                dispatch: { store in
                    guard let codexDelivery else { return }
                    try await Task.detached {
                        guard let worker = try ConversationSidecarWorker.acquireIfUnlocked(store: store) else { return }
                        try await worker.processPending(invoke: codexDelivery)
                    }.value
                }
            )
        ]
        self.antigravityContext = antigravityContext
        self.capturer = capturer
        self.cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
        self.focusedCardID = self.cards.first?.id
        if FileManager.default.fileExists(atPath: conversationHostURL.path) {
            conversationHost = try JSONDecoder().decode(ConversationHost.self, from: Data(contentsOf: conversationHostURL))
        }
        _ = try ConversationSidecarWorker.acquireIfUnlocked(store: codexStore)
        if let (host, _, current, receipt) = try activeConversation(clearingTerminalFailures: true) {
            activeConversationHost = host
            checkedCardIDs = Set(current.cardIDs)
            if receipt?.state == .succeeded, let id = receipt?.conversationId {
                confirmedConversation = ConversationReference(host: host, id: id)
            }
            canEndUnconfirmedConversation = receipt?.state == .unknown
            canEndUnarchivedConversation = receipt?.state == .succeeded && current.markSynthesized && !current.archiveCardIDs.isEmpty
            setBanner(
                canEndUnarchivedConversation ? .resumeUnarchivedStartup : .resumePendingStartup,
                isError: false
            )
        }
        refreshPluginStatus()
    }

    public func setLanguage(_ language: AppLanguage) {
        self.language = language
        try? AntigravityPluginInstaller(paths: paths).refreshLocalizedMetadataIfInstalled(language: language)
        if let failureNotice = lastPluginInstallFailureNotice {
            pluginStatusText = L10n.banner(failureNotice, in: language)
        } else {
            refreshPluginStatus()
        }
        if let activeBannerNotice {
            isUpdatingBannerFromNotice = true
            bannerMessage = L10n.banner(activeBannerNotice, in: language)
            isUpdatingBannerFromNotice = false
        }
    }

    public func recordStartupWarning(_ message: String) {
        setBanner(.custom(message), isError: true)
    }

    public var filteredCards: [RewindCard] {
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
            return haystack.contains(query)
        }
    }

    public func toggleCheck(for cardID: String) {
        if checkedCardIDs.contains(cardID) {
            checkedCardIDs.remove(cardID)
        } else {
            checkedCardIDs.insert(cardID)
        }
    }

    public func toggleFocusedCardCheck() {
        let targetID = focusedCardID ?? filteredCards.first?.id
        if let targetID {
            toggleCheck(for: targetID)
        }
    }

    public func focusAndCheckCard(id: String) {
        guard cards.contains(where: { $0.id == id }) else { return }
        focusedCardID = id
        checkedCardIDs.insert(id)
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
        var provisionalCardID: String?
        let previousFocusedCardID = focusedCardID
        do {
            let selection = try await capturer.captureFrontmostSelection()
            let (platform, sourceTitle, sourceURL, context) = await buildProvenance(from: selection)
            let hasContext = (context?.isEmpty == false)
            let clientClipId = MemosWireFormat.makeClientClipID(now: selection.capturedAt)
            let rawContent = try MemosWireFormat.formatRawMemoContent(
                verbatimText: selection.text,
                sourcePlatform: platform,
                sourceTitle: sourceTitle,
                sourceURL: sourceURL,
                capturedAt: selection.capturedAt,
                hasContext: hasContext
            )
            let commentContent = hasContext ? context?.formattedCommentMarkdown() : nil
            let entry = OutboxEntry(
                clientClipId: clientClipId,
                memoContent: rawContent,
                commentContent: commentContent,
                createdAt: selection.capturedAt
            )

            if let localCard = MemosWireFormat.parseMemo(
                id: clientClipId,
                rawContent: rawContent,
                createdAt: selection.capturedAt,
                now: max(Date(), selection.capturedAt),
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
                    applyFlushedOutboxItems(flushed)
                }
                let saved = try await memosClient.createClip(
                    clientClipId: clientClipId,
                    content: rawContent,
                    contextComment: commentContent,
                    baseURL: baseURL,
                    token: token,
                    fallbackCreatedAt: selection.capturedAt
                )
                updateLocalCards { cards in
                    cards.removeAll { $0.id == clientClipId || $0.id == saved.id }
                    cards.insert(saved, at: 0)
                }
                checkedCardIDs.remove(clientClipId)
                checkedCardIDs.insert(saved.id)
                focusedCardID = saved.id
                setBanner(.savedClip(sourceTitle: sourceTitle), isError: false)
                return .saved(cardID: saved.id, sourceTitle: sourceTitle)
            } catch {
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
            }
            let rewindError = (error as? RewindError) ?? .ioError(error.localizedDescription)
            setBanner(.rewindError(rewindError), isError: true)
            return .failed(rewindError)
        }
    }

    public func refresh() async {
        latestRefreshRequest += 1
        var ticket = RefreshTicket(request: latestRefreshRequest, localRevision: localCardsRevision)
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment) else {
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: cards, pendingOutbox: outbox.loadEntries())
            return
        }
        do {
            let (flushed, _) = try await outbox.flush(using: memosClient, baseURL: baseURL, token: token)
            if !flushed.isEmpty {
                let revisionUnchangedBeforeFlush = (ticket.localRevision == localCardsRevision)
                applyFlushedOutboxItems(flushed)
                if revisionUnchangedBeforeFlush {
                    ticket = RefreshTicket(request: ticket.request, localRevision: localCardsRevision)
                }
            }
            let remoteCards = try await memosClient.listHotClips(baseURL: baseURL, token: token)
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: remoteCards, pendingOutbox: outbox.loadEntries())
            try? hotCache.saveCards(cards)
            if focusedCardID == nil {
                focusedCardID = cards.first?.id
            }
        } catch {
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: cards, pendingOutbox: outbox.loadEntries())
            setBanner(.syncFailedShowingLocal, isError: true)
        }
    }

    private func applyFlushedOutboxItems(_ flushed: [(clientClipId: String, card: RewindCard)]) {
        guard !flushed.isEmpty else { return }
        for item in flushed {
            if checkedCardIDs.remove(item.clientClipId) != nil {
                checkedCardIDs.insert(item.card.id)
            }
            if focusedCardID == item.clientClipId {
                focusedCardID = item.card.id
            }
        }
        let pendingEntries = outbox.loadEntries()
        updateLocalCards { cards in
            for item in flushed {
                cards.removeAll { $0.id == item.clientClipId || $0.id == item.card.id }
                cards.append(item.card)
            }
            cards = Self.mergeCards(cached: cards, pendingOutbox: pendingEntries)
        }
        if focusedCardID == nil {
            focusedCardID = cards.first?.id
        }
    }

    private func canPublishRefresh(_ ticket: RefreshTicket) -> Bool {
        ticket.request == latestRefreshRequest && ticket.localRevision == localCardsRevision && !isCapturingSelection
    }

    @discardableResult
    public func launchChecked(in requestedHost: ConversationHost? = nil, waitSeconds: TimeInterval = 40) async -> ConversationLaunchResult? {
        guard !isLaunchingConversation else { return nil }
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
                host = requestedHost ?? conversationHost
                channel = hostChannel(for: host)
                let selected = cards.filter { checkedCardIDs.contains($0.id) }
                guard !selected.isEmpty else {
                    setBanner(.selectAtLeastOneCard, isError: true)
                    return nil
                }
                if let failureBanner = channel.readinessFailure() {
                    setBanner(failureBanner, isError: true)
                    return nil
                }
                current = try channel.store.submit(
                    prompt: ConversationPrompt.buildPrompt(for: selected, language: language),
                    cardIDs: selected.map(\.id),
                    markSynthesized: markSynthesizedOnLaunch
                )
            }
            let store = channel.store
            activeConversationHost = host
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
                            let selected = cards.filter { remainingIDs.contains($0.id) }
                            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                                setBanner(.sentArchiveBlockedUnconfigured, isError: true)
                                return .succeeded(reference)
                            }
                            var failed = selected.count != remainingIDs.count
                            for card in selected {
                                if card.isOfflinePending { failed = true; continue }
                                do {
                                    try await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
                                    try store.recordArchivedCard(card.id, requestId: current.requestId)
                                    checkedCardIDs.remove(card.id)
                                    updateLocalCards { $0.removeAll { $0.id == card.id } }
                                } catch { failed = true }
                            }
                            try hotCache.saveCards(cards)
                            if failed {
                                setBanner(.sentPartialArchiveFailure, isError: true)
                                return .succeeded(reference)
                            }
                        }
                        canEndUnarchivedConversation = false
                        checkedCardIDs.subtract(current.cardIDs)
                        if opened {
                            try store.clearCurrent(requestId: current.requestId)
                            activeConversationHost = nil
                        }
                        setBanner(
                            opened
                                ? .sentToNewConversation(count: current.cardIDs.count, host: host)
                                : .sentOpenConversationFailed(host),
                            isError: !opened
                        )
                        return .succeeded(reference)
                    case .rejected, .expired:
                        try store.clearCurrent(requestId: current.requestId)
                        activeConversationHost = nil
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

    public func markCardSynthesized(_ card: RewindCard) async {
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment),
              !card.isOfflinePending else {
            setBanner(.archiveCardBlockedOfflineOrUnconfigured, isError: true)
            return
        }
        do {
            try await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
            checkedCardIDs.remove(card.id)
            updateLocalCards { $0.removeAll { $0.id == card.id } }
        } catch {
            setErrorBanner(error)
        }
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

    public func openURL(_ url: URL) {
        onOpenURL?(url)
    }

    public func installOrRepairPlugin(sourceCLIBinaryURL: URL? = nil, sourceSidecarURL: URL? = nil) {
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
                NativeConversationContext.resolve(selectedText: native.renderedSelection ?? selection.text, snapshot: $0, sessionTitle: native.title)
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

    private func updateLocalCards(_ change: (inout [RewindCard]) -> Void) {
        localCardsRevision += 1
        change(&cards)
        try? hotCache.saveCards(cards)
    }

    private static func mergeCards(cached: [RewindCard], pendingOutbox: [OutboxEntry]) -> [RewindCard] {
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
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func setBanner(_ notice: BannerNotice, isError: Bool) {
        activeBannerNotice = notice
        isUpdatingBannerFromNotice = true
        bannerMessage = L10n.banner(notice, in: language)
        isUpdatingBannerFromNotice = false
        isErrorBanner = isError
    }

    private func setErrorBanner(_ error: any Error) {
        if let rewindError = error as? RewindError {
            setBanner(.rewindError(rewindError), isError: true)
        } else {
            setBanner(.custom(error.localizedDescription), isError: true)
        }
    }
}

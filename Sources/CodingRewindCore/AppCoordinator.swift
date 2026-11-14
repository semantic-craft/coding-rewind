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

    public var label: String {
        switch self {
        case .all: return "全部片段"
        case .ready: return "AI 已整理"
        case .pending: return "待整理"
        }
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
        conversationHost: ConversationHost = .antigravity
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
    }

    public var headerTitle: String {
        pendingOutboxCount > 0
            ? "Coding Rewind · \(hotCardCount) 条片段（待同步 \(pendingOutboxCount) 条）"
            : "Coding Rewind · \(hotCardCount) 条片段"
    }

    public var headerSubtitle: String {
        let memosPart: String
        switch connection {
        case .configured(let hostSummary, _):
            memosPart = "Memos 已配置 \(hostSummary)"
        case .unconfigured:
            memosPart = "Memos 尚未设置，可先保存到本机"
        }
        let pluginPart = isPluginReady ? "插件已安装" : "插件需要安装或修复"
        return "\(memosPart) · \(pluginPart)"
    }

    public var toggleHUDTitle: String {
        isHUDVisible ? "隐藏片段浮窗" : "显示片段浮窗"
    }

    public var launchTitle: String {
        checkedCardCount > 0 ? "在所选应用中开始对话（已选 \(checkedCardCount) 条）" : "在所选应用中开始对话"
    }
}

@MainActor
@Observable
public final class AppCoordinator {
    public let paths: StoragePaths
    public var environment: [String: String]
    public let memosClient: MemosClient
    public let outbox: OfflineOutbox
    public let hotCache: HotCache
    public let handoff: ConversationHandoffStore
    public let codexHandoff: ConversationHandoffStore
    private let codexDelivery: (@Sendable (ConversationRequest) -> (ConversationReceipt.State, String?))?
    public var conversationHost: ConversationHost = .antigravity {
        didSet {
            do { try AtomicFile.writeData(JSONEncoder().encode(conversationHost), to: conversationHostURL) }
            catch { setBanner(error.localizedDescription, isError: true) }
        }
    }
    private var conversationHostURL: URL { paths.dataDirectoryURL.appendingPathComponent("conversation-host.json") }
    public private(set) var activeConversationHost: ConversationHost?
    public private(set) var confirmedConversation: ConversationReference?
    public var effectiveConversationHost: ConversationHost { activeConversationHost ?? conversationHost }
    public var conversationActionTitle: String {
        if isLaunchingConversation { return "正在处理…" }
        if canEndUnarchivedConversation { return "重试归档" }
        if activeConversationHost != nil {
            return confirmedConversation == nil ? "查询发送结果" : "打开对话"
        }
        return "开始对话"
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
    public var bannerMessage: String?
    public var isErrorBanner: Bool = false
    public var pluginStatusText: String = ""

    public var onOpenURL: (@MainActor (URL) -> Void)?
    public var onOpenAntigravityApp: (@MainActor () -> Void)?
    public var onOpenConversation: (@MainActor (ConversationReference) -> Bool)?

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memosClient: MemosClient = MemosClient(),
        capturer: any SelectionCapturing,
        antigravityContext: AntigravityCaptureContext = AntigravityCaptureContext(),
        codexDelivery: (@Sendable (ConversationRequest) -> (ConversationReceipt.State, String?))? = nil
    ) throws {
        self.paths = paths
        self.environment = environment
        self.memosClient = memosClient
        self.outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        self.hotCache = HotCache(fileURL: paths.hotCacheFileURL)
        self.handoff = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL)
        self.codexHandoff = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .codex)
        self.codexDelivery = codexDelivery
        self.antigravityContext = antigravityContext
        self.capturer = capturer
        self.cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
        self.focusedCardID = self.cards.first?.id
        if FileManager.default.fileExists(atPath: conversationHostURL.path) {
            conversationHost = try JSONDecoder().decode(ConversationHost.self, from: Data(contentsOf: conversationHostURL))
        }
        if let (host, store, current) = try activeConversation() {
            activeConversationHost = host
            checkedCardIDs = Set(current.cardIDs)
            let receipt = try store.receipt(for: current.requestId)
            if receipt?.state == .succeeded, let id = receipt?.conversationId {
                confirmedConversation = ConversationReference(host: host, id: id)
            }
            canEndUnconfirmedConversation = receipt?.state == .unknown
            canEndUnarchivedConversation = receipt?.state == .succeeded && current.markSynthesized && !current.archiveCardIDs.isEmpty
            bannerMessage = canEndUnarchivedConversation
                ? "片段已发送，但尚未全部归档。点击“重试归档”继续，不会重复发送"
                : "上次对话请求已保留，可继续处理，不会重复发送片段"
        }
        refreshPluginStatus()
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

        let isPluginReady: Bool
        let pluginSummary: String
        switch AntigravityIntegration.verify(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        ) {
        case .installed:
            isPluginReady = true
            pluginSummary = "Antigravity 插件已安装"
        case .needsInstallOrRepair(let reasons):
            isPluginReady = false
            pluginSummary = "插件需要安装或修复（\(reasons.first ?? "尚未安装")）"
        }

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
            conversationHost: effectiveConversationHost
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
                setBanner("已保存到本机，设置 Memos 连接后将自动同步", isError: false)
                return .queuedOffline(cardID: clientClipId)
            }

            do {
                _ = try? await outbox.flush(using: memosClient, baseURL: baseURL, token: token)
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
                setBanner("已保存片段 · \(sourceTitle)", isError: false)
                return .saved(cardID: saved.id, sourceTitle: sourceTitle)
            } catch {
                try outbox.enqueue(entry)
                setBanner("暂未同步到 Memos，已保存到本机", isError: false)
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
            setBanner(error.localizedDescription, isError: true)
            return .failed(rewindError)
        }
    }

    public func refresh() async {
        latestRefreshRequest += 1
        let ticket = RefreshTicket(request: latestRefreshRequest, localRevision: localCardsRevision)
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment) else {
            guard canPublishRefresh(ticket) else { return }
            cards = Self.mergeCards(cached: cards, pendingOutbox: outbox.loadEntries())
            return
        }
        do {
            _ = try await outbox.flush(using: memosClient, baseURL: baseURL, token: token)
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
            setBanner("同步失败，当前显示本机保存的片段", isError: true)
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
            let store: ConversationHandoffStore
            if let (existingHost, existingStore, existing) = try activeConversation() {
                host = existingHost
                store = existingStore
                current = existing
            } else {
                host = requestedHost ?? conversationHost
                store = handoffStore(for: host)
                let selected = cards.filter { checkedCardIDs.contains($0.id) }
                guard !selected.isEmpty else {
                    setBanner("请先保存或勾选至少一条片段", isError: true)
                    return nil
                }
                if host == .antigravity, case .needsInstallOrRepair = AntigravityIntegration.verify(dataDirectoryURL: paths.dataDirectoryURL, configDirectoryURL: paths.antigravityConfigDirectoryURL) {
                    setBanner("请先安装或修复 Antigravity 插件，再开始对话", isError: true)
                    return nil
                }
                guard host != .codex || codexDelivery != nil else {
                    setBanner("请先安装 Codex。所选片段已保留", isError: true)
                    return nil
                }
                current = try store.submit(prompt: ConversationPrompt.buildPrompt(for: selected), cardIDs: selected.map(\.id), markSynthesized: markSynthesizedOnLaunch)
            }
            activeConversationHost = host
            if host == .antigravity { onOpenAntigravityApp?() }
            setBanner("正在等待 \(host.displayName) 确认发送结果…", isError: false)
            if host == .codex, let codexDelivery {
                try await Task.detached {
                    let worker = try ConversationSidecarWorker(store: store)
                    try worker.processPending(invoke: codexDelivery)
                }.value
            }
            let deadline = Date().addingTimeInterval(max(0, waitSeconds))
            repeat {
                if let receipt = try store.receipt(for: current.requestId), receipt.state != .dispatching {
                    switch receipt.state {
                    case .succeeded:
                        guard let conversationID = receipt.conversationId else { throw RewindError.ioError("发送结果缺少对话编号") }
                        let reference = ConversationReference(host: host, id: conversationID)
                        confirmedConversation = reference
                        let opened = host != .codex || onOpenConversation?(reference) == true
                        if current.markSynthesized && !current.archiveCardIDs.isEmpty {
                            canEndUnarchivedConversation = true
                            let remainingIDs = Set(current.archiveCardIDs)
                            let selected = cards.filter { remainingIDs.contains($0.id) }
                            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                                setBanner("内容已发送，Memos 连接尚未设置，暂时无法归档。片段已保留，可重试归档", isError: true)
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
                                setBanner("内容已发送，部分片段未能归档或已不在最近片段列表中。未归档片段已保留，再次点击只重试归档", isError: true)
                                return .succeeded(reference)
                            }
                        }
                        canEndUnarchivedConversation = false
                        checkedCardIDs.subtract(current.cardIDs)
                        if opened {
                            try store.clearCurrent(requestId: current.requestId)
                            activeConversationHost = nil
                        }
                        setBanner(opened ? "已将 \(current.cardIDs.count) 条片段发送到 \(host.displayName) 的新对话" : "已发送到 Codex，但未能打开对话。可重新打开，不会重复发送", isError: !opened)
                        return .succeeded(reference)
                    case .rejected, .expired:
                        try store.clearCurrent(requestId: current.requestId)
                        activeConversationHost = nil
                        setBanner(receipt.state == .expired ? "发送请求已过期，内容未发送。片段已保留，请打开 \(host.displayName) 后重试" : "\(host.displayName) 暂时无法接收片段，内容未发送。请检查应用是否已安装并重试", isError: true)
                        return .failed(state: receipt.state)
                    case .unknown:
                        canEndUnconfirmedConversation = true
                        setBanner("无法确认是否发送成功，已停止自动重发。请到 \(host.displayName) 检查新对话，片段尚未归档", isError: true)
                        return .failed(state: .unknown)
                    case .dispatching: break
                    }
                }
                if Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled
            setBanner("尚未收到发送结果，片段和请求已保留。再次点击只查询结果，不会重复发送", isError: true)
            return .failed(state: .unknown)
        } catch {
            setBanner(error.localizedDescription, isError: true)
            return nil
        }
    }

    public func endUnconfirmedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let (_, store, current) = try activeConversation(),
                  try store.receipt(for: current.requestId)?.state == .unknown else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try store.clearCurrent(requestId: current.requestId)
            activeConversationHost = nil
            canEndUnconfirmedConversation = false
            setBanner("已清除本次待确认请求。重新勾选片段后可开始新对话", isError: false)
        } catch { setBanner(error.localizedDescription, isError: true) }
    }

    public func endUnarchivedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let (_, store, current) = try activeConversation(), current.markSynthesized,
                  try store.receipt(for: current.requestId)?.state == .succeeded else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try store.clearCurrent(requestId: current.requestId)
            activeConversationHost = nil
            canEndUnarchivedConversation = false
            setBanner("未归档片段已保留。重新勾选后可开始新对话", isError: false)
        } catch { setBanner(error.localizedDescription, isError: true) }
    }

    public func reopenConfirmedConversation() {
        guard let reference = confirmedConversation else { return }
        guard onOpenConversation?(reference) == true else {
            setBanner("内容已发送，但未能打开对话。请重试打开", isError: true)
            return
        }
        do {
            if let (host, store, current) = try activeConversation(), host == reference.host,
               (!current.markSynthesized || current.archiveCardIDs.isEmpty),
               try store.receipt(for: current.requestId)?.conversationId == reference.id {
                try store.clearCurrent(requestId: current.requestId)
                activeConversationHost = nil
            }
            setBanner("已打开 \(reference.host.displayName) 对话", isError: false)
        } catch { setBanner(error.localizedDescription, isError: true) }
    }

    private func handoffStore(for host: ConversationHost) -> ConversationHandoffStore {
        host == .antigravity ? handoff : codexHandoff
    }

    private func activeConversation() throws -> (ConversationHost, ConversationHandoffStore, CurrentConversation)? {
        try ConversationHost.allCases.compactMap { host in
            let store = handoffStore(for: host)
            return try store.current().map { (host, store, $0) }
        }.min { $0.2.expiresAt < $1.2.expiresAt }
    }

    public func markCardSynthesized(_ card: RewindCard) async {
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment),
              !card.isOfflinePending else {
            setBanner("片段尚未同步或 Memos 连接尚未设置，暂时无法归档", isError: true)
            return
        }
        do {
            try await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
            checkedCardIDs.remove(card.id)
            updateLocalCards { $0.removeAll { $0.id == card.id } }
        } catch {
            setBanner(error.localizedDescription, isError: true)
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
        }
        setBanner("已保存 Memos 连接设置", isError: false)
    }

    public func installOrRepairPlugin(sourceBridgeURL: URL?, sourceSidecarURL: URL? = nil) {
        do {
            try AntigravityIntegration.installOrRepair(
                dataDirectoryURL: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                sourceMCPBridgeURL: sourceBridgeURL,
                sourceSidecarBinaryURL: sourceSidecarURL
            )
            refreshPluginStatus()
            setBanner(pluginStatusText, isError: false)
        } catch {
            pluginStatusText = "插件安装失败：\(error.localizedDescription)"
            setBanner(pluginStatusText, isError: true)
        }
    }

    public func refreshPluginStatus() {
        switch AntigravityIntegration.verify(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        ) {
        case .installed:
            pluginStatusText = "Antigravity 插件已安装"
        case .needsInstallOrRepair(let reasons):
            pluginStatusText = "插件需要安装或修复（\(reasons.first ?? "尚未安装")）"
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

    private func setBanner(_ message: String, isError: Bool) {
        bannerMessage = message
        isErrorBanner = isError
    }
}

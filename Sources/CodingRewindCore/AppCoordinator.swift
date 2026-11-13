// SPDX-License-Identifier: MIT

import Foundation
import Observation

public protocol SelectionCapturing: Sendable {
    func captureFrontmostSelection() async throws -> CapturedSelection
}

public enum StatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case ready
    case pending

    public var label: String {
        switch self {
        case .all: return "全部热卡"
        case .ready: return "AI 已定锚"
        case .pending: return "待分析"
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

    public init(
        isHUDVisible: Bool,
        hotCardCount: Int,
        checkedCardCount: Int,
        pendingOutboxCount: Int,
        connection: ConnectionState,
        isPluginReady: Bool,
        pluginSummary: String,
        isAccessibilityTrusted: Bool,
        recentCards: [RecentCardItem]
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
    }

    public var headerTitle: String {
        pendingOutboxCount > 0
            ? "Coding Rewind · \(hotCardCount) 张热卡（待同步 \(pendingOutboxCount)）"
            : "Coding Rewind · \(hotCardCount) 张热卡"
    }

    public var headerSubtitle: String {
        let memosPart: String
        switch connection {
        case .configured(let hostSummary, _):
            memosPart = "Memos 已配置 \(hostSummary)"
        case .unconfigured:
            memosPart = "Memos 未配置（离线队列可用）"
        }
        let pluginPart = isPluginReady ? "插件已就绪" : "插件待安装"
        return "\(memosPart) · \(pluginPart)"
    }

    public var toggleHUDTitle: String {
        isHUDVisible ? "收起 Rewind 浮窗" : "打开 Rewind 浮窗"
    }

    public var launchTitle: String {
        checkedCardCount > 0 ? "在 Antigravity 开聊（已选 \(checkedCardCount) 张）" : "在 Antigravity 开聊"
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
    public private(set) var isLaunchingConversation = false
    public private(set) var canEndUnconfirmedConversation = false
    public private(set) var canEndUnarchivedConversation = false
    public let activeTurns: ActiveTurnStore
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

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memosClient: MemosClient = MemosClient(),
        capturer: any SelectionCapturing
    ) throws {
        self.paths = paths
        self.environment = environment
        self.memosClient = memosClient
        self.outbox = OfflineOutbox(fileURL: paths.outboxFileURL)
        self.hotCache = HotCache(fileURL: paths.hotCacheFileURL)
        self.handoff = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL)
        self.activeTurns = try ActiveTurnStore(dataDirectoryURL: paths.dataDirectoryURL)
        self.capturer = capturer
        self.cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
        self.focusedCardID = self.cards.first?.id
        if let current = try handoff.current() {
            checkedCardIDs = Set(current.cardIDs)
            let receipt = try handoff.receipt(for: current.requestId)
            canEndUnconfirmedConversation = receipt?.state == .unknown
            canEndUnarchivedConversation = receipt?.state == .succeeded && current.markSynthesized && !current.archiveCardIDs.isEmpty
            bannerMessage = "上次接聊请求尚待确认，点击开聊查询结果，不会重复发送"
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
            pluginSummary = "Antigravity 2.x 插件与 Hook 已就绪"
        case .needsInstallOrRepair(let reasons):
            isPluginReady = false
            pluginSummary = "待安装或修复（\(reasons.first ?? "未安装")）"
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
            recentCards: recent
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

    public func captureSelection() async {
        guard !isCapturingSelection else { return }
        isCapturingSelection = true
        defer {
            localCardsRevision += 1
            isCapturingSelection = false
        }
        do {
            let selection = try await capturer.captureFrontmostSelection()
            let (platform, sourceTitle, sourceURL, context) = buildProvenance(from: selection)
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
                setBanner("离线已暂存队列 · 配置 Memos 后自动幂等同步", isError: false)
                return
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
                setBanner("已存入 Rewind 热池 · \(sourceTitle)", isError: false)
            } catch {
                try outbox.enqueue(entry)
                setBanner("网络暂不可达，已安全记入离线队列", isError: false)
            }
        } catch {
            setBanner(error.localizedDescription, isError: true)
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
            setBanner("刷新失败，当前展示本地热缓存", isError: true)
        }
    }

    private func canPublishRefresh(_ ticket: RefreshTicket) -> Bool {
        ticket.request == latestRefreshRequest && ticket.localRevision == localCardsRevision && !isCapturingSelection
    }

    @discardableResult
    public func launchCheckedInAntigravity(waitSeconds: TimeInterval = 40) async -> AntigravityLauncher.LaunchOutcome? {
        guard !isLaunchingConversation else { return nil }
        isLaunchingConversation = true
        canEndUnconfirmedConversation = false
        canEndUnarchivedConversation = false
        defer { isLaunchingConversation = false }
        do {
            let current: CurrentConversation
            if let existing = try handoff.current() {
                current = existing
            } else {
                let selected = cards.filter { checkedCardIDs.contains($0.id) }
                guard !selected.isEmpty else {
                    setBanner("请先捕获或勾选至少一条卡片", isError: true)
                    return nil
                }
                guard case .installed = AntigravityIntegration.verify(dataDirectoryURL: paths.dataDirectoryURL, configDirectoryURL: paths.antigravityConfigDirectoryURL) else {
                    setBanner("请先安装或修复 Antigravity 插件，再点击开聊", isError: true)
                    return nil
                }
                current = try handoff.submit(prompt: AntigravityLauncher.buildPrompt(for: selected), cardIDs: selected.map(\.id), markSynthesized: markSynthesizedOnLaunch)
            }
            onOpenAntigravityApp?()
            setBanner("正在等待 Antigravity 创建新会话并发送上下文…", isError: false)
            let deadline = Date().addingTimeInterval(max(0, waitSeconds))
            repeat {
                if let receipt = try handoff.receipt(for: current.requestId), receipt.state != .dispatching {
                    switch receipt.state {
                    case .succeeded:
                        guard let conversationID = receipt.conversationId else { throw RewindError.ioError("接聊回执缺少会话编号") }
                        if current.markSynthesized && !current.archiveCardIDs.isEmpty {
                            canEndUnarchivedConversation = true
                            let remainingIDs = Set(current.archiveCardIDs)
                            let selected = cards.filter { remainingIDs.contains($0.id) }
                            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                                setBanner("新会话已发送，归档未完成：Memos 未连接。卡片仍保留，可再次点击重试归档", isError: true)
                                return .succeeded(conversationId: conversationID)
                            }
                            var failed = selected.count != remainingIDs.count
                            for card in selected {
                                if card.isOfflinePending { failed = true; continue }
                                do {
                                    try await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
                                    try handoff.recordArchivedCard(card.id, requestId: current.requestId)
                                    checkedCardIDs.remove(card.id)
                                    updateLocalCards { $0.removeAll { $0.id == card.id } }
                                } catch { failed = true }
                            }
                            try hotCache.saveCards(cards)
                            if failed {
                                setBanner("新会话已发送，部分卡片归档失败或已不在热池，未归档卡片保留。再次点击仅重试归档", isError: true)
                                return .succeeded(conversationId: conversationID)
                            }
                        }
                        canEndUnarchivedConversation = false
                        checkedCardIDs.subtract(current.cardIDs)
                        try handoff.clearCurrent(requestId: current.requestId)
                        setBanner("已在 Antigravity 新会话发送上下文（共 \(current.cardIDs.count) 张卡片）", isError: false)
                        return .succeeded(conversationId: conversationID)
                    case .rejected, .expired:
                        try handoff.clearCurrent(requestId: current.requestId)
                        setBanner(receipt.state == .expired ? "接聊请求已过期，未发送。卡片保留，请确认 Antigravity 已启动后重试" : "Antigravity 尚未提供接聊入口，未发送。请安装插件并重新启动 Antigravity 后重试", isError: true)
                        return .failed(state: receipt.state)
                    case .unknown:
                        canEndUnconfirmedConversation = true
                        setBanner("接聊结果无法确认，已停止自动重发。请到 Antigravity 检查新会话，卡片未归档", isError: true)
                        return .failed(state: .unknown)
                    case .dispatching: break
                    }
                }
                if Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled
            setBanner("仍未收到接聊结果，卡片与请求已保留。再次点击仅查询，不会重复发送", isError: true)
            return .failed(state: .unknown)
        } catch {
            setBanner(error.localizedDescription, isError: true)
            return nil
        }
    }

    public func endUnconfirmedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let current = try handoff.current(),
                  try handoff.receipt(for: current.requestId)?.state == .unknown else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try handoff.clearCurrent(requestId: current.requestId)
            canEndUnconfirmedConversation = false
            setBanner("已结束本次未确认请求。重新勾选卡片后可发起新会话", isError: false)
        } catch { setBanner(error.localizedDescription, isError: true) }
    }

    public func endUnarchivedConversation() {
        guard !isLaunchingConversation else { return }
        do {
            guard let current = try handoff.current(), current.markSynthesized,
                  try handoff.receipt(for: current.requestId)?.state == .succeeded else { return }
            checkedCardIDs.subtract(current.cardIDs)
            try handoff.clearCurrent(requestId: current.requestId)
            canEndUnarchivedConversation = false
            setBanner("已结束本次接聊，未归档卡片已保留。重新勾选后可再开聊", isError: false)
        } catch { setBanner(error.localizedDescription, isError: true) }
    }

    public func markCardSynthesized(_ card: RewindCard) async {
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment),
              !card.isOfflinePending else {
            setBanner("离线或未配置凭据，无法标记服务端状态", isError: true)
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
        setBanner("已保存 Memos 连接配置", isError: false)
    }

    public func installOrRepairPlugin(sourceHookURL: URL?, sourceBridgeURL: URL?, sourceSidecarURL: URL? = nil) {
        do {
            try AntigravityIntegration.installOrRepair(
                dataDirectoryURL: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                sourceHookBinaryURL: sourceHookURL,
                sourceMCPBridgeURL: sourceBridgeURL,
                sourceSidecarBinaryURL: sourceSidecarURL
            )
            refreshPluginStatus()
            setBanner(pluginStatusText, isError: false)
        } catch {
            pluginStatusText = "安装失败: \(error.localizedDescription)"
            setBanner(pluginStatusText, isError: true)
        }
    }

    public func refreshPluginStatus() {
        switch AntigravityIntegration.verify(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL
        ) {
        case .installed:
            pluginStatusText = "Antigravity 2.x 插件与 Hook 已就绪"
        case .needsInstallOrRepair(let reasons):
            pluginStatusText = "待安装或修复（\(reasons.first ?? "未安装")）"
        }
    }

    private func buildProvenance(
        from selection: CapturedSelection
    ) -> (platform: String, title: String, url: String?, context: CaptureContext?) {
        if selection.bundleIdentifier == CapturedSelection.antigravityBundleIdentifier {
            if let turn = activeTurns.latestTurn(forFrontmostBundleID: selection.bundleIdentifier) {
                return (
                    "antigravity",
                    turn.sessionTitle,
                    "conversation://\(turn.conversationId)",
                    turn.toCaptureContext()
                )
            }
            return ("antigravity", selection.windowTitle ?? "Antigravity", nil, nil)
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

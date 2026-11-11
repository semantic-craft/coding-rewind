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

@MainActor
@Observable
public final class AppCoordinator {
    public let paths: StoragePaths
    public var environment: [String: String]
    public let memosClient: MemosClient
    public let outbox: OfflineOutbox
    public let hotCache: HotCache
    public let activeTurns: ActiveTurnStore
    public var capturer: any SelectionCapturing

    public var cards: [RewindCard] = []
    public var searchText: String = ""
    public var statusFilter: StatusFilter = .all
    public var checkedCardIDs: Set<String> = []
    public var focusedCardID: String?
    public var bannerMessage: String?
    public var isErrorBanner: Bool = false
    public var pluginStatusText: String = ""

    public var onCopyToClipboard: (@MainActor (String) -> Void)?
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
        self.activeTurns = try ActiveTurnStore(dataDirectoryURL: paths.dataDirectoryURL)
        self.capturer = capturer
        self.cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
        self.focusedCardID = self.cards.first?.id
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

    public func captureSelection() async {
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
                upsertLocalCard(localCard)
                checkedCardIDs.insert(localCard.id)
                focusedCardID = localCard.id
            }

            guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
                  let token = KeychainTokenStore.resolveToken(environment: environment) else {
                try outbox.enqueue(entry)
                try? hotCache.saveCards(cards)
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
                cards.removeAll { $0.id == clientClipId || $0.id == saved.id }
                cards.insert(saved, at: 0)
                checkedCardIDs.remove(clientClipId)
                checkedCardIDs.insert(saved.id)
                focusedCardID = saved.id
                try? hotCache.saveCards(cards)
                setBanner("已存入 Rewind 热池 · \(sourceTitle)", isError: false)
            } catch {
                try outbox.enqueue(entry)
                try? hotCache.saveCards(cards)
                setBanner("网络暂不可达，已安全记入离线队列", isError: false)
            }
        } catch {
            setBanner(error.localizedDescription, isError: true)
        }
    }

    public func refresh() async {
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment),
              let token = KeychainTokenStore.resolveToken(environment: environment) else {
            cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
            return
        }
        do {
            let flushResult = try await outbox.flush(using: memosClient, baseURL: baseURL, token: token)
            let remoteCards = try await memosClient.listHotClips(baseURL: baseURL, token: token)
            cards = Self.mergeCards(cached: remoteCards, pendingOutbox: flushResult.remaining)
            try? hotCache.saveCards(remoteCards)
            if focusedCardID == nil {
                focusedCardID = cards.first?.id
            }
        } catch {
            cards = Self.mergeCards(cached: hotCache.loadCards(), pendingOutbox: outbox.loadEntries())
            setBanner("刷新失败，当前展示本地热缓存", isError: true)
        }
    }

    @discardableResult
    public func launchCheckedInAntigravity(markSynthesized: Bool = false) async -> AntigravityLauncher.LaunchOutcome? {
        let visible = filteredCards
        var selected = cards.filter { checkedCardIDs.contains($0.id) }
        if selected.isEmpty, let first = visible.first {
            selected = [first]
            checkedCardIDs.insert(first.id)
        }
        guard !selected.isEmpty else {
            setBanner("请先捕获或勾选至少一条卡片", isError: true)
            return nil
        }

        let outcome = AntigravityLauncher.launchConversation(
            cards: selected,
            environment: environment,
            copyToClipboard: { [weak self] text in self?.onCopyToClipboard?(text) },
            openAntigravityApp: { [weak self] in self?.onOpenAntigravityApp?() }
        )

        switch outcome {
        case .launchedViaAgentAPI:
            setBanner("已在 Antigravity 开启新会话（共 \(selected.count) 张卡片）", isError: false)
        case .copiedToClipboardFallback:
            setBanner("未找到 agentapi，已复制提示词到剪贴板并打开 Antigravity", isError: false)
        }

        if markSynthesized,
           let baseURL = paths.resolveMemosBaseURL(environment: environment),
           let token = KeychainTokenStore.resolveToken(environment: environment) {
            for card in selected where !card.isOfflinePending {
                try? await memosClient.markSynthesized(card: card, baseURL: baseURL, token: token)
                checkedCardIDs.remove(card.id)
            }
            await refresh()
        }
        return outcome
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
            cards.removeAll { $0.id == card.id }
            try? hotCache.saveCards(cards)
        } catch {
            setBanner(error.localizedDescription, isError: true)
        }
    }

    public func saveCredentials(memosURL: String, token: String) throws {
        try paths.saveMemosURLString(memosURL)
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try KeychainTokenStore.saveToken(token, environment: environment)
        }
        setBanner("已保存 Memos 连接配置", isError: false)
    }

    public func installOrRepairPlugin(sourceHookURL: URL?, sourceBridgeURL: URL?) {
        do {
            try AntigravityIntegration.installOrRepair(
                dataDirectoryURL: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL,
                sourceHookBinaryURL: sourceHookURL,
                sourceMCPBridgeURL: sourceBridgeURL
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

    private func upsertLocalCard(_ card: RewindCard) {
        cards.removeAll { $0.id == card.id }
        cards.insert(card, at: 0)
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

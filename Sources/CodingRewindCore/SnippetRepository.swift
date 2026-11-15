// SPDX-License-Identifier: MIT

import Foundation

public enum SnippetStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case ready
    case synthesized
}

public enum SnippetStatusFilter: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case ready
    case pending
    case synthesized
    case all
}

public enum SnippetDataOrigin: String, Codable, Equatable, Hashable, Sendable {
    case remote
    case localCache
    case offlinePending
}

public enum SnippetResolutionMode: Codable, Equatable, Sendable {
    case online
    case localOnly
    case offlineFallback(reason: String)
}

public struct SnippetRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let status: SnippetStatus
    public let sourcePlatform: String
    public let title: String?
    public let sessionTopic: String?
    public let contextSummary: String?
    public let keywords: [String]
    public let sourceTitle: String
    public let sourceURL: String?
    public let verbatimText: String
    public let createdAt: Date
    public let dataOrigin: SnippetDataOrigin
    public let conversationContext: CaptureContext?

    public init(
        id: String,
        status: SnippetStatus,
        sourcePlatform: String,
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String] = [],
        sourceTitle: String,
        sourceURL: String? = nil,
        verbatimText: String,
        createdAt: Date,
        dataOrigin: SnippetDataOrigin,
        conversationContext: CaptureContext? = nil
    ) {
        self.id = id
        self.status = status
        self.sourcePlatform = sourcePlatform
        self.title = title
        self.sessionTopic = sessionTopic
        self.contextSummary = contextSummary
        self.keywords = keywords
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.verbatimText = verbatimText
        self.createdAt = createdAt
        self.dataOrigin = dataOrigin
        self.conversationContext = conversationContext
    }

    public func withConversationContext(_ conversationContext: CaptureContext?) -> SnippetRecord {
        SnippetRecord(
            id: id,
            status: status,
            sourcePlatform: sourcePlatform,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            verbatimText: verbatimText,
            createdAt: createdAt,
            dataOrigin: dataOrigin,
            conversationContext: conversationContext
        )
    }
}

public struct SnippetQuery: Equatable, Sendable {
    public var windowHours: Double?
    public var status: SnippetStatusFilter
    public var sourcePlatform: String?
    public var searchText: String?
    public var limit: Int

    public init(
        windowHours: Double? = 72,
        status: SnippetStatusFilter = .active,
        sourcePlatform: String? = nil,
        searchText: String? = nil,
        limit: Int = 50
    ) {
        self.windowHours = windowHours
        self.status = status
        self.sourcePlatform = sourcePlatform
        self.searchText = searchText
        self.limit = min(max(limit, 1), 500)
    }
}

public struct SnippetQueryResult: Codable, Equatable, Sendable {
    public let snippets: [SnippetRecord]
    public let resolution: SnippetResolutionMode
    public let pendingOutboxCount: Int

    public init(snippets: [SnippetRecord], resolution: SnippetResolutionMode, pendingOutboxCount: Int) {
        self.snippets = snippets
        self.resolution = resolution
        self.pendingOutboxCount = pendingOutboxCount
    }
}

public protocol SnippetQuerying: Sendable {
    func listSnippets(_ query: SnippetQuery, now: Date) async throws -> SnippetQueryResult
    func getSnippet(id: String, includeContext: Bool, now: Date) async throws -> SnippetRecord
    func archiveSnippet(id: String) async throws -> SnippetRecord
}

public struct SnippetRepository: SnippetQuerying, Sendable {
    public let paths: StoragePaths
    public let environment: [String: String]
    public let bundledDeveloperCredentialsURL: URL?
    public let client: MemosClient
    public let credentialTimeoutSeconds: TimeInterval
    private let preResolvedToken: DeveloperCredentialsResolver.TokenResolution?

    private var outbox: OfflineOutbox {
        OfflineOutbox(fileURL: paths.outboxFileURL)
    }

    private var hotCache: HotCache {
        HotCache(fileURL: paths.hotCacheFileURL)
    }

    private var isQAMode: Bool {
        environment[StoragePaths.qaEnvironmentKey] == "1"
    }

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledDeveloperCredentialsURL: URL? = nil,
        client: MemosClient = MemosClient()
    ) {
        self.init(
            paths: paths,
            environment: environment,
            bundledDeveloperCredentialsURL: bundledDeveloperCredentialsURL,
            client: client,
            credentialTimeoutSeconds: 10.0,
            preResolvedToken: nil
        )
    }

    package init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledDeveloperCredentialsURL: URL? = nil,
        client: MemosClient = MemosClient(),
        credentialTimeoutSeconds: TimeInterval = 10.0,
        preResolvedToken: DeveloperCredentialsResolver.TokenResolution? = nil
    ) {
        self.paths = paths
        self.environment = environment
        self.bundledDeveloperCredentialsURL = bundledDeveloperCredentialsURL
        self.client = client
        self.credentialTimeoutSeconds = credentialTimeoutSeconds
        self.preResolvedToken = preResolvedToken
    }

    private func resolveToken() -> DeveloperCredentialsResolver.TokenResolution {
        if let preResolvedToken {
            return preResolvedToken
        }
        return DeveloperCredentialsResolver.resolveToken(
            paths: paths,
            environment: environment,
            bundledDeveloperCredentialsURL: bundledDeveloperCredentialsURL,
            timeoutSeconds: credentialTimeoutSeconds
        )
    }

    public func listSnippets(_ query: SnippetQuery = SnippetQuery(), now: Date = Date()) async throws -> SnippetQueryResult {
        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            let outboxEntries = outbox.loadEntries()
            return buildLocalQueryResult(
                query: query,
                now: now,
                outboxEntries: outboxEntries,
                pendingOutboxCount: outboxEntries.count,
                resolution: .localOnly
            )
        }

        let token: String
        switch resolveToken() {
        case .resolved(let resolvedToken):
            token = resolvedToken
        case .developerCredentialsFailed(let failure):
            let outboxEntries = outbox.loadEntries()
            return buildLocalQueryResult(
                query: query,
                now: now,
                outboxEntries: outboxEntries,
                pendingOutboxCount: outboxEntries.count,
                resolution: .offlineFallback(reason: failure.localizedDescription(in: .en))
            )
        case .missing:
            if isQAMode {
                throw RewindError.missingCredentials
            }
            let outboxEntries = outbox.loadEntries()
            if environment[KeychainTokenStore.disableKeychainFallbackEnvironmentKey] == "1" {
                return buildLocalQueryResult(
                    query: query,
                    now: now,
                    outboxEntries: outboxEntries,
                    pendingOutboxCount: outboxEntries.count,
                    resolution: .offlineFallback(reason: "Developer credentials unavailable; Keychain fallback disabled.")
                )
            }
            return buildLocalQueryResult(
                query: query,
                now: now,
                outboxEntries: outboxEntries,
                pendingOutboxCount: outboxEntries.count,
                resolution: .localOnly
            )
        }

        do {
            let remoteDTOs = try await client.listAllMemos(baseURL: baseURL, token: token)
            let freshOutboxEntries = outbox.loadEntries()
            var recordsByID: [String: SnippetRecord] = [:]

            for dto in remoteDTOs {
                guard let created = dto.createTime.flatMap(MemosWireFormat.parseISO8601)
                    ?? dto.updateTime.flatMap(MemosWireFormat.parseISO8601) else {
                    continue
                }
                if let record = MemosWireFormat.parseSnippetRecord(
                    id: dto.name,
                    rawContent: dto.content,
                    createdAt: created,
                    dataOrigin: .remote
                ) {
                    recordsByID[record.id] = record
                }
            }

            for entry in freshOutboxEntries where recordsByID[entry.clientClipId] == nil {
                if let pendingRecord = MemosWireFormat.parseSnippetRecord(
                    id: entry.clientClipId,
                    rawContent: entry.memoContent,
                    createdAt: entry.createdAt,
                    dataOrigin: .offlinePending
                ) {
                    recordsByID[pendingRecord.id] = pendingRecord
                }
            }

            let filtered = Self.applyQuery(query, to: Array(recordsByID.values), now: now)
            return SnippetQueryResult(
                snippets: filtered,
                resolution: .online,
                pendingOutboxCount: freshOutboxEntries.count
            )
        } catch {
            let freshOutboxEntries = outbox.loadEntries()
            return buildLocalQueryResult(
                query: query,
                now: now,
                outboxEntries: freshOutboxEntries,
                pendingOutboxCount: freshOutboxEntries.count,
                resolution: .offlineFallback(reason: Self.describeFallbackReason(error))
            )
        }
    }

    public func getSnippet(id: String, includeContext: Bool = true, now: Date = Date()) async throws -> SnippetRecord {
        let normalizedID = try MemosWireFormat.normalizeSnippetID(id)

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            return try loadLocalSnippet(id: normalizedID, includeContext: includeContext, now: now)
        }

        let token: String
        switch resolveToken() {
        case .resolved(let resolvedToken):
            token = resolvedToken
        case .developerCredentialsFailed(let failure):
            if let local = try? loadLocalSnippet(id: normalizedID, includeContext: includeContext, now: now) {
                return local
            }
            throw failure
        case .missing:
            if isQAMode {
                throw RewindError.missingCredentials
            }
            return try loadLocalSnippet(id: normalizedID, includeContext: includeContext, now: now)
        }

        let dto: MemoWireDTO
        do {
            dto = try await client.getMemo(id: normalizedID, baseURL: baseURL, token: token)
        } catch let error as RewindError {
            if case .httpError(let statusCode, _) = error, statusCode == 404 {
                if let outboxRecord = loadOutboxSnippet(id: normalizedID, includeContext: includeContext) {
                    return outboxRecord
                }
                throw error
            }
            if let local = try? loadLocalSnippet(id: normalizedID, includeContext: includeContext, now: now) {
                return local
            }
            throw error
        } catch {
            if let local = try? loadLocalSnippet(id: normalizedID, includeContext: includeContext, now: now) {
                return local
            }
            throw RewindError.networkFailure(error.localizedDescription)
        }

        let createdAt = dto.createTime.flatMap(MemosWireFormat.parseISO8601)
            ?? dto.updateTime.flatMap(MemosWireFormat.parseISO8601)
            ?? now
        let resolvedName = dto.name.isEmpty ? normalizedID : dto.name

        guard let baseRecord = MemosWireFormat.parseSnippetRecord(
            id: resolvedName,
            rawContent: dto.content,
            createdAt: createdAt,
            dataOrigin: .remote
        ) else {
            throw RewindError.snippetNotFound(normalizedID)
        }

        guard includeContext else {
            return baseRecord
        }

        var conversationContext: CaptureContext?
        if let comments = try? await client.listMemoComments(id: normalizedID, baseURL: baseURL, token: token) {
            for comment in comments {
                if let parsed = MemosWireFormat.parseContextComment(comment.content) {
                    conversationContext = parsed
                    break
                }
            }
        }
        return conversationContext == nil ? baseRecord : baseRecord.withConversationContext(conversationContext)
    }

    public func archiveSnippet(id: String) async throws -> SnippetRecord {
        let normalizedID = try MemosWireFormat.normalizeSnippetID(id)

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            throw RewindError.missingCredentials
        }

        let token: String
        switch resolveToken() {
        case .resolved(let resolvedToken):
            token = resolvedToken
        case .developerCredentialsFailed(let failure):
            throw failure
        case .missing:
            throw RewindError.missingCredentials
        }

        if let pendingEntry = outbox.loadEntries().first(where: { $0.clientClipId == normalizedID }) {
            _ = try await client.createClip(
                clientClipId: pendingEntry.clientClipId,
                content: pendingEntry.memoContent,
                contextComment: pendingEntry.commentContent,
                baseURL: baseURL,
                token: token,
                fallbackCreatedAt: pendingEntry.createdAt
            )
        }

        let dto = try await client.getMemo(id: normalizedID, baseURL: baseURL, token: token)
        let createdAt = dto.createTime.flatMap(MemosWireFormat.parseISO8601)
            ?? dto.updateTime.flatMap(MemosWireFormat.parseISO8601)
            ?? Date()
        let resolvedName = dto.name.isEmpty ? normalizedID : dto.name

        guard MemosWireFormat.parseSnippetRecord(
            id: resolvedName,
            rawContent: dto.content,
            createdAt: createdAt,
            dataOrigin: .remote
        ) != nil else {
            throw RewindError.snippetNotFound(normalizedID)
        }

        let updatedContent = MemosWireFormat.replacingWithSynthesizedTag(dto.content)
        let patchedDTO = try await client.updateMemoContent(
            id: normalizedID,
            content: updatedContent,
            baseURL: baseURL,
            token: token
        )

        let finalContent = (patchedDTO?.content.isEmpty == false) ? patchedDTO!.content : updatedContent
        let finalCreatedAt = patchedDTO?.createTime.flatMap(MemosWireFormat.parseISO8601) ?? createdAt
        let finalName = (patchedDTO?.name.isEmpty == false) ? patchedDTO!.name : resolvedName

        try? outbox.removeEntry(clientClipId: normalizedID)
        try? hotCache.removeCard(id: normalizedID)

        guard let updatedRecord = MemosWireFormat.parseSnippetRecord(
            id: finalName,
            rawContent: finalContent,
            createdAt: finalCreatedAt,
            dataOrigin: .remote
        ) else {
            throw RewindError.invalidServerResponse
        }
        return updatedRecord
    }

    private func buildLocalQueryResult(
        query: SnippetQuery,
        now: Date,
        outboxEntries: [OutboxEntry],
        pendingOutboxCount: Int,
        resolution: SnippetResolutionMode
    ) -> SnippetQueryResult {
        var recordsByID: [String: SnippetRecord] = [:]
        for card in hotCache.loadCards(now: now) {
            let origin: SnippetDataOrigin = card.isOfflinePending ? .offlinePending : .localCache
            if let record = MemosWireFormat.parseSnippetRecord(
                id: card.id,
                rawContent: card.rawContent,
                createdAt: card.createdAt,
                dataOrigin: origin
            ) {
                recordsByID[record.id] = record
            }
        }
        for entry in outboxEntries {
            if let record = MemosWireFormat.parseSnippetRecord(
                id: entry.clientClipId,
                rawContent: entry.memoContent,
                createdAt: entry.createdAt,
                dataOrigin: .offlinePending
            ) {
                recordsByID[record.id] = record
            }
        }
        let filtered = Self.applyQuery(query, to: Array(recordsByID.values), now: now)
        return SnippetQueryResult(
            snippets: filtered,
            resolution: resolution,
            pendingOutboxCount: pendingOutboxCount
        )
    }

    private func loadOutboxSnippet(
        id normalizedID: String,
        includeContext: Bool
    ) -> SnippetRecord? {
        guard let entry = outbox.loadEntries().first(where: { $0.clientClipId == normalizedID }) else {
            return nil
        }
        let context = includeContext
            ? entry.commentContent.flatMap(MemosWireFormat.parseContextComment)
            : nil
        return MemosWireFormat.parseSnippetRecord(
            id: entry.clientClipId,
            rawContent: entry.memoContent,
            createdAt: entry.createdAt,
            dataOrigin: .offlinePending,
            conversationContext: context
        )
    }

    private func loadLocalSnippet(
        id normalizedID: String,
        includeContext: Bool,
        now: Date
    ) throws -> SnippetRecord {
        if let outboxRecord = loadOutboxSnippet(id: normalizedID, includeContext: includeContext) {
            return outboxRecord
        }
        return try loadCachedSnippet(id: normalizedID, now: now)
    }

    private func loadCachedSnippet(id normalizedID: String, now: Date) throws -> SnippetRecord {
        let cachedCards = hotCache.loadCards(now: now)
        if let card = cachedCards.first(where: { $0.id == normalizedID }),
           let record = MemosWireFormat.parseSnippetRecord(
               id: card.id,
               rawContent: card.rawContent,
               createdAt: card.createdAt,
               dataOrigin: card.isOfflinePending ? .offlinePending : .localCache
           ) {
            return record
        }
        throw RewindError.snippetNotFound(normalizedID)
    }

    private static func applyQuery(_ query: SnippetQuery, to records: [SnippetRecord], now: Date) -> [SnippetRecord] {
        let cutoff: Date? = query.windowHours.map { now.addingTimeInterval(-max(0, $0) * 3600) }
        let trimmedPlatform = query.sourcePlatform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let platformFilter = (trimmedPlatform?.isEmpty == false) ? trimmedPlatform : nil
        let trimmedSearch = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = (trimmedSearch?.isEmpty == false) ? trimmedSearch!.lowercased() : nil
        let clampedLimit = min(max(query.limit, 1), 500)

        let filtered = records.filter { record in
            if let cutoff, record.createdAt < cutoff {
                return false
            }
            switch query.status {
            case .active:
                if record.status != .ready && record.status != .pending {
                    return false
                }
            case .ready:
                if record.status != .ready {
                    return false
                }
            case .pending:
                if record.status != .pending {
                    return false
                }
            case .synthesized:
                if record.status != .synthesized {
                    return false
                }
            case .all:
                break
            }
            if let platformFilter,
               record.sourcePlatform.caseInsensitiveCompare(platformFilter) != .orderedSame {
                return false
            }
            if let needle {
                let matchesField: (String?) -> Bool = { candidate in
                    guard let candidate, !candidate.isEmpty else { return false }
                    return candidate.lowercased().contains(needle)
                }
                let matched = matchesField(record.title)
                    || matchesField(record.sessionTopic)
                    || matchesField(record.contextSummary)
                    || record.keywords.contains(where: { $0.lowercased().contains(needle) })
                    || matchesField(record.sourceTitle)
                    || matchesField(record.verbatimText)
                if !matched {
                    return false
                }
            }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(clampedLimit))
    }

    private static func describeFallbackReason(_ error: any Error) -> String {
        if let rewindError = error as? RewindError {
            return rewindError.localizedDescription(in: .en)
        }
        return error.localizedDescription
    }
}

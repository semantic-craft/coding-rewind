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
    public let tags: [String]
    public let sourceTitle: String
    public let sourceURL: String?
    public let verbatimText: String
    public let createdAt: Date
    public let dataOrigin: SnippetDataOrigin
    public let conversationContext: CaptureContext?
    public let notes: [SnippetNote]

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case sourcePlatform
        case title
        case sessionTopic
        case contextSummary
        case keywords
        case tags
        case sourceTitle
        case sourceURL
        case verbatimText
        case createdAt
        case dataOrigin
        case conversationContext
        case notes
    }

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
        conversationContext: CaptureContext? = nil,
        tags: [String] = [],
        notes: [SnippetNote] = []
    ) {
        self.id = id
        self.status = status
        self.sourcePlatform = sourcePlatform
        self.title = title
        self.sessionTopic = sessionTopic
        self.contextSummary = contextSummary
        self.keywords = keywords
        self.tags = tags
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.verbatimText = verbatimText
        self.createdAt = createdAt
        self.dataOrigin = dataOrigin
        self.conversationContext = conversationContext
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.status = try container.decode(SnippetStatus.self, forKey: .status)
        self.sourcePlatform = try container.decode(String.self, forKey: .sourcePlatform)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.sessionTopic = try container.decodeIfPresent(String.self, forKey: .sessionTopic)
        self.contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        self.keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.sourceTitle = try container.decode(String.self, forKey: .sourceTitle)
        self.sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        self.verbatimText = try container.decode(String.self, forKey: .verbatimText)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.dataOrigin = try container.decode(SnippetDataOrigin.self, forKey: .dataOrigin)
        self.conversationContext = try container.decodeIfPresent(CaptureContext.self, forKey: .conversationContext)
        self.notes = try container.decodeIfPresent([SnippetNote].self, forKey: .notes) ?? []
    }

    public func withConversationContext(_ conversationContext: CaptureContext?) -> SnippetRecord {
        withAttachments(conversationContext: conversationContext, notes: notes)
    }

    public func withAttachments(
        conversationContext: CaptureContext?,
        notes: [SnippetNote]
    ) -> SnippetRecord {
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
            conversationContext: conversationContext,
            tags: tags,
            notes: notes
        )
    }
}

public struct SnippetCreateInput: Equatable, Sendable {
    public var text: String
    public var title: String?
    public var sessionTopic: String?
    public var contextSummary: String?
    public var keywords: [String]
    public var tags: [String]
    public var sourcePlatform: String
    public var sourceTitle: String?
    public var sourceURL: String?

    public init(
        text: String,
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String] = [],
        tags: [String] = [],
        sourcePlatform: String = "agent",
        sourceTitle: String? = nil,
        sourceURL: String? = nil
    ) {
        self.text = text
        self.title = title
        self.sessionTopic = sessionTopic
        self.contextSummary = contextSummary
        self.keywords = keywords
        self.tags = tags
        self.sourcePlatform = sourcePlatform
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
    }
}

public struct SnippetMetadataPatch: Equatable, Sendable {
    public var title: String?
    public var sessionTopic: String?
    public var contextSummary: String?
    public var keywords: [String]?
    public var addTags: [String]
    public var removeTags: [String]
    public var archived: Bool?

    public init(
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String]? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        archived: Bool? = nil
    ) {
        self.title = title
        self.sessionTopic = sessionTopic
        self.contextSummary = contextSummary
        self.keywords = keywords
        self.addTags = addTags
        self.removeTags = removeTags
        self.archived = archived
    }

    public var isEmpty: Bool {
        title == nil
            && sessionTopic == nil
            && contextSummary == nil
            && keywords == nil
            && addTags.isEmpty
            && removeTags.isEmpty
            && archived == nil
    }
}

public struct SnippetNoteInput: Equatable, Sendable {
    public var note: String
    public var author: String?

    public init(note: String, author: String? = nil) {
        self.note = note
        self.author = author
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

public enum SnippetDeletionDisposition: String, Codable, Equatable, Sendable {
    case remoteAndLocal
    case localPendingOnly
    case alreadyAbsent
}

public struct SnippetDeletionResult: Codable, Equatable, Sendable {
    public let id: String
    public let deleted: Bool
    public let disposition: SnippetDeletionDisposition

    public init(id: String, deleted: Bool, disposition: SnippetDeletionDisposition) {
        self.id = id
        self.deleted = deleted
        self.disposition = disposition
    }
}

public protocol SnippetQuerying: Sendable {
    func listSnippets(_ query: SnippetQuery, now: Date) async throws -> SnippetQueryResult
    func getSnippet(id: String, includeContext: Bool, now: Date) async throws -> SnippetRecord
    func createSnippet(_ input: SnippetCreateInput, now: Date) async throws -> SnippetRecord
    func updateSnippetMetadata(id: String, patch: SnippetMetadataPatch, now: Date) async throws -> SnippetRecord
    func appendSnippetNote(id: String, input: SnippetNoteInput, now: Date) async throws -> SnippetRecord
    func archiveSnippet(id: String) async throws -> SnippetRecord
    func deleteSnippet(id: String) async throws -> SnippetDeletionResult
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

    private var localNotesStore: LocalNotesStore {
        LocalNotesStore(fileURL: paths.localNotesFileURL)
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

        var conversationContext: CaptureContext?
        var collectedNotes = localNotesStore.loadNotes(for: normalizedID)
        if let comments = try? await client.listMemoComments(id: normalizedID, baseURL: baseURL, token: token) {
            for comment in comments {
                if includeContext, conversationContext == nil,
                   let parsedCtx = MemosWireFormat.parseContextComment(comment.content) {
                    conversationContext = parsedCtx
                } else {
                    let fallbackDate = comment.createTime.flatMap(MemosWireFormat.parseISO8601)
                        ?? comment.updateTime.flatMap(MemosWireFormat.parseISO8601)
                        ?? now
                    if let parsedNote = MemosWireFormat.parseNoteComment(
                        id: comment.name,
                        rawComment: comment.content,
                        fallbackCreatedAt: fallbackDate
                    ) {
                        collectedNotes.append(parsedNote)
                    }
                }
            }
        }
        let sortedNotes = LocalNotesStore.sortAndDeduplicate(collectedNotes)
        return baseRecord.withAttachments(
            conversationContext: includeContext ? conversationContext : nil,
            notes: sortedNotes
        )
    }

    public func createSnippet(_ input: SnippetCreateInput, now: Date = Date()) async throws -> SnippetRecord {
        let clientClipId = MemosWireFormat.makeClientClipID(now: now)
        let rawContent = try MemosWireFormat.formatAgentCreatedContent(
            verbatimText: input.text,
            sourcePlatform: input.sourcePlatform,
            sourceTitle: input.sourceTitle ?? "AI Synthesis",
            sourceURL: input.sourceURL,
            capturedAt: now,
            title: input.title,
            sessionTopic: input.sessionTopic,
            contextSummary: input.contextSummary,
            keywords: input.keywords,
            tags: input.tags
        )

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            return try enqueueLocalCreatedClip(clientClipId: clientClipId, rawContent: rawContent, now: now)
        }

        let token: String
        switch resolveToken() {
        case .resolved(let resolvedToken):
            token = resolvedToken
        case .developerCredentialsFailed(let failure):
            throw failure
        case .missing:
            if isQAMode {
                throw RewindError.missingCredentials
            }
            return try enqueueLocalCreatedClip(clientClipId: clientClipId, rawContent: rawContent, now: now)
        }

        do {
            let savedCard = try await client.createClip(
                clientClipId: clientClipId,
                content: rawContent,
                contextComment: nil,
                baseURL: baseURL,
                token: token,
                fallbackCreatedAt: now
            )
            if let hotCard = MemosWireFormat.parseMemo(
                id: savedCard.id,
                rawContent: savedCard.rawContent,
                createdAt: savedCard.createdAt,
                now: now,
                isOfflinePending: false
            ) {
                try? hotCache.upsertCard(hotCard, now: now)
            }
            guard let record = MemosWireFormat.parseSnippetRecord(
                id: savedCard.id,
                rawContent: savedCard.rawContent,
                createdAt: savedCard.createdAt,
                dataOrigin: .remote
            ) else {
                throw RewindError.invalidServerResponse
            }
            return record
        } catch is URLError {
            return try enqueueLocalCreatedClip(clientClipId: clientClipId, rawContent: rawContent, now: now)
        } catch RewindError.networkFailure {
            return try enqueueLocalCreatedClip(clientClipId: clientClipId, rawContent: rawContent, now: now)
        }
    }

    public func updateSnippetMetadata(
        id: String,
        patch: SnippetMetadataPatch,
        now: Date = Date()
    ) async throws -> SnippetRecord {
        let normalizedID = try MemosWireFormat.normalizeSnippetID(id)
        guard !patch.isEmpty else {
            throw RewindError.invalidMetadataUpdate("At least one metadata field or tag change is required.")
        }
        for rawTag in patch.addTags where MemosWireFormat.sanitizeCustomTag(rawTag) == nil {
            throw RewindError.invalidMetadataUpdate("Invalid custom tag '\(rawTag)'.")
        }
        for rawTag in patch.removeTags where MemosWireFormat.sanitizeCustomTag(rawTag) == nil {
            throw RewindError.invalidMetadataUpdate("Invalid custom tag '\(rawTag)'.")
        }

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            return try updateLocalSnippetMetadata(id: normalizedID, patch: patch, now: now)
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
            ?? now
        let resolvedName = dto.name.isEmpty ? normalizedID : dto.name

        guard MemosWireFormat.parseSnippetRecord(
            id: resolvedName,
            rawContent: dto.content,
            createdAt: createdAt,
            dataOrigin: .remote
        ) != nil else {
            throw RewindError.snippetNotFound(normalizedID)
        }

        let updatedContent = MemosWireFormat.updatingSnippetMetadata(
            rawContent: dto.content,
            title: patch.title,
            sessionTopic: patch.sessionTopic,
            contextSummary: patch.contextSummary,
            keywords: patch.keywords,
            addTags: patch.addTags,
            removeTags: patch.removeTags,
            archived: patch.archived
        )
        let patchedDTO = try await client.updateMemoContent(
            id: normalizedID,
            content: updatedContent,
            baseURL: baseURL,
            token: token
        )

        let finalContent = (patchedDTO?.content.isEmpty == false) ? patchedDTO!.content : updatedContent
        let finalCreatedAt = patchedDTO?.createTime.flatMap(MemosWireFormat.parseISO8601) ?? createdAt
        let finalName = (patchedDTO?.name.isEmpty == false) ? patchedDTO!.name : resolvedName

        _ = try? outbox.removeEntry(clientClipId: normalizedID)
        if let activeCard = MemosWireFormat.parseMemo(
            id: normalizedID,
            rawContent: finalContent,
            createdAt: finalCreatedAt,
            now: now,
            isOfflinePending: false
        ) {
            try? hotCache.upsertCard(activeCard, now: now)
        } else {
            _ = try? hotCache.removeCard(id: normalizedID)
        }

        guard let updatedRecord = MemosWireFormat.parseSnippetRecord(
            id: finalName,
            rawContent: finalContent,
            createdAt: finalCreatedAt,
            dataOrigin: .remote,
            notes: localNotesStore.loadNotes(for: normalizedID)
        ) else {
            throw RewindError.invalidServerResponse
        }
        return updatedRecord
    }

    public func appendSnippetNote(
        id: String,
        input: SnippetNoteInput,
        now: Date = Date()
    ) async throws -> SnippetRecord {
        let normalizedID = try MemosWireFormat.normalizeSnippetID(id)
        let commentMarkdown = try MemosWireFormat.formatNoteComment(
            note: input.note,
            author: input.author,
            createdAt: now
        )
        let commentID = MemosWireFormat.makeNoteCommentID(snippetID: normalizedID, now: now)

        guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
            _ = try loadLocalSnippet(id: normalizedID, includeContext: true, now: now)
            guard let localNote = MemosWireFormat.parseNoteComment(
                id: commentID,
                rawComment: commentMarkdown,
                fallbackCreatedAt: now
            ) else {
                throw RewindError.invalidMetadataUpdate("Failed to construct note payload.")
            }
            try localNotesStore.appendNote(localNote, for: normalizedID)
            return try loadLocalSnippet(id: normalizedID, includeContext: true, now: now)
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
            _ = try? outbox.removeEntry(clientClipId: normalizedID)
        }

        let dto = try await client.getMemo(id: normalizedID, baseURL: baseURL, token: token)
        let createdAt = dto.createTime.flatMap(MemosWireFormat.parseISO8601)
            ?? dto.updateTime.flatMap(MemosWireFormat.parseISO8601)
            ?? now
        let resolvedName = dto.name.isEmpty ? normalizedID : dto.name
        guard MemosWireFormat.parseSnippetRecord(
            id: resolvedName,
            rawContent: dto.content,
            createdAt: createdAt,
            dataOrigin: .remote
        ) != nil else {
            throw RewindError.snippetNotFound(normalizedID)
        }

        let postedDTO = try await client.postMemoComment(
            memoID: normalizedID,
            commentID: commentID,
            content: commentMarkdown,
            baseURL: baseURL,
            token: token
        )
        let postedNote = MemosWireFormat.parseNoteComment(
            id: postedDTO.name,
            rawComment: postedDTO.content.isEmpty ? commentMarkdown : postedDTO.content,
            fallbackCreatedAt: postedDTO.createTime.flatMap(MemosWireFormat.parseISO8601) ?? now
        )

        let refreshed = try await getSnippet(id: normalizedID, includeContext: true, now: now)
        if let postedNote {
            let merged = LocalNotesStore.sortAndDeduplicate(refreshed.notes + [postedNote])
            return refreshed.withAttachments(conversationContext: refreshed.conversationContext, notes: merged)
        }
        return refreshed
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

        _ = try? outbox.removeEntry(clientClipId: normalizedID)
        _ = try? hotCache.removeCard(id: normalizedID)

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

    public func deleteSnippet(id: String) async throws -> SnippetDeletionResult {
        let normalizedID = try MemosWireFormat.normalizeSnippetID(id)
        let hadOutbox = outbox.loadEntries().contains { $0.clientClipId == normalizedID }

        if hadOutbox {
            guard let baseURL = paths.resolveMemosBaseURL(environment: environment) else {
                return try finalizePendingDeletion(id: normalizedID)
            }

            let token: String
            switch resolveToken() {
            case .resolved(let resolvedToken):
                token = resolvedToken
            case .developerCredentialsFailed(let failure):
                throw failure
            case .missing:
                if isQAMode {
                    throw RewindError.missingCredentials
                }
                return try finalizePendingDeletion(id: normalizedID)
            }

            do {
                let existedRemote = try await client.deleteMemo(id: normalizedID, baseURL: baseURL, token: token)
                return try finalizePendingDeletion(
                    id: normalizedID,
                    disposition: existedRemote ? .remoteAndLocal : .localPendingOnly
                )
            } catch RewindError.networkFailure {
                return try finalizePendingDeletion(id: normalizedID)
            }
        }

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

        let existedRemote = try await client.deleteMemo(id: normalizedID, baseURL: baseURL, token: token)
        _ = try? outbox.removeEntry(clientClipId: normalizedID)
        _ = try? localNotesStore.removeNotes(for: normalizedID)
        let removedCache = (try? hotCache.removeCard(id: normalizedID)) ?? false
        return SnippetDeletionResult(
            id: normalizedID,
            deleted: existedRemote || removedCache,
            disposition: existedRemote ? .remoteAndLocal : .alreadyAbsent
        )
    }

    private func finalizePendingDeletion(
        id normalizedID: String,
        disposition: SnippetDeletionDisposition = .localPendingOnly
    ) throws -> SnippetDeletionResult {
        try outbox.removeEntry(clientClipId: normalizedID)
        _ = try? hotCache.removeCard(id: normalizedID)
        _ = try? localNotesStore.removeNotes(for: normalizedID)
        return SnippetDeletionResult(id: normalizedID, deleted: true, disposition: disposition)
    }

    private func enqueueLocalCreatedClip(
        clientClipId: String,
        rawContent: String,
        now: Date
    ) throws -> SnippetRecord {
        let entry = OutboxEntry(
            clientClipId: clientClipId,
            memoContent: rawContent,
            commentContent: nil,
            createdAt: now
        )
        try outbox.enqueue(entry)
        if let hotCard = MemosWireFormat.parseMemo(
            id: clientClipId,
            rawContent: rawContent,
            createdAt: now,
            now: now,
            isOfflinePending: true
        ) {
            try hotCache.upsertCard(hotCard, now: now)
        }
        guard let record = MemosWireFormat.parseSnippetRecord(
            id: clientClipId,
            rawContent: rawContent,
            createdAt: now,
            dataOrigin: .offlinePending,
            notes: localNotesStore.loadNotes(for: clientClipId)
        ) else {
            throw RewindError.ioError("Failed to parse created local snippet")
        }
        return record
    }

    private func updateLocalSnippetMetadata(
        id normalizedID: String,
        patch: SnippetMetadataPatch,
        now: Date
    ) throws -> SnippetRecord {
        if let existingEntry = outbox.loadEntries().first(where: { $0.clientClipId == normalizedID }) {
            guard MemosWireFormat.parseSnippetRecord(
                id: existingEntry.clientClipId,
                rawContent: existingEntry.memoContent,
                createdAt: existingEntry.createdAt,
                dataOrigin: .offlinePending
            ) != nil else {
                throw RewindError.snippetNotFound(normalizedID)
            }
            let updatedContent = MemosWireFormat.updatingSnippetMetadata(
                rawContent: existingEntry.memoContent,
                title: patch.title,
                sessionTopic: patch.sessionTopic,
                contextSummary: patch.contextSummary,
                keywords: patch.keywords,
                addTags: patch.addTags,
                removeTags: patch.removeTags,
                archived: patch.archived
            )
            let updatedEntry = OutboxEntry(
                clientClipId: existingEntry.clientClipId,
                memoContent: updatedContent,
                commentContent: existingEntry.commentContent,
                createdAt: existingEntry.createdAt
            )
            try outbox.enqueue(updatedEntry)
            if let hotCard = MemosWireFormat.parseMemo(
                id: existingEntry.clientClipId,
                rawContent: updatedContent,
                createdAt: existingEntry.createdAt,
                now: now,
                isOfflinePending: true
            ) {
                try hotCache.upsertCard(hotCard, now: now)
            } else {
                _ = try? hotCache.removeCard(id: normalizedID)
            }
            guard let updatedRecord = MemosWireFormat.parseSnippetRecord(
                id: existingEntry.clientClipId,
                rawContent: updatedContent,
                createdAt: existingEntry.createdAt,
                dataOrigin: .offlinePending,
                notes: localNotesStore.loadNotes(for: normalizedID)
            ) else {
                throw RewindError.ioError("Failed to parse updated local snippet")
            }
            return updatedRecord
        }

        let cachedCards = hotCache.loadCards(now: now)
        if let card = cachedCards.first(where: { $0.id == normalizedID }),
           MemosWireFormat.parseSnippetRecord(
               id: card.id,
               rawContent: card.rawContent,
               createdAt: card.createdAt,
               dataOrigin: card.isOfflinePending ? .offlinePending : .localCache
           ) != nil {
            let updatedContent = MemosWireFormat.updatingSnippetMetadata(
                rawContent: card.rawContent,
                title: patch.title,
                sessionTopic: patch.sessionTopic,
                contextSummary: patch.contextSummary,
                keywords: patch.keywords,
                addTags: patch.addTags,
                removeTags: patch.removeTags,
                archived: patch.archived
            )
            let updatedEntry = OutboxEntry(
                clientClipId: card.id,
                memoContent: updatedContent,
                commentContent: nil,
                createdAt: card.createdAt
            )
            try outbox.enqueue(updatedEntry)
            if let hotCard = MemosWireFormat.parseMemo(
                id: card.id,
                rawContent: updatedContent,
                createdAt: card.createdAt,
                now: now,
                isOfflinePending: true
            ) {
                try hotCache.upsertCard(hotCard, now: now)
            } else {
                _ = try? hotCache.removeCard(id: normalizedID)
            }
            guard let updatedRecord = MemosWireFormat.parseSnippetRecord(
                id: card.id,
                rawContent: updatedContent,
                createdAt: card.createdAt,
                dataOrigin: .offlinePending,
                notes: localNotesStore.loadNotes(for: normalizedID)
            ) else {
                throw RewindError.ioError("Failed to parse updated cached snippet")
            }
            return updatedRecord
        }

        throw RewindError.snippetNotFound(normalizedID)
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
            conversationContext: context,
            notes: localNotesStore.loadNotes(for: normalizedID)
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
               dataOrigin: card.isOfflinePending ? .offlinePending : .localCache,
               notes: localNotesStore.loadNotes(for: normalizedID)
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
                    || record.tags.contains(where: { $0.lowercased().contains(needle) })
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

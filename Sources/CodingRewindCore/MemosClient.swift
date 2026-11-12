// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public struct MemoWireDTO: Codable, Equatable, Sendable {
    public let name: String
    public let content: String
    public let createTime: String?
    public let updateTime: String?
}

private struct ListMemosResponseDTO: Codable {
    let memos: [MemoWireDTO]?
}

private struct CreateMemoRequestDTO: Codable {
    let content: String
    let visibility: String
}

private struct UpdateMemoRequestDTO: Codable {
    let content: String
}

public struct MemosClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func createClip(
        clientClipId: String,
        content: String,
        contextComment: String?,
        baseURL: URL,
        token: String,
        fallbackCreatedAt: Date = Date()
    ) async throws -> RewindCard {
        guard MemosWireFormat.isValidMemoID(clientClipId) else {
            throw RewindError.invalidClipID(clientClipId)
        }

        let createURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos",
            queryItems: [URLQueryItem(name: "memoId", value: clientClipId)]
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        let createBody = try jsonEncoder.encode(CreateMemoRequestDTO(content: content, visibility: "PRIVATE"))
        let (data, status) = try await performRequest(url: createURL, method: "POST", token: token, body: createBody)

        let serverId: String
        let createdDate: Date
        let storedContent: String

        if (200..<300).contains(status) {
            let dto = try JSONDecoder().decode(MemoWireDTO.self, from: data)
            serverId = dto.name.hasPrefix("memos/") ? String(dto.name.dropFirst("memos/".count)) : dto.name
            createdDate = dto.createTime.flatMap(MemosWireFormat.parseISO8601) ?? fallbackCreatedAt
            storedContent = dto.content
        } else if status == 409 {
            serverId = clientClipId
            createdDate = fallbackCreatedAt
            storedContent = content
        } else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }

        if let comment = contextComment, !comment.isEmpty {
            let commentId = "\(clientClipId)-ctx"
            let commentURL = try endpointURL(
                baseURL: baseURL,
                path: "/api/memos/\(serverId)/comments",
                queryItems: [URLQueryItem(name: "commentId", value: commentId)]
            )
            let commentBody = try jsonEncoder.encode(CreateMemoRequestDTO(content: comment, visibility: "PRIVATE"))
            let (cData, cStatus) = try await performRequest(url: commentURL, method: "POST", token: token, body: commentBody)
            if !(200..<300).contains(cStatus) && cStatus != 409 {
                throw RewindError.httpError(statusCode: cStatus, body: String(decoding: cData, as: UTF8.self))
            }
        }

        if let parsed = MemosWireFormat.parseMemo(
            id: serverId,
            rawContent: storedContent,
            createdAt: createdDate,
            now: max(Date(), createdDate)
        ) {
            return parsed
        }
        return RewindCard(
            id: serverId,
            rawContent: storedContent,
            status: .pending,
            sourcePlatform: "macos",
            sourceTitle: "macOS",
            verbatimText: storedContent,
            createdAt: createdDate
        )
    }

    public func listHotClips(
        baseURL: URL,
        token: String,
        now: Date = Date()
    ) async throws -> [RewindCard] {
        let listURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos",
            queryItems: [URLQueryItem(name: "pageSize", value: "100")]
        )
        let (data, status) = try await performRequest(url: listURL, method: "GET", token: token, body: nil)
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ListMemosResponseDTO.self, from: data)
        let cards = (decoded.memos ?? []).compactMap { dto -> RewindCard? in
            guard let created = dto.createTime.flatMap(MemosWireFormat.parseISO8601) else {
                return nil
            }
            return MemosWireFormat.parseMemo(
                id: dto.name,
                rawContent: dto.content,
                createdAt: created,
                now: now
            )
        }
        return cards.sorted { $0.createdAt > $1.createdAt }
    }

    public func markSynthesized(
        card: RewindCard,
        baseURL: URL,
        token: String
    ) async throws {
        let patchURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos/\(card.id)",
            queryItems: [URLQueryItem(name: "updateMask", value: "content")]
        )
        let updated = MemosWireFormat.replacingWithSynthesizedTag(card.rawContent)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try jsonEncoder.encode(UpdateMemoRequestDTO(content: updated))
        let (data, status) = try await performRequest(url: patchURL, method: "PATCH", token: token, body: body)
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
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

    private func endpointURL(baseURL: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let baseStr = Self.normalizeBaseURLString(baseURL.absoluteString)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: baseStr + normalizedPath) else {
            throw RewindError.invalidMemosURL(baseURL.absoluteString)
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw RewindError.invalidMemosURL(baseURL.absoluteString)
        }
        return finalURL
    }

    private func performRequest(
        url: URL,
        method: String,
        token: String,
        body: Data?
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RewindError.ioError("Non-HTTP response")
        }
        return (data, http.statusCode)
    }
}

public struct OutboxEntry: Codable, Equatable, Sendable {
    public let clientClipId: String
    public let memoContent: String
    public let commentContent: String?
    public let createdAt: Date

    public init(clientClipId: String, memoContent: String, commentContent: String?, createdAt: Date = Date()) {
        self.clientClipId = clientClipId
        self.memoContent = memoContent
        self.commentContent = commentContent
        self.createdAt = createdAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clientClipId == rhs.clientClipId &&
        lhs.createdAt == rhs.createdAt &&
        lhs.memoContent.utf8.elementsEqual(rhs.memoContent.utf8) &&
        lhs.commentContent.map { Data($0.utf8) } == rhs.commentContent.map { Data($0.utf8) }
    }
}

public struct OfflineOutbox: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func loadEntries() -> [OutboxEntry] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(OutboxEntry.self, from: Data(line.utf8))
            }
    }

    public func enqueue(_ entry: OutboxEntry) throws {
        try withFileLock {
            var existing = loadEntries()
            if let idx = existing.firstIndex(where: { $0.clientClipId == entry.clientClipId }) {
                existing[idx] = entry
            } else {
                existing.append(entry)
            }
            try writeEntries(existing)
        }
    }

    @discardableResult
    public func flush(
        using client: MemosClient,
        baseURL: URL,
        token: String
    ) async throws -> (flushed: [RewindCard], remaining: [OutboxEntry]) {
        let entries = loadEntries()
        guard !entries.isEmpty else { return ([], []) }

        var flushed: [RewindCard] = []
        var sentEntries: [String: OutboxEntry] = [:]

        for entry in entries {
            do {
                let saved = try await client.createClip(
                    clientClipId: entry.clientClipId,
                    content: entry.memoContent,
                    contextComment: entry.commentContent,
                    baseURL: baseURL,
                    token: token,
                    fallbackCreatedAt: entry.createdAt
                )
                flushed.append(saved)
                sentEntries[entry.clientClipId] = entry
            } catch {
                continue
            }
        }

        let remaining = try withFileLock {
            let current = loadEntries()
            let remaining = current.filter { sentEntries[$0.clientClipId] != $0 }
            if remaining.count != current.count {
                try writeEntries(remaining)
            }
            return remaining
        }
        return (flushed, remaining)
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic writes replace the queue inode, so every writer locks a separate stable file.
        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RewindError.ioError("open(\(lockURL.lastPathComponent)) errno=\(errno)")
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw RewindError.ioError("flock errno=\(errno)")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    private func writeEntries(_ entries: [OutboxEntry]) throws {
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try entries.map { entry -> String in
            let lineData = try encoder.encode(entry)
            return String(decoding: lineData, as: UTF8.self)
        }
        try AtomicFile.writeUTF8(lines.joined(separator: "\n") + "\n", to: fileURL, permissions: 0o600)
    }
}

public struct HotCache: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func loadCards(now: Date = Date()) -> [RewindCard] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cards = try? decoder.decode([RewindCard].self, from: data) else {
            return []
        }
        return hotCards(cards, now: now)
    }

    public func saveCards(_ cards: [RewindCard], now: Date = Date()) throws {
        let hot = hotCards(cards, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(hot)
        try AtomicFile.writeData(data, to: fileURL, permissions: 0o600)
    }

    private func hotCards(_ cards: [RewindCard], now: Date) -> [RewindCard] {
        cards.compactMap { card in
            MemosWireFormat.parseMemo(
                id: card.id,
                rawContent: card.rawContent,
                createdAt: card.createdAt,
                now: now,
                isOfflinePending: card.isOfflinePending
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

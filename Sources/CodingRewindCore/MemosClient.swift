// SPDX-License-Identifier: MIT

import Foundation

public struct MemoWireDTO: Codable, Equatable, Sendable {
    public let name: String
    public let content: String
    public let createTime: String?
    public let updateTime: String?

    enum CodingKeys: String, CodingKey {
        case name
        case content
        case createTime
        case updateTime
    }

    public init(name: String, content: String, createTime: String? = nil, updateTime: String? = nil) {
        self.name = name
        self.content = content
        self.createTime = createTime
        self.updateTime = updateTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        self.updateTime = try container.decodeIfPresent(String.self, forKey: .updateTime)
    }
}

private struct ListMemosResponseDTO: Codable {
    let memos: [MemoWireDTO]?
    let nextPageToken: String?
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
            serverId = Self.parseServerMemoID(from: dto.name) ?? (dto.name.isEmpty ? clientClipId : dto.name)
            createdDate = dto.createTime.flatMap(MemosWireFormat.parseISO8601) ?? fallbackCreatedAt
            storedContent = dto.content.isEmpty ? content : dto.content
        } else if status == 409 {
            let existing = await resolveExistingMemo(
                clientClipId: clientClipId,
                baseURL: baseURL,
                token: token
            )
            serverId = existing?.serverId ?? clientClipId
            createdDate = existing?.createTime ?? fallbackCreatedAt
            storedContent = existing?.content ?? content
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
            now: createdDate
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
        var pageToken: String?
        var cardsByID: [String: RewindCard] = [:]
        repeat {
            var queryItems = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let listURL = try endpointURL(baseURL: baseURL, path: "/api/memos", queryItems: queryItems)
            let (data, status) = try await performRequest(url: listURL, method: "GET", token: token, body: nil)
            guard (200..<300).contains(status) else {
                throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
            }
            let decoded = try JSONDecoder().decode(ListMemosResponseDTO.self, from: data)
            for dto in decoded.memos ?? [] {
                guard let created = dto.createTime.flatMap(MemosWireFormat.parseISO8601),
                      let card = MemosWireFormat.parseMemo(id: dto.name, rawContent: dto.content, createdAt: created, now: now) else {
                    continue
                }
                cardsByID[card.id] = card
            }
            pageToken = decoded.nextPageToken
        } while pageToken?.isEmpty == false
        return cardsByID.values.sorted { $0.createdAt > $1.createdAt }
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

    private static func parseServerMemoID(from resourceName: String) -> String? {
        guard resourceName.hasPrefix("memos/") else { return nil }
        let id = String(resourceName.dropFirst("memos/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    private func resolveExistingMemo(
        clientClipId: String,
        baseURL: URL,
        token: String
    ) async -> (serverId: String, createTime: Date?, content: String?)? {
        guard let getURL = try? endpointURL(
            baseURL: baseURL,
            path: "/api/memos/\(clientClipId)",
            queryItems: []
        ),
        let (data, status) = try? await performRequest(url: getURL, method: "GET", token: token, body: nil),
        (200..<300).contains(status),
        let dto = try? JSONDecoder().decode(MemoWireDTO.self, from: data),
        let serverId = Self.parseServerMemoID(from: dto.name) ?? (dto.name.isEmpty ? nil : dto.name) else {
            return nil
        }
        return (
            serverId: serverId,
            createTime: dto.createTime.flatMap(MemosWireFormat.parseISO8601),
            content: dto.content.isEmpty ? nil : dto.content
        )
    }

    private func endpointURL(baseURL: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let baseStr = MemosWireFormat.normalizeBaseURLString(baseURL.absoluteString)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: baseStr + normalizedPath) else {
            throw RewindError.invalidMemosURL(baseURL.absoluteString)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
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

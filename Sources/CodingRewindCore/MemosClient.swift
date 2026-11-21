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

private struct CommentItemWireDTO: Codable {
    let name: String
    let content: String
    let createTime: String?
    let updateTime: String?

    enum CodingKeys: String, CodingKey {
        case name
        case content
        case createTime
        case updateTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        self.updateTime = try container.decodeIfPresent(String.self, forKey: .updateTime)
    }

    var memoDTO: MemoWireDTO {
        MemoWireDTO(name: name, content: content, createTime: createTime, updateTime: updateTime)
    }
}

private struct ListCommentsResponseDTO: Codable {
    let memos: [CommentItemWireDTO]?
    let comments: [CommentItemWireDTO]?
    let nextPageToken: String?
}

private struct CreateMemoRequestDTO: Codable {
    let content: String
    let visibility: String
}

private struct UpdateMemoRequestDTO: Codable {
    let content: String
}

private final class MemosRedirectGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = MemosRedirectGuardDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let nextURL = request.url,
              MemosWireFormat.isAllowedMemosBaseURL(nextURL) else {
            completionHandler(nil)
            return
        }
        var forwarded = request
        if let originalURL = task.originalRequest?.url {
            let sameOrigin = originalURL.scheme?.lowercased() == nextURL.scheme?.lowercased()
                && originalURL.host?.lowercased() == nextURL.host?.lowercased()
                && originalURL.port == nextURL.port
            if !sameOrigin {
                forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
            }
        } else {
            forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(forwarded)
    }
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

        let encodedServerID = try Self.encodedMemoPathComponent(from: serverId)
        if let comment = contextComment, !comment.isEmpty {
            let commentId = "\(clientClipId)-ctx"
            let commentURL = try endpointURL(
                baseURL: baseURL,
                path: "/api/memos/\(encodedServerID)/comments",
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

    /// Returns nil when a memo with `memoID` already exists.
    public func createMemo(
        memoID: String,
        content: String,
        baseURL: URL,
        token: String
    ) async throws -> MemoWireDTO? {
        guard MemosWireFormat.isValidMemoID(memoID) else {
            throw RewindError.invalidClipID(memoID)
        }
        let createURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos",
            queryItems: [URLQueryItem(name: "memoId", value: memoID)]
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try jsonEncoder.encode(CreateMemoRequestDTO(content: content, visibility: "PRIVATE"))
        let (data, status) = try await performCheckedRequest(url: createURL, method: "POST", token: token, body: body)
        if status == 409 {
            return nil
        }
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try? JSONDecoder().decode(MemoWireDTO.self, from: data)
        return MemoWireDTO(
            name: decoded?.name.isEmpty == false ? decoded!.name : "memos/\(memoID)",
            content: decoded?.content.isEmpty == false ? decoded!.content : content,
            createTime: decoded?.createTime,
            updateTime: decoded?.updateTime
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
        return cardsByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Probes the list endpoint with one record to confirm the URL, token and response shape.
    public func verifyConnection(baseURL: URL, token: String) async throws {
        let probeURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos",
            queryItems: [URLQueryItem(name: "pageSize", value: "1")]
        )
        let data: Data
        let status: Int
        do {
            (data, status) = try await performRequest(url: probeURL, method: "GET", token: token, body: nil)
        } catch let error as URLError {
            throw RewindError.networkFailure(error.localizedDescription)
        }
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        guard (try? JSONDecoder().decode(ListMemosResponseDTO.self, from: data)) != nil else {
            throw RewindError.invalidServerResponse
        }
    }

    public func markSynthesized(
        card: RewindCard,
        baseURL: URL,
        token: String
    ) async throws {
        let updated = MemosWireFormat.replacingWithSynthesizedTag(card.rawContent)
        _ = try await updateMemoContent(
            id: card.id,
            content: updated,
            baseURL: baseURL,
            token: token
        )
    }

    public func listAllMemos(
        baseURL: URL,
        token: String,
        pageSize: Int = 100
    ) async throws -> [MemoWireDTO] {
        let clampedPageSize = min(max(pageSize, 1), 500)
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var allMemos: [MemoWireDTO] = []

        repeat {
            var queryItems = [URLQueryItem(name: "pageSize", value: String(clampedPageSize))]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let listURL = try endpointURL(baseURL: baseURL, path: "/api/memos", queryItems: queryItems)
            let (data, status) = try await performCheckedRequest(url: listURL, method: "GET", token: token, body: nil)
            guard (200..<300).contains(status) else {
                throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
            }
            let decoded: ListMemosResponseDTO
            do {
                decoded = try JSONDecoder().decode(ListMemosResponseDTO.self, from: data)
            } catch {
                throw RewindError.invalidServerResponse
            }
            if let pageMemos = decoded.memos {
                allMemos.append(contentsOf: pageMemos)
            }
            if let next = decoded.nextPageToken, !next.isEmpty {
                guard seenPageTokens.insert(next).inserted else {
                    throw RewindError.invalidServerResponse
                }
                pageToken = next
            } else {
                pageToken = nil
            }
        } while pageToken != nil

        return allMemos
    }

    public func getMemo(
        id: String,
        baseURL: URL,
        token: String
    ) async throws -> MemoWireDTO {
        let encodedID = try Self.encodedMemoPathComponent(from: id)
        let getURL = try endpointURL(baseURL: baseURL, path: "/api/memos/\(encodedID)", queryItems: [])
        let (data, status) = try await performCheckedRequest(url: getURL, method: "GET", token: token, body: nil)
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(MemoWireDTO.self, from: data)
        } catch {
            throw RewindError.invalidServerResponse
        }
    }

    public func listMemoComments(
        id: String,
        baseURL: URL,
        token: String,
        pageSize: Int = 100
    ) async throws -> [MemoWireDTO] {
        let encodedID = try Self.encodedMemoPathComponent(from: id)
        let clampedPageSize = min(max(pageSize, 1), 500)
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        var allComments: [MemoWireDTO] = []

        repeat {
            var queryItems = [URLQueryItem(name: "pageSize", value: String(clampedPageSize))]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let commentsURL = try endpointURL(
                baseURL: baseURL,
                path: "/api/memos/\(encodedID)/comments",
                queryItems: queryItems
            )
            let (data, status) = try await performCheckedRequest(url: commentsURL, method: "GET", token: token, body: nil)
            guard (200..<300).contains(status) else {
                throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
            }
            let decoded: ListCommentsResponseDTO
            do {
                decoded = try JSONDecoder().decode(ListCommentsResponseDTO.self, from: data)
            } catch {
                throw RewindError.invalidServerResponse
            }
            let items = decoded.memos ?? decoded.comments ?? []
            allComments.append(contentsOf: items.map(\.memoDTO))
            if let next = decoded.nextPageToken, !next.isEmpty {
                guard seenPageTokens.insert(next).inserted else {
                    throw RewindError.invalidServerResponse
                }
                pageToken = next
            } else {
                pageToken = nil
            }
        } while pageToken != nil

        return allComments
    }

    @discardableResult
    public func postMemoComment(
        memoID: String,
        commentID: String,
        content: String,
        baseURL: URL,
        token: String
    ) async throws -> MemoWireDTO {
        guard MemosWireFormat.isValidMemoID(commentID) else {
            throw RewindError.invalidClipID(commentID)
        }
        let encodedID = try Self.encodedMemoPathComponent(from: memoID)
        let commentURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos/\(encodedID)/comments",
            queryItems: [URLQueryItem(name: "commentId", value: commentID)]
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try jsonEncoder.encode(CreateMemoRequestDTO(content: content, visibility: "PRIVATE"))
        let (data, status) = try await performCheckedRequest(url: commentURL, method: "POST", token: token, body: body)
        if (200..<300).contains(status) {
            if let decoded = try? JSONDecoder().decode(CommentItemWireDTO.self, from: data) {
                let effectiveName = decoded.name.isEmpty ? "memos/\(commentID)" : decoded.name
                let effectiveContent = decoded.content.isEmpty ? content : decoded.content
                return MemoWireDTO(
                    name: effectiveName,
                    content: effectiveContent,
                    createTime: decoded.createTime,
                    updateTime: decoded.updateTime
                )
            }
            return MemoWireDTO(name: "memos/\(commentID)", content: content)
        }
        if status == 409 {
            return MemoWireDTO(name: "memos/\(commentID)", content: content)
        }
        throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    public func updateMemoContent(
        id: String,
        content: String,
        baseURL: URL,
        token: String
    ) async throws -> MemoWireDTO? {
        let encodedID = try Self.encodedMemoPathComponent(from: id)
        let patchURL = try endpointURL(
            baseURL: baseURL,
            path: "/api/memos/\(encodedID)",
            queryItems: [URLQueryItem(name: "updateMask", value: "content")]
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try jsonEncoder.encode(UpdateMemoRequestDTO(content: content))
        let (data, status) = try await performCheckedRequest(url: patchURL, method: "PATCH", token: token, body: body)
        guard (200..<300).contains(status) else {
            throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        return try? JSONDecoder().decode(MemoWireDTO.self, from: data)
    }

    @discardableResult
    public func deleteMemo(
        id: String,
        baseURL: URL,
        token: String
    ) async throws -> Bool {
        let encodedID = try Self.encodedMemoPathComponent(from: id)
        let deleteURL = try endpointURL(baseURL: baseURL, path: "/api/memos/\(encodedID)", queryItems: [])
        let (data, status) = try await performCheckedRequest(url: deleteURL, method: "DELETE", token: token, body: nil)
        if (200..<300).contains(status) {
            return true
        }
        if status == 404 {
            return false
        }
        throw RewindError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
    }

    private func performCheckedRequest(
        url: URL,
        method: String,
        token: String,
        body: Data?
    ) async throws -> (Data, Int) {
        do {
            return try await performRequest(url: url, method: method, token: token, body: body)
        } catch let error as URLError {
            throw RewindError.networkFailure(error.localizedDescription)
        }
    }

    private static func encodedMemoPathComponent(from rawID: String) throws -> String {
        let normalized = try MemosWireFormat.normalizeSnippetID(rawID)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw RewindError.invalidClipID(rawID)
        }
        return encoded
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
        guard MemosWireFormat.isAllowedMemosBaseURL(baseURL) else {
            throw RewindError.invalidMemosURL(baseURL.absoluteString)
        }
        let baseStr = MemosWireFormat.normalizeBaseURLString(baseURL.absoluteString)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: baseStr + normalizedPath) else {
            throw RewindError.invalidMemosURL(baseURL.absoluteString)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url,
              MemosWireFormat.isAllowedMemosBaseURL(finalURL) else {
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
        let (data, response) = try await session.data(for: request, delegate: MemosRedirectGuardDelegate.shared)
        guard let http = response as? HTTPURLResponse else {
            throw RewindError.ioError("Non-HTTP response")
        }
        return (data, http.statusCode)
    }
}

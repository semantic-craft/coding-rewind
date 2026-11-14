// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Security

public enum AtomicFile {
    public static func writeData(_ data: Data, to destinationURL: URL, permissions: mode_t = 0o600) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY, permissions)
        guard fd >= 0 else {
            throw RewindError.ioError("open(\(tempURL.lastPathComponent)) errno=\(errno)")
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                var offset = 0
                while remaining > 0 {
                    let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw RewindError.ioError("write errno=\(errno)")
                    }
                    remaining -= written
                    offset += written
                }
            }
            _ = fchmod(fd, permissions)
            close(fd)
        } catch {
            close(fd)
            unlink(tempURL.path)
            throw error
        }
        if rename(tempURL.path, destinationURL.path) != 0 {
            let code = errno
            unlink(tempURL.path)
            throw RewindError.ioError("rename errno=\(code)")
        }
    }

    public static func writeUTF8(_ text: String, to destinationURL: URL, permissions: mode_t = 0o600) throws {
        try writeData(Data(text.utf8), to: destinationURL, permissions: permissions)
    }
}

public struct StoragePaths: Equatable, Sendable {
    public static let dataDirEnvironmentKey = "CODING_REWIND_DATA_DIR"
    public static let memosURLEnvironmentKey = "CODING_REWIND_MEMOS_URL"
    public static let memosTokenEnvironmentKey = "CODING_REWIND_MEMOS_TOKEN"
    public static let qaEnvironmentKey = "CODING_REWIND_QA"
    public static let antigravityConfigEnvironmentKey = "CODING_REWIND_ANTIGRAVITY_CONFIG"

    public let dataDirectoryURL: URL
    public let antigravityConfigDirectoryURL: URL

    public var configFileURL: URL { dataDirectoryURL.appendingPathComponent("config.json", isDirectory: false) }
    public var outboxFileURL: URL { dataDirectoryURL.appendingPathComponent("outbox.jsonl", isDirectory: false) }
    public var hotCacheFileURL: URL { dataDirectoryURL.appendingPathComponent("hot_cache.json", isDirectory: false) }
    public var binDirectoryURL: URL { dataDirectoryURL.appendingPathComponent("bin", isDirectory: true) }

    public init(dataDirectoryURL: URL, antigravityConfigDirectoryURL: URL? = nil) throws {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let defaultGemini = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        let resolvedConfig = (antigravityConfigDirectoryURL ?? defaultGemini).standardizedFileURL
        try fm.createDirectory(at: resolvedData, withIntermediateDirectories: true)
        self.dataDirectoryURL = resolvedData
        self.antigravityConfigDirectoryURL = resolvedConfig
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StoragePaths {
        let fm = FileManager.default
        let dataURL: URL
        if let raw = environment[dataDirEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            dataURL = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dataURL = appSupport.appendingPathComponent("CodingRewind", isDirectory: true)
        }

        let agConfigURL: URL?
        if let rawConfig = environment[antigravityConfigEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawConfig.isEmpty {
            agConfigURL = URL(fileURLWithPath: (rawConfig as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            agConfigURL = nil
        }
        return try StoragePaths(dataDirectoryURL: dataURL, antigravityConfigDirectoryURL: agConfigURL)
    }

    private struct DiskConfig: Codable {
        var memos_url: String?
    }

    public func readConfiguredMemosURLString(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let envURL = environment[Self.memosURLEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envURL.isEmpty {
            return MemosWireFormat.normalizeBaseURLString(envURL)
        }
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode(DiskConfig.self, from: data),
              let raw = decoded.memos_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return MemosWireFormat.normalizeBaseURLString(raw)
    }

    public func resolveMemosBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = readConfiguredMemosURLString(environment: environment),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    public func saveMemosURLString(_ rawURL: String) throws {
        let trimmedInput = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if trimmedInput.isEmpty {
            normalized = ""
        } else {
            guard let url = URL(string: trimmedInput),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http"),
                  url.host?.isEmpty == false else {
                throw RewindError.invalidMemosURL(rawURL)
            }
            normalized = MemosWireFormat.normalizeBaseURLString(trimmedInput)
        }
        let payload = DiskConfig(memos_url: normalized.isEmpty ? nil : normalized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try AtomicFile.writeData(data, to: configFileURL, permissions: 0o600)
    }
}

public struct ConnectionSettingsState: Equatable, Sendable {
    public let memosURL: String
    public let isURLManaged: Bool
    public let isTokenManaged: Bool

    public init(paths: StoragePaths, environment: [String: String]) {
        memosURL = paths.readConfiguredMemosURLString(environment: environment) ?? ""
        isURLManaged = Self.hasValue(StoragePaths.memosURLEnvironmentKey, in: environment)
        isTokenManaged = Self.hasValue(StoragePaths.memosTokenEnvironmentKey, in: environment)
    }

    private static func hasValue(_ key: String, in environment: [String: String]) -> Bool {
        !(environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public enum KeychainTokenStore {
    public static let defaultService = "com.codingrewind.memos"
    public static let qaService = "com.codingrewind.memos.qa"

    public static func serviceName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if environment[StoragePaths.qaEnvironmentKey] == "1" {
            return qaService
        }
        if let custom = environment["CODING_REWIND_KEYCHAIN_SERVICE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return defaultService
    }

    public static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let envToken = environment[StoragePaths.memosTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return envToken
        }
        let service = serviceName(environment: environment)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public static func saveToken(
        _ rawToken: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let service = serviceName(environment: environment)
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if trimmed.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw RewindError.keychainError(status)
            }
            return
        }
        let tokenData = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: tokenData] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecAttrAccount as String] = "memos"
            addQuery[kSecValueData as String] = tokenData
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RewindError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw RewindError.keychainError(updateStatus)
        }
    }

    public static func deleteToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try saveToken("", environment: environment)
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
    ) async throws -> (flushed: [(clientClipId: String, card: RewindCard)], remaining: [OutboxEntry]) {
        let entries = loadEntries()
        guard !entries.isEmpty else { return ([], []) }

        var flushed: [(clientClipId: String, card: RewindCard)] = []
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
                flushed.append((clientClipId: entry.clientClipId, card: saved))
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

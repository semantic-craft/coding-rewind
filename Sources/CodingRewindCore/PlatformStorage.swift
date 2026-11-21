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
    public static let dshHomeEnvironmentKey = "CODING_REWIND_DSH_HOME"
    public static let aiAccessEnvironmentKey = "CODING_REWIND_AI_ACCESS"

    public let dataDirectoryURL: URL
    public let antigravityConfigDirectoryURL: URL
    public let dshHomeDirectoryURL: URL

    public var configFileURL: URL { dataDirectoryURL.appendingPathComponent("config.json", isDirectory: false) }
    public var outboxFileURL: URL { dataDirectoryURL.appendingPathComponent("outbox.jsonl", isDirectory: false) }
    public var hotCacheFileURL: URL { dataDirectoryURL.appendingPathComponent("hot_cache.json", isDirectory: false) }
    public var localNotesFileURL: URL { dataDirectoryURL.appendingPathComponent("local_notes.json", isDirectory: false) }
    public var binDirectoryURL: URL { dataDirectoryURL.appendingPathComponent("bin", isDirectory: true) }
    public var developerCredentialsFileURL: URL { dataDirectoryURL.appendingPathComponent("DeveloperCredentials.plist", isDirectory: false) }
    public var updatesDirectoryURL: URL { dataDirectoryURL.appendingPathComponent("updates", isDirectory: true) }
    public var dshPluginStagingDirectoryURL: URL {
        dataDirectoryURL
            .appendingPathComponent("dsh-plugin", isDirectory: true)
            .appendingPathComponent("coding-rewind-dsh", isDirectory: true)
    }
    public var dshActiveSessionFileURL: URL {
        dataDirectoryURL.appendingPathComponent("dsh-active-session.json", isDirectory: false)
    }

    public init(
        dataDirectoryURL: URL,
        antigravityConfigDirectoryURL: URL? = nil,
        dshHomeDirectoryURL: URL? = nil
    ) throws {
        let fm = FileManager.default
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let defaultGemini = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        let defaultDSH = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
        let resolvedConfig = (antigravityConfigDirectoryURL ?? defaultGemini).standardizedFileURL
        let resolvedDSHHome = (dshHomeDirectoryURL ?? defaultDSH).standardizedFileURL
        try fm.createDirectory(at: resolvedData, withIntermediateDirectories: true)
        self.dataDirectoryURL = resolvedData
        self.antigravityConfigDirectoryURL = resolvedConfig
        self.dshHomeDirectoryURL = resolvedDSHHome
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

        let dshHomeURL: URL?
        if let rawDSH = environment[dshHomeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDSH.isEmpty {
            dshHomeURL = URL(fileURLWithPath: (rawDSH as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dshHomeURL = nil
        }

        return try StoragePaths(
            dataDirectoryURL: dataURL,
            antigravityConfigDirectoryURL: agConfigURL,
            dshHomeDirectoryURL: dshHomeURL
        )
    }

    private struct DiskConfig: Codable {
        var memos_url: String?
        var ai_access_mode: String?
    }

    private struct MCPServerEntryDTO: Encodable {
        let command: String
        let args: [String]
    }

    private struct MCPClientConfigurationDTO: Encodable {
        let mcpServers: [String: MCPServerEntryDTO]
    }

    private func readDiskConfig() -> (config: DiskConfig, forceReadOnlyOnInvalidConfig: Bool) {
        var st = stat()
        if lstat(configFileURL.path, &st) != 0 {
            if errno == ENOENT {
                return (DiskConfig(memos_url: nil, ai_access_mode: nil), false)
            }
            return (DiskConfig(memos_url: nil, ai_access_mode: AIAccessMode.readOnly.rawValue), true)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: configFileURL),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let dict = rawObject as? [String: Any] else {
            return (DiskConfig(memos_url: nil, ai_access_mode: AIAccessMode.readOnly.rawValue), true)
        }
        let memosURL = dict["memos_url"] as? String
        if let rawAccess = dict["ai_access_mode"], !(rawAccess is NSNull) {
            guard let accessStr = rawAccess as? String,
                  let parsedMode = Self.parseAIAccessMode(accessStr) else {
                return (DiskConfig(memos_url: memosURL, ai_access_mode: AIAccessMode.readOnly.rawValue), true)
            }
            return (DiskConfig(memos_url: memosURL, ai_access_mode: parsedMode.rawValue), false)
        }
        return (DiskConfig(memos_url: memosURL, ai_access_mode: nil), false)
    }

    private func updateDiskConfig(_ mutate: (inout DiskConfig) -> Void) throws {
        try FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = configFileURL.appendingPathExtension("lock")
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

        var disk = readDiskConfig().config
        mutate(&disk)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(disk)
        try AtomicFile.writeData(data, to: configFileURL, permissions: 0o600)
    }

    public func readConfiguredMemosURLString(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let envURL = environment[Self.memosURLEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envURL.isEmpty {
            return MemosWireFormat.normalizeBaseURLString(envURL)
        }
        guard let raw = readDiskConfig().config.memos_url?.trimmingCharacters(in: .whitespacesAndNewlines),
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
              MemosWireFormat.isAllowedMemosBaseURL(url) else {
            return nil
        }
        return url
    }

    /// Returns the normalized https (or loopback http) base URL for typed input, or nil when it is not a usable address.
    public static func normalizedMemosBaseURL(from rawURL: String) -> URL? {
        let trimmedInput = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let initialURL = URL(string: trimmedInput),
              MemosWireFormat.isAllowedMemosBaseURL(initialURL),
              let normalizedURL = URL(string: MemosWireFormat.normalizeBaseURLString(trimmedInput)),
              MemosWireFormat.isAllowedMemosBaseURL(normalizedURL) else {
            return nil
        }
        return normalizedURL
    }

    public func saveMemosURLString(_ rawURL: String) throws {
        let trimmedInput = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if trimmedInput.isEmpty {
            normalized = ""
        } else {
            guard Self.normalizedMemosBaseURL(from: trimmedInput) != nil else {
                throw RewindError.invalidMemosURL(rawURL)
            }
            normalized = MemosWireFormat.normalizeBaseURLString(trimmedInput)
        }
        try updateDiskConfig { disk in
            disk.memos_url = normalized.isEmpty ? nil : normalized
        }
    }

    public static func parseAIAccessMode(_ raw: String) -> AIAccessMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read_only", "readonly", "read-only":
            return .readOnly
        case "read_write", "readwrite", "read-write":
            return .readWrite
        default:
            return nil
        }
    }

    public func isAIAccessManagedByEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !(environment[Self.aiAccessEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public func resolveAIAccessMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIAccessMode {
        if let envRaw = environment[Self.aiAccessEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envRaw.isEmpty {
            return Self.parseAIAccessMode(envRaw) ?? .readOnly
        }
        let (disk, forceReadOnly) = readDiskConfig()
        if forceReadOnly {
            return .readOnly
        }
        if let diskRaw = disk.ai_access_mode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !diskRaw.isEmpty {
            return Self.parseAIAccessMode(diskRaw) ?? .readOnly
        }
        return .readWrite
    }

    public func saveAIAccessMode(_ mode: AIAccessMode) throws {
        try updateDiskConfig { disk in
            disk.ai_access_mode = mode.rawValue
        }
    }

    public static func standardMCPConfigurationJSON(
        executablePath: String = "${HOME}/Library/Application Support/CodingRewind/bin/coding-rewind"
    ) -> String {
        let payload = MCPClientConfigurationDTO(
            mcpServers: [
                "coding-rewind": MCPServerEntryDTO(command: executablePath, args: ["mcp"])
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ConnectionSettingsState: Equatable, Sendable {
    public let memosURL: String
    public let isURLManaged: Bool
    public let isTokenManaged: Bool
    /// True when an access token exists, from the environment or the Keychain. The token itself is never read.
    public let hasSavedToken: Bool

    public init(paths: StoragePaths, environment: [String: String]) {
        memosURL = paths.readConfiguredMemosURLString(environment: environment) ?? ""
        isURLManaged = Self.hasValue(StoragePaths.memosURLEnvironmentKey, in: environment)
        isTokenManaged = Self.hasValue(StoragePaths.memosTokenEnvironmentKey, in: environment)
        hasSavedToken = KeychainTokenStore.hasToken(environment: environment)
    }

    private static func hasValue(_ key: String, in environment: [String: String]) -> Bool {
        !(environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public enum KeychainTokenStore {
    public static let defaultService = "com.codingrewind.memos"
    public static let qaService = "com.codingrewind.memos.qa"
    public static let disableKeychainFallbackEnvironmentKey = "CODING_REWIND_DISABLE_KEYCHAIN_FALLBACK"

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
        if environment[disableKeychainFallbackEnvironmentKey] == "1" {
            return nil
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

    /// Checks that a token exists without reading its data, so the system never asks for Keychain access.
    public static func hasToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let envToken = environment[StoragePaths.memosTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return true
        }
        if environment[disableKeychainFallbackEnvironmentKey] == "1" {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(environment: environment),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
    public func removeEntry(clientClipId: String) throws -> Bool {
        try withFileLock {
            let current = loadEntries()
            let remaining = current.filter { $0.clientClipId != clientClipId }
            let removed = remaining.count != current.count
            if removed {
                try writeEntries(remaining)
            }
            return removed
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

    public func upsertCard(_ card: RewindCard, now: Date = Date()) throws {
        var existing = loadCards(now: now).filter { $0.id != card.id }
        existing.insert(card, at: 0)
        try saveCards(existing, now: now)
    }

    @discardableResult
    public func removeCard(id: String) throws -> Bool {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cards = try? decoder.decode([RewindCard].self, from: data) else { return false }
        let remaining = cards.filter { $0.id != id }
        let removed = remaining.count != cards.count
        guard removed else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(remaining)
        try AtomicFile.writeData(encoded, to: fileURL, permissions: 0o600)
        return true
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

public struct LocalNotesStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func loadNotes(for snippetID: String) -> [SnippetNote] {
        guard let normalized = try? MemosWireFormat.normalizeSnippetID(snippetID) else {
            return []
        }
        let all = loadAll()
        return Self.sortAndDeduplicate(all[normalized] ?? [])
    }

    public func appendNote(_ note: SnippetNote, for snippetID: String) throws {
        let normalized = try MemosWireFormat.normalizeSnippetID(snippetID)
        try withFileLock {
            var all = loadAll()
            var list = all[normalized] ?? []
            if let idx = list.firstIndex(where: { $0.id == note.id }) {
                list[idx] = note
            } else {
                list.append(note)
            }
            all[normalized] = Self.sortAndDeduplicate(list)
            try writeAll(all)
        }
    }

    @discardableResult
    public func removeNotes(for snippetID: String) throws -> Bool {
        let normalized = try MemosWireFormat.normalizeSnippetID(snippetID)
        return try withFileLock {
            var all = loadAll()
            let removed = all.removeValue(forKey: normalized) != nil
            if removed {
                try writeAll(all)
            }
            return removed
        }
    }

    public func remapCardID(from oldID: String, to newID: String) throws {
        let normalizedOld = try MemosWireFormat.normalizeSnippetID(oldID)
        let normalizedNew = try MemosWireFormat.normalizeSnippetID(newID)
        guard normalizedOld != normalizedNew else { return }
        try withFileLock {
            var all = loadAll()
            guard let oldNotes = all.removeValue(forKey: normalizedOld) else { return }
            let existingNew = all[normalizedNew] ?? []
            all[normalizedNew] = Self.sortAndDeduplicate(existingNew + oldNotes)
            try writeAll(all)
        }
    }

    public static func sortAndDeduplicate(_ notes: [SnippetNote]) -> [SnippetNote] {
        var byID: [String: SnippetNote] = [:]
        for note in notes {
            byID[note.id] = note
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private func loadAll() -> [String: [SnippetNote]] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [SnippetNote]].self, from: data)) ?? [:]
    }

    private func writeAll(_ map: [String: [SnippetNote]]) throws {
        if map.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(map)
        try AtomicFile.writeData(data, to: fileURL, permissions: 0o600)
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
}

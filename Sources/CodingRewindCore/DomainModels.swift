// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Security

public enum RewindError: Error, LocalizedError, Equatable, Sendable {
    case emptySelection
    case accessibilityPermissionDenied
    case noFrontmostApplication
    case invalidClipID(String)
    case invalidMemosURL(String)
    case missingCredentials
    case httpError(statusCode: Int, body: String)
    case ioError(String)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "未选中非空文本，请先高亮内容再按快捷键。"
        case .accessibilityPermissionDenied:
            return "未获得辅助功能权限，请在系统设置中授权 CodingRewind。"
        case .noFrontmostApplication:
            return "未检测到前台应用窗口。"
        case .invalidClipID(let id):
            return "无效片段标识: \(id)"
        case .invalidMemosURL(let raw):
            return "无效的 Memos 地址: \(raw)"
        case .missingCredentials:
            return "尚未配置 Memos 地址或访问令牌，已暂存至本地离线队列。"
        case .httpError(let code, let body):
            return "Memos 请求失败 (HTTP \(code)): \(body.prefix(120))"
        case .ioError(let detail):
            return "本地读写失败: \(detail)"
        case .keychainError(let status):
            return "钥匙串访问失败 (OSStatus \(status))"
        }
    }
}

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
            return MemosClient.normalizeBaseURLString(envURL)
        }
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode(DiskConfig.self, from: data),
              let raw = decoded.memos_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return MemosClient.normalizeBaseURLString(raw)
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
            normalized = MemosClient.normalizeBaseURLString(trimmedInput)
        }
        let payload = DiskConfig(memos_url: normalized.isEmpty ? nil : normalized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try AtomicFile.writeData(data, to: configFileURL, permissions: 0o600)
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

public struct ConversationTurn: Codable, Equatable, Hashable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CaptureContext: Codable, Equatable, Hashable, Sendable {
    public let sessionTitle: String
    public let prompt: String
    public let recentTurns: [ConversationTurn]

    public init(sessionTitle: String, prompt: String, recentTurns: [ConversationTurn] = []) {
        self.sessionTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.recentTurns = recentTurns.filter { !$0.text.isEmpty }
    }

    public var isEmpty: Bool {
        sessionTitle.isEmpty && prompt.isEmpty && recentTurns.isEmpty
    }

    public func formattedCommentMarkdown() -> String {
        let turnsBlock = recentTurns
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n")
        return "<!-- rewind-context-v1 -->\nSession Title: \(sessionTitle)\nPrompt: \(prompt)\n\n### Recent Turns\n\(turnsBlock)"
    }
}

public struct CapturedSelection: Equatable, Sendable {
    public static let antigravityBundleIdentifier = "com.google.antigravity"

    public let text: String
    public let bundleIdentifier: String
    public let appName: String
    public let windowTitle: String?
    public let documentURL: String?
    public let antigravityConversationID: AntigravityConversationID?
    public let nativeChat: NativeChatCapture?
    public let capturedAt: Date

    public init(
        text: String,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil,
        documentURL: String? = nil,
        antigravityConversationID: AntigravityConversationID? = nil,
        nativeChat: NativeChatCapture? = nil,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.antigravityConversationID = antigravityConversationID
        self.nativeChat = nativeChat
        self.capturedAt = capturedAt
    }
}

public enum CardStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case ready

    public var badgeText: String {
        switch self {
        case .pending: return "待分析"
        case .ready: return "AI 已定锚"
        }
    }
}

public struct RewindCard: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let hotWindowSeconds: TimeInterval = 72 * 3600

    public let id: String
    public let rawContent: String
    public let status: CardStatus
    public let sourcePlatform: String
    public let title: String?
    public let sessionTopic: String?
    public let contextSummary: String?
    public let keywords: [String]
    public let sourceTitle: String
    public let sourceURL: String?
    public let verbatimText: String
    public let createdAt: Date
    public var isOfflinePending: Bool

    public init(
        id: String,
        rawContent: String,
        status: CardStatus,
        sourcePlatform: String,
        title: String? = nil,
        sessionTopic: String? = nil,
        contextSummary: String? = nil,
        keywords: [String] = [],
        sourceTitle: String,
        sourceURL: String? = nil,
        verbatimText: String,
        createdAt: Date,
        isOfflinePending: Bool = false
    ) {
        self.id = id
        self.rawContent = rawContent
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
        self.isOfflinePending = isOfflinePending
    }

    public var reopenURL: URL? {
        guard let sourceURL, let url = URL(string: sourceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "conversation" else {
            return nil
        }
        return url
    }
}

public enum MemosWireFormat {
    public static func makeClientClipID(now: Date = Date()) -> String {
        let epoch = max(0, Int(now.timeIntervalSince1970))
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        return "rw-\(epoch)-\(suffix)"
    }

    public static func isValidMemoID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty && bytes.count <= 36 else { return false }
        let isAlphaNum: (UInt8) -> Bool = { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        guard isAlphaNum(bytes[0]), isAlphaNum(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { isAlphaNum($0) || $0 == 0x2D }
    }

    public static func inferWebPlatform(urlString: String?, title: String?) -> String {
        let host = urlString.flatMap(URL.init(string:))?.host?.lowercased() ?? ""
        let loweredTitle = title?.lowercased() ?? ""
        if host.contains("chatgpt.com") || host.contains("openai.com") || loweredTitle.contains("chatgpt") {
            return "chatgpt"
        }
        if host.contains("claude.ai") || loweredTitle.contains("claude") {
            return "claude"
        }
        if host.contains("gemini.google.com") || loweredTitle.contains("gemini") {
            return "gemini"
        }
        return "macos"
    }

    public static func formatISO8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    public static func formatRawMemoContent(
        verbatimText: String,
        sourcePlatform: String,
        sourceTitle: String,
        sourceURL: String?,
        capturedAt: Date,
        hasContext: Bool
    ) throws -> String {
        let cleanedBody = verbatimText.replacingOccurrences(of: "\0", with: "")
        guard !cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        let safePlatform = sourcePlatform.isEmpty ? "macos" : sourcePlatform
        let tags = hasContext
            ? "#rewind/pending #rewind/has-ctx #source/\(safePlatform)"
            : "#rewind/pending #source/\(safePlatform)"
        let safeTitle = (sourceTitle.isEmpty ? safePlatform : sourceTitle)
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
        let targetLink = (sourceURL?.isEmpty == false) ? (sourceURL ?? "") : "macos://\(safePlatform)"
        let iso = formatISO8601UTC(capturedAt)
        return "\(tags)\n\n> **Source:** [\(safeTitle)](\(targetLink)) · \(iso)\n\n\(cleanedBody)"
    }

    public static func replacingWithSynthesizedTag(_ rawContent: String) -> String {
        let headerEnd = rawContent.firstIndex(where: \.isNewline) ?? rawContent.endIndex
        let updatedHeader = headerTokens(rawContent).compactMap { token -> String? in
            switch token {
            case "#rewind/pending", "#rewind/ready": return "#rewind/synthesized"
            case "#rewind/has-ctx": return nil
            default: return String(token)
            }
        }.joined(separator: " ")
        return updatedHeader + rawContent[headerEnd...]
    }

    private static func headerTokens(_ rawContent: String) -> [Substring] {
        rawContent.prefix { !$0.isNewline }.split(whereSeparator: \.isWhitespace)
    }

    public static func parseMemo(
        id: String,
        rawContent: String,
        createdAt: Date,
        now: Date = Date(),
        hotWindow: TimeInterval = RewindCard.hotWindowSeconds,
        isOfflinePending: Bool = false
    ) -> RewindCard? {
        let tags = headerTokens(rawContent)
        let status: CardStatus? = tags.contains("#rewind/ready") ? .ready
            : tags.contains("#rewind/pending") ? .pending : nil
        guard let status,
              !tags.contains("#rewind/synthesized"),
              createdAt >= now.addingTimeInterval(-hotWindow) else {
            return nil
        }

        let lines = rawContent.components(separatedBy: "\n")
        var idx = 1
        var sourcePlatform = "macos"

        for token in tags where token.hasPrefix("#source/") {
            sourcePlatform = String(token.dropFirst("#source/".count))
        }
        while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }

        var title: String?
        var sessionTopic: String?
        var contextSummary: String?
        var keywords: [String] = []
        var sourceTitle = sourcePlatform
        var sourceURL: String?

        let metadataPrefixes = [
            "> **Title:**",
            "> **Session:**",
            "> **Context:**",
            "> **Keywords:**",
            "> **Source:**"
        ]

        while idx < lines.count {
            let line = lines[idx]
            guard let matched = metadataPrefixes.first(where: { line.hasPrefix($0) }) else {
                break
            }
            let value = String(line.dropFirst(matched.count)).trimmingCharacters(in: .whitespaces)
            switch matched {
            case "> **Title:**":
                title = value.isEmpty ? nil : value
            case "> **Session:**":
                sessionTopic = value.isEmpty ? nil : value
            case "> **Context:**":
                contextSummary = value.isEmpty ? nil : value
            case "> **Keywords:**":
                keywords = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "> **Source:**":
                let parsed = parseSourceLine(value)
                if !parsed.title.isEmpty { sourceTitle = parsed.title }
                sourceURL = parsed.url
            default:
                break
            }
            idx += 1
        }

        if idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }
        let verbatim = idx < lines.count ? lines[idx...].joined(separator: "\n") : ""

        let normalizedID = id.hasPrefix("memos/") ? String(id.dropFirst("memos/".count)) : id
        return RewindCard(
            id: normalizedID,
            rawContent: rawContent,
            status: status,
            sourcePlatform: sourcePlatform,
            title: title,
            sessionTopic: sessionTopic,
            contextSummary: contextSummary,
            keywords: keywords,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            verbatimText: verbatim,
            createdAt: createdAt,
            isOfflinePending: isOfflinePending
        )
    }

    private static func parseSourceLine(_ raw: String) -> (title: String, url: String?) {
        let mainPart = raw.components(separatedBy: " · ").first ?? raw
        if mainPart.hasPrefix("["),
           let midRange = mainPart.range(of: "]("),
           mainPart.hasSuffix(")") {
            let label = String(mainPart[mainPart.index(after: mainPart.startIndex)..<midRange.lowerBound])
            let linkStart = midRange.upperBound
            let linkEnd = mainPart.index(before: mainPart.endIndex)
            let link = String(mainPart[linkStart..<linkEnd])
            let exposedURL = link.hasPrefix("macos://") ? nil : link
            return (label, exposedURL)
        }
        return (mainPart.trimmingCharacters(in: .whitespaces), nil)
    }
}

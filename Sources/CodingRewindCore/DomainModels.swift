// SPDX-License-Identifier: MIT

import Foundation

public struct StoragePaths: Equatable, Sendable {
    public static let appSupportEnvironmentKey = "CODING_REWIND_APP_SUPPORT"
    public static let antigravityConfigEnvironmentKey = "CODING_REWIND_ANTIGRAVITY_CONFIG"

    public let appSupportDirectoryURL: URL
    public let stashDatabaseURL: URL
    public let draftsDirectoryURL: URL
    public let runtimeDirectoryURL: URL
    public let antigravityConfigDirectoryURL: URL

    public init(
        appSupportDirectoryURL: URL,
        draftsDirectoryURL: URL? = nil,
        antigravityConfigDirectoryURL: URL? = nil
    ) throws {
        let fm = FileManager.default
        let resolvedAppSupport = appSupportDirectoryURL.standardizedFileURL
        let resolvedDrafts = (draftsDirectoryURL ?? resolvedAppSupport.appendingPathComponent("Drafts", isDirectory: true)).standardizedFileURL
        let resolvedRuntime = resolvedAppSupport.appendingPathComponent("Runtime", isDirectory: true).standardizedFileURL
        let defaultGeminiConfig = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        let resolvedAntigravityConfig = (antigravityConfigDirectoryURL ?? defaultGeminiConfig).standardizedFileURL

        try fm.createDirectory(at: resolvedAppSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: resolvedDrafts, withIntermediateDirectories: true)
        try fm.createDirectory(at: resolvedRuntime, withIntermediateDirectories: true)

        self.appSupportDirectoryURL = resolvedAppSupport
        self.stashDatabaseURL = resolvedAppSupport.appendingPathComponent("stash.sqlite3", isDirectory: false)
        self.draftsDirectoryURL = resolvedDrafts
        self.runtimeDirectoryURL = resolvedRuntime
        self.antigravityConfigDirectoryURL = resolvedAntigravityConfig
    }

    public static func defaultUserPaths() throws -> StoragePaths {
        try resolveFromEnvironment(ProcessInfo.processInfo.environment)
    }

    public static func resolveFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StoragePaths {
        let fm = FileManager.default
        let appSupportURL: URL
        if let overridePath = environment[appSupportEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            appSupportURL = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            let baseAppSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            appSupportURL = baseAppSupport.appendingPathComponent("CodingRewind", isDirectory: true)
        }

        let antigravityURL: URL?
        if let configOverride = environment[antigravityConfigEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configOverride.isEmpty {
            antigravityURL = URL(fileURLWithPath: configOverride, isDirectory: true)
        } else {
            antigravityURL = nil
        }

        return try StoragePaths(
            appSupportDirectoryURL: appSupportURL,
            antigravityConfigDirectoryURL: antigravityURL
        )
    }
}

public struct ClipID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public init(parsing rawValue: String) throws {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw StashError.invalidClipID(rawValue)
        }
        self.rawValue = normalized
    }

    public var shortCode: String {
        String(rawValue.prefix(8))
    }

    public var description: String {
        rawValue
    }
}

public struct DraftID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let stem: String

    public init(parsing rawStem: String) throws {
        var candidate = rawStem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if candidate.hasSuffix(".md") {
            candidate = String(candidate.dropLast(3))
        }
        guard !candidate.isEmpty,
              !candidate.contains(".."),
              candidate.unicodeScalars.allSatisfy({
                  ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_"
              }) else {
            throw StashError.invalidDraftID(rawStem)
        }
        self.stem = candidate
    }

    public static func makeSlug(fromTitle title: String, suffix: String? = nil) -> DraftID {
        let lowered = title.lowercased()
        var parts: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        var base = parts.joined(separator: "-")
        if base.isEmpty {
            base = "draft"
        }
        if base.count > 40 {
            base = String(base.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let cleanedSuffix = suffix?
            .lowercased()
            .unicodeScalars
            .filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
            .map(String.init)
            .joined()
        let finalStem: String
        if let cleanedSuffix, !cleanedSuffix.isEmpty {
            finalStem = "\(base)-\(cleanedSuffix)"
        } else {
            finalStem = base
        }
        return (try? DraftID(parsing: finalStem)) ?? (try! DraftID(parsing: "draft-note"))
    }

    public var filename: String {
        "\(stem).md"
    }

    public var description: String {
        stem
    }
}

public struct VerbatimExcerpt: Hashable, Codable, Sendable, CustomStringConvertible {
    public let text: String

    public init(validating rawText: String) throws {
        let cleaned = rawText.replacingOccurrences(of: "\0", with: "")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StashError.emptyExcerpt
        }
        self.text = cleaned
    }

    public var description: String {
        text
    }
}

public enum PromptContext: Equatable, Hashable, Codable, Sendable {
    case captured(String)
    case missing

    public static func from(raw: String?) -> PromptContext {
        guard let cleaned = raw?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cleaned.isEmpty else {
            return .missing
        }
        return .captured(cleaned)
    }

    public var capturedText: String? {
        switch self {
        case .captured(let text):
            return text
        case .missing:
            return nil
        }
    }
}

public enum WebChatSite: String, CaseIterable, Hashable, Codable, Sendable {
    case chatgpt
    case claude
    case gemini
    case other

    public var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT Web"
        case .claude:
            return "Claude Web"
        case .gemini:
            return "Gemini Web"
        case .other:
            return "Web Chat"
        }
    }

    public static func infer(sourceParam: String?, url: URL?, windowTitle: String?) -> WebChatSite {
        if let param = sourceParam?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !param.isEmpty {
            if param.contains("chatgpt") || param.contains("openai") { return .chatgpt }
            if param.contains("claude") || param.contains("anthropic") { return .claude }
            if param.contains("gemini") || param.contains("bard") { return .gemini }
        }
        if let host = url?.host?.lowercased() {
            if host.contains("chatgpt.com") || host.contains("openai.com") { return .chatgpt }
            if host.contains("claude.ai") || host.contains("anthropic.com") { return .claude }
            if host.contains("gemini.google.com") { return .gemini }
        }
        if let title = windowTitle?.lowercased() {
            if title.contains("chatgpt") { return .chatgpt }
            if title.contains("claude") { return .claude }
            if title.contains("gemini") { return .gemini }
        }
        return .other
    }
}

public enum ClipSource: Equatable, Hashable, Codable, Sendable {
    case antigravity(conversationId: String?, workspacePath: String?, locator: String?)
    case web(site: WebChatSite, url: String?, pageTitle: String?)
    case desktop(bundleIdentifier: String, appName: String, windowTitle: String?)

    public var displayBadge: String {
        switch self {
        case .antigravity(_, let workspacePath, _):
            if let workspacePath, !workspacePath.isEmpty {
                let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
                if !folder.isEmpty && folder != "/" {
                    return "Antigravity · \(folder)"
                }
            }
            return "Antigravity 2.x"
        case .web(let site, _, _):
            return site.displayName
        case .desktop(_, let appName, _):
            return appName.isEmpty ? "macOS App" : appName
        }
    }

    public var reopenURL: URL? {
        switch self {
        case .web(_, let urlString, _):
            guard let urlString, let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }
            return url
        case .antigravity(let conversationId, let workspacePath, _):
            if let workspacePath, FileManager.default.fileExists(atPath: workspacePath) {
                return URL(fileURLWithPath: workspacePath)
            }
            if let conversationId, !conversationId.isEmpty {
                return URL(string: "antigravity://conversation/\(conversationId)")
            }
            return nil
        case .desktop:
            return nil
        }
    }
}

public enum ClipDisposition: Equatable, Hashable, Codable, Sendable {
    case active(reheatedAt: Date? = nil)
    case synthesized(draftID: DraftID?, at: Date)
    case cooled(at: Date)

    public static var active: ClipDisposition {
        .active(reheatedAt: nil)
    }
}

public enum ClipLifecycle: String, CaseIterable, Hashable, Codable, Sendable {
    case hot
    case synthesized
    case archived

    public var displayName: String {
        switch self {
        case .hot:
            return "近 72h 热窗"
        case .synthesized:
            return "已成文"
        case .archived:
            return "已冷却"
        }
    }
}

public struct ClipAnnotation: Equatable, Hashable, Codable, Sendable {
    public var title: String?
    public var tags: [String]
    public var userNote: String?

    public init(title: String? = nil, tags: [String] = [], userNote: String? = nil) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedNote = userNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
    }

    public var isEmpty: Bool {
        title == nil && tags.isEmpty && userNote == nil
    }
}

public struct Clip: Identifiable, Equatable, Hashable, Codable, Sendable {
    public static let defaultHotWindow: TimeInterval = 72 * 3600

    public let id: ClipID
    public let verbatimExcerpt: VerbatimExcerpt
    public var excerpt: String { verbatimExcerpt.text }
    public let promptContext: PromptContext
    public let source: ClipSource
    public let capturedAt: Date
    public var disposition: ClipDisposition
    public var annotation: ClipAnnotation

    public init(
        id: ClipID = ClipID(),
        verbatimExcerpt: VerbatimExcerpt,
        promptContext: PromptContext,
        source: ClipSource,
        capturedAt: Date = Date(),
        disposition: ClipDisposition = .active(reheatedAt: nil),
        annotation: ClipAnnotation = ClipAnnotation()
    ) {
        self.id = id
        self.verbatimExcerpt = verbatimExcerpt
        self.promptContext = promptContext
        self.source = source
        self.capturedAt = capturedAt
        self.disposition = disposition
        self.annotation = annotation
    }

    public func lifecycle(
        at referenceDate: Date = Date(),
        hotWindow: TimeInterval = Clip.defaultHotWindow
    ) -> ClipLifecycle {
        switch disposition {
        case .synthesized:
            return .synthesized
        case .cooled:
            return .archived
        case .active(let reheatedAt):
            let anchorDate = reheatedAt ?? capturedAt
            return referenceDate.timeIntervalSince(anchorDate) <= hotWindow ? .hot : .archived
        }
    }
}

public struct NewClip: Equatable, Sendable {
    public let verbatimExcerpt: VerbatimExcerpt
    public var excerpt: String { verbatimExcerpt.text }
    public let promptContext: PromptContext
    public let source: ClipSource
    public let capturedAt: Date
    public let annotation: ClipAnnotation

    public init(
        excerpt: String,
        promptContext: PromptContext,
        source: ClipSource,
        capturedAt: Date = Date(),
        annotation: ClipAnnotation = ClipAnnotation()
    ) throws {
        self.verbatimExcerpt = try VerbatimExcerpt(validating: excerpt)
        self.promptContext = promptContext
        self.source = source
        self.capturedAt = capturedAt
        self.annotation = annotation
    }

    public static func fromDesktopSelection(
        _ selection: CapturedSelection,
        activeAntigravityTurn: ActiveAntigravityTurn?
    ) throws -> NewClip {
        if selection.bundleIdentifier == CapturedSelection.antigravityBundleIdentifier {
            if let turn = activeAntigravityTurn {
                let locator = "conversation://\(turn.conversationId)"
                return try NewClip(
                    excerpt: selection.text,
                    promptContext: PromptContext.from(raw: turn.userPrompt),
                    source: .antigravity(
                        conversationId: turn.conversationId,
                        workspacePath: turn.workspacePath,
                        locator: locator
                    ),
                    capturedAt: selection.capturedAt
                )
            } else {
                return try NewClip(
                    excerpt: selection.text,
                    promptContext: .missing,
                    source: .antigravity(
                        conversationId: nil,
                        workspacePath: nil,
                        locator: nil
                    ),
                    capturedAt: selection.capturedAt
                )
            }
        }

        let browserBundlePrefixes = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.brave.Browser",
            "com.microsoft.edgemac"
        ]
        if browserBundlePrefixes.contains(where: { selection.bundleIdentifier.hasPrefix($0) }) {
            let parsedURL = selection.documentURL.flatMap(URL.init(string:))
            let site = WebChatSite.infer(sourceParam: nil, url: parsedURL, windowTitle: selection.windowTitle)
            if site != .other || parsedURL != nil {
                return try NewClip(
                    excerpt: selection.text,
                    promptContext: .missing,
                    source: .web(site: site, url: selection.documentURL, pageTitle: selection.windowTitle),
                    capturedAt: selection.capturedAt
                )
            }
        }

        return try NewClip(
            excerpt: selection.text,
            promptContext: .missing,
            source: .desktop(
                bundleIdentifier: selection.bundleIdentifier,
                appName: selection.appName,
                windowTitle: selection.windowTitle
            ),
            capturedAt: selection.capturedAt
        )
    }
}

public struct CapturedSelection: Equatable, Sendable {
    public static let antigravityBundleIdentifier = "com.google.antigravity"

    public let text: String
    public let bundleIdentifier: String
    public let appName: String
    public let windowTitle: String?
    public let documentURL: String?
    public let capturedAt: Date

    public init(
        text: String,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil,
        documentURL: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.capturedAt = capturedAt
    }
}

public struct DeletionReceipt: Equatable, Sendable {
    public let deletedClipCount: Int
    public let remainingClipCount: Int
    public let remainingFTSTokenRows: Int

    public init(deletedClipCount: Int, remainingClipCount: Int, remainingFTSTokenRows: Int) {
        self.deletedClipCount = deletedClipCount
        self.remainingClipCount = remainingClipCount
        self.remainingFTSTokenRows = remainingFTSTokenRows
    }
}

public struct DeleteAllConfirmation: Equatable, Sendable {
    public static let userConfirmedPurgeAll = DeleteAllConfirmation()
    private init() {}
}

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case markdown
    case json
}

public enum ClipScope: String, CaseIterable, Equatable, Codable, Sendable {
    case hot
    case synthesized
    case archived
    case all

    public var displayTitle: String {
        switch self {
        case .hot:
            return "近 72h 热窗"
        case .synthesized:
            return "已成文"
        case .archived:
            return "已冷却"
        case .all:
            return "全部"
        }
    }
}

public struct ClipQuery: Equatable, Sendable {
    public var text: String?
    public var scope: ClipScope
    public var limit: Int
    public var referenceDate: Date
    public var hotWindow: TimeInterval

    public init(
        text: String? = nil,
        scope: ClipScope = .hot,
        limit: Int = 50,
        referenceDate: Date = Date(),
        hotWindow: TimeInterval = Clip.defaultHotWindow
    ) {
        self.text = text
        self.scope = scope
        self.limit = max(1, limit)
        self.referenceDate = referenceDate
        self.hotWindow = hotWindow
    }

    public static func hot(limit: Int = 50, now: Date = Date()) -> ClipQuery {
        ClipQuery(text: nil, scope: .hot, limit: limit, referenceDate: now)
    }
}

public enum StashError: Error, LocalizedError, Equatable, Sendable {
    case emptyExcerpt
    case invalidClipID(String)
    case invalidDraftID(String)
    case readOnlyStore
    case clipNotFound(ClipID)
    case databaseOpenFailed(String)
    case queryFailed(String)
    case writeFailed(String)
    case exportEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .emptyExcerpt:
            return "无法保存空白片段，请先选中非空文字。"
        case .invalidClipID(let raw):
            return "无效的片段标识: \(raw)"
        case .invalidDraftID(let raw):
            return "无效的草稿文件名: \(raw)"
        case .readOnlyStore:
            return "当前存储处于只读模式，无法写入或删除片段。"
        case .clipNotFound(let id):
            return "找不到片段: \(id.rawValue)"
        case .databaseOpenFailed(let detail):
            return "无法打开本地归档数据库: \(detail)"
        case .queryFailed(let detail):
            return "本地检索失败: \(detail)"
        case .writeFailed(let detail):
            return "本地归档写入失败: \(detail)"
        case .exportEncodingFailed:
            return "导出数据编码失败。"
        }
    }
}

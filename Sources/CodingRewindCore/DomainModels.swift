// SPDX-License-Identifier: MIT

import Foundation

public enum AIAccessMode: String, Codable, CaseIterable, Equatable, Sendable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public struct SnippetNote: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let author: String
    public let content: String
    public let createdAt: Date

    public init(id: String, author: String, content: String, createdAt: Date) {
        self.id = id
        self.author = author
        self.content = content
        self.createdAt = createdAt
    }
}

public enum RewindError: Error, LocalizedError, Equatable, Sendable {
    case emptySelection
    case accessibilityPermissionDenied
    case noFrontmostApplication
    case invalidClipID(String)
    case snippetNotFound(String)
    case invalidMemosURL(String)
    case missingCredentials
    case aiWriteDisabled
    case invalidMetadataUpdate(String)
    case httpError(statusCode: Int, body: String)
    case invalidServerResponse
    case networkFailure(String)
    case ioError(String)
    case keychainError(OSStatus)

    public func localizedDescription(in language: AppLanguage) -> String {
        L10n.rewindError(self, in: language)
    }

    public var errorDescription: String? {
        localizedDescription(in: .zhHans)
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

public enum CaptureContextLead: Equatable, Hashable, Sendable {
    case sessionOpening(String)
    case pageLead(String)
}

public struct CaptureContext: Codable, Equatable, Hashable, Sendable {
    public let sessionTitle: String
    public let sessionID: String?
    public let lead: CaptureContextLead?
    public let prompt: String
    public let recentTurns: [ConversationTurn]

    private enum CodingKeys: String, CodingKey {
        case sessionTitle
        case sessionID
        case sessionOpening
        case pageLead
        case prompt
        case recentTurns
    }

    public init(
        sessionTitle: String,
        sessionID: String? = nil,
        lead: CaptureContextLead? = nil,
        prompt: String,
        recentTurns: [ConversationTurn] = []
    ) {
        self.sessionTitle = Self.normalizeText(sessionTitle)
        let cleanedSessionID = sessionID.map(Self.normalizeText) ?? ""
        self.sessionID = cleanedSessionID.isEmpty ? nil : cleanedSessionID
        switch lead {
        case .sessionOpening(let raw):
            let cleaned = Self.normalizeText(raw)
            self.lead = cleaned.isEmpty ? nil : .sessionOpening(cleaned)
        case .pageLead(let raw):
            let cleaned = Self.normalizeText(raw)
            self.lead = cleaned.isEmpty ? nil : .pageLead(cleaned)
        case nil:
            self.lead = nil
        }
        self.prompt = Self.normalizeText(prompt)
        self.recentTurns = recentTurns.filter { !$0.text.isEmpty }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionTitle = try container.decodeIfPresent(String.self, forKey: .sessionTitle) ?? ""
        let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        let rawOpening = try container.decodeIfPresent(String.self, forKey: .sessionOpening)
        let rawPageLead = try container.decodeIfPresent(String.self, forKey: .pageLead)
        let prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        let recentTurns = try container.decodeIfPresent([ConversationTurn].self, forKey: .recentTurns) ?? []

        let decodedLead: CaptureContextLead?
        if let rawOpening, !Self.normalizeText(rawOpening).isEmpty {
            decodedLead = .sessionOpening(rawOpening)
        } else if let rawPageLead, !Self.normalizeText(rawPageLead).isEmpty {
            decodedLead = .pageLead(rawPageLead)
        } else {
            decodedLead = nil
        }

        self.init(
            sessionTitle: sessionTitle,
            sessionID: sessionID,
            lead: decodedLead,
            prompt: prompt,
            recentTurns: recentTurns
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionTitle, forKey: .sessionTitle)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(sessionOpening, forKey: .sessionOpening)
        try container.encodeIfPresent(pageLead, forKey: .pageLead)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(recentTurns, forKey: .recentTurns)
    }

    public var sessionOpening: String? {
        if case .sessionOpening(let text) = lead {
            return text
        }
        return nil
    }

    public var pageLead: String? {
        if case .pageLead(let text) = lead {
            return text
        }
        return nil
    }

    public var isEmpty: Bool {
        sessionTitle.isEmpty && sessionID == nil && lead == nil && prompt.isEmpty && recentTurns.isEmpty
    }

    public func formattedCommentMarkdown() -> String {
        MemosWireFormat.formatContextComment(self)
    }

    private static func normalizeText(_ value: String) -> String {
        value.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SourceLocator: Equatable, Hashable, Sendable {
    case web(url: URL, sessionID: String?)
    case antigravitySession(sessionID: String)

    public var sessionID: String? {
        switch self {
        case .web(_, let sessionID):
            return sessionID
        case .antigravitySession(let sessionID):
            return sessionID
        }
    }

    public static func parse(sourceURL: String?) -> SourceLocator? {
        guard let raw = sourceURL?.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "conversation":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let combined = ((components?.host ?? url.host ?? "") + (components?.path ?? url.path))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else { return nil }
            return .antigravitySession(sessionID: combined)
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return .web(url: url, sessionID: extractChatSessionID(from: url))
        default:
            return nil
        }
    }

    public static func extractChatSessionID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch rawHost {
        case "chatgpt.com", "www.chatgpt.com", "chat.openai.com":
            if segments.count >= 2 && segments[0] == "c" {
                return segments[1]
            }
            if segments.count >= 4 && segments[0] == "g" && segments[2] == "c" {
                return segments[3]
            }
            return nil
        case "claude.ai", "www.claude.ai":
            if segments.count >= 2 && segments[0] == "chat" {
                return segments[1]
            }
            if segments.count >= 4 && segments[0] == "project" && segments[2] == "chat" {
                return segments[3]
            }
            return nil
        case "gemini.google.com":
            if segments.count >= 2 && segments[0] == "app" {
                return segments[1]
            }
            if segments.count >= 4 && segments[0] == "u" && segments[1].allSatisfy(\.isNumber) && segments[2] == "app" {
                return segments[3]
            }
            return nil
        default:
            return nil
        }
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

    public func badgeText(in language: AppLanguage) -> String {
        L10n.cardStatusBadge(self, in: language)
    }

    public var badgeText: String {
        badgeText(in: .zhHans)
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

    public var sourceLocator: SourceLocator? {
        SourceLocator.parse(sourceURL: sourceURL)
    }

    public func effectiveSessionID(context: CaptureContext? = nil) -> String? {
        sourceLocator?.sessionID ?? context?.sessionID
    }
}

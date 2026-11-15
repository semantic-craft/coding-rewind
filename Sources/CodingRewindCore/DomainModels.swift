// SPDX-License-Identifier: MIT

import Foundation

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

    public var reopenURL: URL? {
        guard let sourceURL, let url = URL(string: sourceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "conversation" else {
            return nil
        }
        return url
    }
}

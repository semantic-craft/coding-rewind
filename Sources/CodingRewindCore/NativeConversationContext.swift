// SPDX-License-Identifier: MIT

import Foundation

public enum NativeChatHost: String, Equatable, Sendable {
    case chatGPT = "chatgpt"
    case gemini
}

public struct NativeChatCapture: Equatable, Sendable {
    public let host: NativeChatHost
    public let title: String
    public let backlink: URL?
    public let snapshot: NativeConversationSnapshot?
    public let renderedSelection: String?

    public init(host: NativeChatHost, title: String, backlink: URL? = nil, snapshot: NativeConversationSnapshot? = nil, renderedSelection: String? = nil) {
        self.host = host
        self.title = title
        self.backlink = backlink
        self.snapshot = snapshot
        self.renderedSelection = renderedSelection
    }
}

public struct NativeConversationSnapshot: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable {
            case user = "User"
            case assistant = "Assistant"
        }

        public let role: Role
        public let renderedText: String
        public let contextText: String

        public init(role: Role, renderedText: String, contextText: String? = nil) {
            self.role = role
            self.renderedText = renderedText
            self.contextText = contextText ?? renderedText
        }
    }

    public enum Entry: Equatable, Sendable {
        case message(Message)
        case gap
    }

    public enum Anchor: Equatable, Sendable {
        case message(Int)
        case uniqueText
    }

    public let entries: [Entry]
    public let anchor: Anchor

    public init(entries: [Entry], anchor: Anchor = .uniqueText) {
        self.entries = entries
        self.anchor = anchor
    }
}

public enum NativeConversationContext {
    public static func resolve(
        selectedText: String, snapshot: NativeConversationSnapshot, sessionTitle: String
    ) -> CaptureContext? {
        let selection = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
        guard !selection.isEmpty else { return nil }
        let matches = snapshot.entries.indices.filter { index in
            guard case .message(let message) = snapshot.entries[index] else { return false }
            return message.renderedText.replacingOccurrences(of: "\r\n", with: "\n")
                .range(of: selection, options: .literal) != nil
        }
        let anchor: Int
        switch snapshot.anchor {
        case .message(let index):
            guard matches.contains(index) else { return nil }
            anchor = index
        case .uniqueText:
            guard matches.count == 1, let index = matches.first else { return nil }
            anchor = index
        }
        let intervalStart = snapshot.entries[..<anchor].lastIndex(of: .gap).map { $0 + 1 } ?? 0
        let messages = snapshot.entries[intervalStart...anchor].compactMap { entry -> NativeConversationSnapshot.Message? in
            guard case .message(let message) = entry else { return nil }
            return message
        }
        let rounds = messages.indices.filter { messages[$0].role == .user }.suffix(4)
        guard let firstRound = rounds.first, let lastRound = rounds.last else { return nil }
        let prompt = messages.last?.role == .assistant ? messages[lastRound].contextText : ""
        return CaptureContext(
            sessionTitle: sessionTitle,
            prompt: prompt,
            recentTurns: messages[firstRound...].map { ConversationTurn(role: $0.role.rawValue, text: $0.contextText) }
        )
    }
}

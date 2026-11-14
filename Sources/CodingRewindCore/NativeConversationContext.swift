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
        let indexedMessages: [(entryIndex: Int, message: ConversationContextSlicer.Message)] = snapshot.entries.enumerated().compactMap { index, entry in
            guard case .message(let message) = entry else { return nil }
            let role: ConversationContextSlicer.Role = message.role == .user ? .user : .assistant
            return (
                index,
                ConversationContextSlicer.Message(
                    role: role,
                    matchText: message.renderedText,
                    contextText: message.contextText
                )
            )
        }

        let anchorMode: ConversationContextSlicer.AnchorMode
        switch snapshot.anchor {
        case .message(let entryIndex):
            guard let pos = indexedMessages.firstIndex(where: { $0.entryIndex == entryIndex }) else {
                return nil
            }
            anchorMode = .explicitIndex(pos)
        case .uniqueText:
            anchorMode = .uniqueSubstring
        }

        guard let matchedPos = ConversationContextSlicer.resolveAnchor(
            selectedText: selectedText,
            in: indexedMessages.map(\.message),
            mode: anchorMode
        ) else {
            return nil
        }

        let anchor = indexedMessages[matchedPos].entryIndex
        let intervalStart = snapshot.entries[..<anchor].lastIndex(of: .gap).map { $0 + 1 } ?? 0
        let continuousSlice = indexedMessages
            .filter { $0.entryIndex >= intervalStart && $0.entryIndex <= anchor }
            .map(\.message)
        guard !continuousSlice.isEmpty else { return nil }

        return ConversationContextSlicer.slice(
            selectedText: selectedText,
            messages: continuousSlice,
            anchor: .explicitIndex(continuousSlice.count - 1),
            sessionTitle: sessionTitle
        )
    }
}

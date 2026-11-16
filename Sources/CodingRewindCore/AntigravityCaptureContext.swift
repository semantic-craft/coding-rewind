// SPDX-License-Identifier: MIT

import Foundation

public struct AntigravityConversationID: Equatable, Sendable {
    fileprivate let uuid: UUID

    package init?(webAreaURL: URL) {
        guard let components = URLComponents(url: webAreaURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host == "127.0.0.1",
              components.user == nil, components.password == nil,
              components.percentEncodedPath.hasPrefix("/c/") else {
            return nil
        }
        let afterPrefix = components.percentEncodedPath.dropFirst(3)
        guard !afterPrefix.hasPrefix("/") else { return nil }
        let rawUUID = afterPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawUUID.contains("/"), let uuid = UUID(uuidString: rawUUID) else {
            return nil
        }
        self.uuid = uuid
    }

    public var rawValue: String { uuid.uuidString.lowercased() }

    public var backlink: String { "conversation://\(rawValue)" }
}

public struct AntigravityCaptureContext: Sendable {
    private let brainDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.brainDirectory = homeDirectory.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    package func resolve(
        conversationID: AntigravityConversationID,
        selectedText: String,
        sessionTitle: String
    ) async -> CaptureContext? {
        let rawSessionID = conversationID.rawValue
        let transcript = brainDirectory
            .appendingPathComponent(rawSessionID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl", isDirectory: false)
        let task = Task.detached {
            guard let messages = try? Self.readMessages(from: transcript) else { return nil as CaptureContext? }
            return ConversationContextSlicer.slice(
                selectedText: selectedText,
                messages: messages,
                anchor: .uniqueSubstring,
                sessionTitle: sessionTitle,
                sessionID: rawSessionID
            )
        }
        return await task.value
    }

    private static func parseMessage(record: [String: Any]) throws -> ConversationContextSlicer.Message? {
        let stepType = (record["type"] as? String) ?? (record["event"] as? [String: Any])?["type"] as? String
        let userInput = record["userInput"] as? [String: Any]
        let role: ConversationContextSlicer.Role
        switch stepType {
        case "USER_INPUT":
            let source = (record["source"] as? String) ?? (userInput?["source"] as? String) ?? "USER"
            guard source == "USER" || source == "USER_EXPLICIT" else { return nil }
            role = .user
        case "PLANNER_RESPONSE", "MODEL_OUTPUT":
            role = .assistant
        case .some:
            return nil
        case nil:
            throw CocoaError(.fileReadCorruptFile)
        }

        let content = record["content"] ?? userInput?["content"] ?? record["text"]
        let text: String
        switch content {
        case let string as String:
            text = string
        case let parts as [[String: Any]]:
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case nil:
            guard role == .user else { return nil }
            text = ""
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
        let truncatedByHost = (record["truncated_fields"] as? [String])?.contains("content") == true
        return ConversationContextSlicer.Message(
            role: role,
            matchText: text,
            truncatedByHost: truncatedByHost
        )
    }

    private static func readMessages(from transcript: URL) throws -> [ConversationContextSlicer.Message] {
        let handle = try FileHandle(forReadingFrom: transcript)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size > 0 else { return [] }
        try handle.seek(toOffset: 0)
        guard let bytes = try handle.read(upToCount: size), bytes.count == size,
              let lastLineEnd = bytes.lastIndex(of: 0x0a) else {
            return []
        }
        return try bytes[..<lastLineEnd].split(separator: 0x0a).compactMap { line in
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try parseMessage(record: record)
        }
    }
}

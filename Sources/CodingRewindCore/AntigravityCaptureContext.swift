// SPDX-License-Identifier: MIT

import Foundation

public struct AntigravityConversationID: Equatable, Sendable {
    fileprivate let uuid: UUID

    package init?(webAreaURL: URL) {
        guard let components = URLComponents(url: webAreaURL, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              components.user == nil, components.password == nil,
              components.percentEncodedPath.hasPrefix("/c/"),
              let uuid = UUID(uuidString: String(components.percentEncodedPath.dropFirst(3))) else {
            return nil
        }
        self.uuid = uuid
    }

    public var backlink: String { "conversation://\(uuid.uuidString.lowercased())" }
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
        let transcript = brainDirectory
            .appendingPathComponent(conversationID.uuid.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl", isDirectory: false)
        return await Task.detached {
            guard let messages = try? Self.readMessages(from: transcript) else { return nil }
            return Self.context(for: selectedText, in: messages, sessionTitle: sessionTitle)
        }.value
    }

    private struct Message {
        enum Role: String {
            case user = "User"
            case assistant = "Assistant"
        }

        let role: Role
        let text: String
        let truncatedByHost: Bool

        var excerpt: String {
            let limit = 800
            return text.count > limit || truncatedByHost ? String(text.prefix(limit)) + "…" : text
        }

        init?(record: [String: Any]) throws {
            let stepType = (record["type"] as? String) ?? (record["event"] as? [String: Any])?["type"] as? String
            let userInput = record["userInput"] as? [String: Any]
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
            truncatedByHost = (record["truncated_fields"] as? [String])?.contains("content") == true
        }
    }

    private static func readMessages(from transcript: URL) throws -> [Message] {
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
            return try Message(record: record)
        }
    }

    private static func context(for selectedText: String, in messages: [Message], sessionTitle: String) -> CaptureContext? {
        let selection = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
        guard !selection.isEmpty else { return nil }
        var anchor: Int?
        for (index, message) in messages.enumerated() {
            let text = message.text.replacingOccurrences(of: "\r\n", with: "\n")
            guard text.range(of: selection, options: .literal) != nil else { continue }
            guard anchor == nil else { return nil }
            anchor = index
        }
        guard let anchor else { return nil }

        let throughAnchor = messages[...anchor]
        let roundStarts = throughAnchor.indices.filter { messages[$0].role == .user }.suffix(4)
        let prompt: String
        if messages[anchor].role == .assistant, let start = roundStarts.last {
            prompt = messages[start].excerpt
        } else {
            prompt = ""
        }
        let context = throughAnchor[(roundStarts.first ?? anchor)...].map {
            ConversationTurn(role: $0.role.rawValue, text: $0.excerpt)
        }
        return CaptureContext(sessionTitle: sessionTitle, prompt: prompt, recentTurns: context)
    }
}

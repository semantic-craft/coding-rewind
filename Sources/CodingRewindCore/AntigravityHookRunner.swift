// SPDX-License-Identifier: MIT

import Foundation

public enum AntigravityHookRunner {
    public static let emptyJSONAcknowledgement = Data("{}\n".utf8)
    private static let tailWindowBytes: UInt64 = 256 * 1024
    private static let maxTurnChars = 800

    @discardableResult
    public static func run(
        stdin: Data,
        environment: [String: String],
        activeTurnStore: ActiveTurnStore,
        stdout: (Data) -> Void,
        now: Date = Date()
    ) -> Int32 {
        defer { stdout(emptyJSONAcknowledgement) }

        if isSubagentInvocation(environment: environment) {
            return 0
        }
        guard let parsed = parsePayload(stdin: stdin, environment: environment) else {
            return 0
        }

        let recentTurns = parsed.transcriptPath.map { extractRecentTurns(fromTranscriptPath: $0, limit: 4) } ?? []
        let resolvedPrompt: String
        if let direct = parsed.lastUserInput, !direct.isEmpty {
            resolvedPrompt = direct
        } else {
            resolvedPrompt = recentTurns.last(where: { $0.role == "User" })?.text ?? ""
        }

        if let turn = try? ActiveAntigravityTurn(
            conversationId: parsed.conversationId,
            workspacePath: parsed.workspacePath,
            lastUserInput: resolvedPrompt,
            hookEventName: parsed.hookEventName,
            recentTurns: recentTurns,
            observedAt: now
        ) {
            try? activeTurnStore.record(turn)
        }
        return 0
    }

    public static func isSubagentInvocation(environment: [String: String]) -> Bool {
        if let subID = environment["ANTIGRAVITY_SUBAGENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subID.isEmpty {
            return true
        }
        return environment["SUBAGENT"] == "1" || environment["IS_SUBAGENT"] == "1"
    }

    private struct HookPayload {
        let conversationId: String
        let lastUserInput: String?
        let workspacePath: String?
        let transcriptPath: String?
        let hookEventName: String?
    }

    private static func parsePayload(stdin: Data, environment: [String: String]) -> HookPayload? {
        let json: [String: Any]
        if !stdin.isEmpty, let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            json = obj
        } else {
            json = [:]
        }

        let rawConv = (json["conversationId"] as? String)
            ?? (json["conversation_id"] as? String)
            ?? environment["CONVERSATION_ID"]
            ?? environment["ANTIGRAVITY_CONVERSATION_ID"]
        guard let conversationId = rawConv?.trimmingCharacters(in: .whitespacesAndNewlines),
              !conversationId.isEmpty else {
            return nil
        }

        let lastUserInput = ((json["lastUserInput"] as? String) ?? (json["last_user_input"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let workspaceArray = (json["workspacePaths"] as? [String]) ?? (json["workspace_paths"] as? [String])
        let workspaceCandidate = workspaceArray?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? (json["cwd"] as? String)
            ?? environment["PWD"]
        let workspacePath = workspaceCandidate?.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawTranscript = ((json["transcriptPath"] as? String) ?? (json["transcript_path"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptPath: String?
        if let rawTranscript, !rawTranscript.isEmpty {
            transcriptPath = (rawTranscript as NSString).expandingTildeInPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            transcriptPath = "\(home)/.gemini/antigravity/brain/\(conversationId)/.system_generated/logs/transcript.jsonl"
        }

        let hookEventName = ((json["hookEventName"] as? String) ?? (json["hook_event_name"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HookPayload(
            conversationId: conversationId,
            lastUserInput: (lastUserInput?.isEmpty == false) ? lastUserInput : nil,
            workspacePath: (workspacePath?.isEmpty == false) ? workspacePath : nil,
            transcriptPath: transcriptPath,
            hookEventName: (hookEventName?.isEmpty == false) ? hookEventName : nil
        )
    }

    public static func extractRecentTurns(fromTranscriptPath path: String, limit: Int = 4) -> [ConversationTurn] {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }

        let startOffset = fileSize > tailWindowBytes ? (fileSize - tailWindowBytes) : 0
        try? handle.seek(toOffset: startOffset)
        guard let tailData = try? handle.readToEnd(), !tailData.isEmpty else { return [] }

        let text = String(decoding: tailData, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if startOffset > 0 && !lines.isEmpty {
            lines.removeFirst()
        }

        var turns: [ConversationTurn] = []
        for line in lines {
            if let turn = parseTranscriptLine(String(line)) {
                turns.append(turn)
            }
        }
        return Array(turns.suffix(max(1, limit)))
    }

    private static func parseTranscriptLine(_ line: String) -> ConversationTurn? {
        guard line.contains("USER_INPUT") || line.contains("PLANNER_RESPONSE") || line.contains("MODEL_OUTPUT"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let stepType = (obj["type"] as? String) ?? ((obj["event"] as? [String: Any])?["type"] as? String)
        let role: String
        switch stepType {
        case "USER_INPUT":
            let source = (obj["source"] as? String)
                ?? ((obj["userInput"] as? [String: Any])?["source"] as? String)
                ?? "USER"
            guard source == "USER" || source == "USER_EXPLICIT" else { return nil }
            role = "User"
        case "PLANNER_RESPONSE", "MODEL_OUTPUT":
            role = "Assistant"
        default:
            return nil
        }

        let rawContent: Any? = obj["content"]
            ?? (obj["userInput"] as? [String: Any])?["content"]
            ?? obj["text"]
        let extracted: String?
        if let str = rawContent as? String {
            extracted = str.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let parts = rawContent as? [[String: Any]] {
            extracted = parts
                .compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            extracted = nil
        }

        guard let clean = extracted, !clean.isEmpty else { return nil }
        let truncated = clean.count > maxTurnChars ? String(clean.prefix(maxTurnChars)) + "…" : clean
        return ConversationTurn(role: role, text: truncated)
    }
}

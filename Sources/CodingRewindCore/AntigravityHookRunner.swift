// SPDX-License-Identifier: MIT

import Foundation

public enum AntigravityHookRunner {
    public static let emptyJSONAcknowledgement = Data("{}\n".utf8)
    private static let initialTailWindowBytes: UInt64 = 64 * 1024
    private static let expandedTailWindowBytes: UInt64 = 256 * 1024

    @discardableResult
    public static func run(
        stdin: Data,
        environment: [String: String],
        activeTurnStore: ActiveTurnStore,
        stdout: (Data) -> Void,
        now: Date = Date()
    ) -> Int32 {
        defer {
            stdout(emptyJSONAcknowledgement)
        }

        if isSubagentInvocation(environment: environment) {
            return 0
        }

        guard let parsed = parsePayload(stdin: stdin, environment: environment) else {
            return 0
        }

        guard let prompt = extractLatestUserPrompt(fromTranscriptPath: parsed.transcriptPath) else {
            return 0
        }

        if let turn = try? ActiveAntigravityTurn(
            conversationId: parsed.conversationId,
            workspacePath: parsed.cwd,
            userPrompt: prompt,
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
        if environment["SUBAGENT"] == "1" || environment["IS_SUBAGENT"] == "1" {
            return true
        }
        return false
    }

    private struct HookPayload {
        let conversationId: String
        let transcriptPath: String
        let cwd: String?
    }

    private static func parsePayload(
        stdin: Data,
        environment: [String: String]
    ) -> HookPayload? {
        var jsonDict: [String: Any] = [:]
        if !stdin.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            jsonDict = parsed
        }

        let rawConvID = (jsonDict["conversationId"] as? String)
            ?? (jsonDict["conversation_id"] as? String)
            ?? environment["CONVERSATION_ID"]
            ?? environment["ANTIGRAVITY_CONVERSATION_ID"]

        guard let conversationId = rawConvID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !conversationId.isEmpty else {
            return nil
        }

        let rawTranscript = (jsonDict["transcriptPath"] as? String)
            ?? (jsonDict["transcript_path"] as? String)

        let transcriptPath: String
        if let rawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTranscript.isEmpty {
            transcriptPath = (rawTranscript as NSString).expandingTildeInPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            transcriptPath = "\(home)/.gemini/antigravity/brain/\(conversationId)/.system_generated/logs/transcript.jsonl"
        }

        let cwd = ((jsonDict["cwd"] as? String) ?? environment["PWD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HookPayload(
            conversationId: conversationId,
            transcriptPath: transcriptPath,
            cwd: (cwd?.isEmpty == false) ? cwd : nil
        )
    }

    public static func extractLatestUserPrompt(fromTranscriptPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return nil
        }

        for windowBytes in [initialTailWindowBytes, expandedTailWindowBytes] {
            let startOffset = fileSize > windowBytes ? (fileSize - windowBytes) : 0
            try? handle.seek(toOffset: startOffset)
            guard let tailData = try? handle.readToEnd(),
                  !tailData.isEmpty else {
                continue
            }

            let text = String(decoding: tailData, as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if startOffset > 0 && !lines.isEmpty {
                lines.removeFirst()
            }

            for line in lines.reversed() {
                if let prompt = parseUserInputLine(String(line)) {
                    return prompt
                }
            }

            if startOffset == 0 {
                break
            }
        }

        return nil
    }

    private static func parseUserInputLine(_ line: String) -> String? {
        guard line.contains("USER_INPUT"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let typeValue = (obj["type"] as? String) ?? ((obj["event"] as? [String: Any])?["type"] as? String)
        guard typeValue == "USER_INPUT" else {
            return nil
        }

        let sourceValue = (obj["source"] as? String)
            ?? ((obj["userInput"] as? [String: Any])?["source"] as? String)
            ?? "USER"
        guard sourceValue == "USER" || sourceValue == "USER_EXPLICIT" else {
            return nil
        }

        let contentCandidate: Any? = obj["content"]
            ?? (obj["userInput"] as? [String: Any])?["content"]
            ?? obj["text"]
            ?? (obj["userInput"] as? [String: Any])?["text"]

        if let directString = contentCandidate as? String {
            let trimmed = directString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let parts = contentCandidate as? [[String: Any]] {
            let joined = parts
                .compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }
}

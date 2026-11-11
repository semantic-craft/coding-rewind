// SPDX-License-Identifier: MIT

import Foundation

public struct ActiveAntigravityTurn: Equatable, Codable, Sendable {
    public let conversationId: String
    public let workspacePath: String?
    public let lastUserInput: String
    public let hookEventName: String?
    public let recentTurns: [ConversationTurn]
    public let observedAt: Date

    public init(
        conversationId: String,
        workspacePath: String?,
        lastUserInput: String,
        hookEventName: String? = nil,
        recentTurns: [ConversationTurn] = [],
        observedAt: Date = Date()
    ) throws {
        let trimmedID = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = lastUserInput
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTurns = Array(recentTurns.filter { !$0.text.isEmpty }.suffix(4))
        guard !trimmedID.isEmpty, (!trimmedPrompt.isEmpty || !cleanedTurns.isEmpty) else {
            throw RewindError.ioError("ActiveAntigravityTurn requires non-empty conversationId and turn content")
        }
        self.conversationId = trimmedID
        let trimmedWS = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspacePath = (trimmedWS?.isEmpty == false) ? trimmedWS : nil
        self.lastUserInput = trimmedPrompt
        let trimmedEvent = hookEventName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hookEventName = (trimmedEvent?.isEmpty == false) ? trimmedEvent : nil
        self.recentTurns = cleanedTurns
        self.observedAt = observedAt
    }

    public var sessionTitle: String {
        if let workspacePath, !workspacePath.isEmpty {
            let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
            if !folder.isEmpty && folder != "/" {
                return folder
            }
        }
        return "Antigravity"
    }

    public func toCaptureContext() -> CaptureContext {
        CaptureContext(sessionTitle: sessionTitle, prompt: lastUserInput, recentTurns: recentTurns)
    }
}

public struct ActiveTurnStore: Sendable {
    public let fileURL: URL
    public let maxTurnAge: TimeInterval

    public init(dataDirectoryURL: URL, maxTurnAge: TimeInterval = 4 * 3600) throws {
        let resolvedDir = dataDirectoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: resolvedDir, withIntermediateDirectories: true)
        self.fileURL = resolvedDir.appendingPathComponent("active_turn.json", isDirectory: false)
        self.maxTurnAge = maxTurnAge
    }

    public func record(_ turn: ActiveAntigravityTurn) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(turn)
        try AtomicFile.writeData(data, to: fileURL, permissions: 0o600)
    }

    public func latestTurn(
        forFrontmostBundleID bundleID: String,
        now: Date = Date()
    ) -> ActiveAntigravityTurn? {
        guard bundleID == CapturedSelection.antigravityBundleIdentifier,
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let turn = try? decoder.decode(ActiveAntigravityTurn.self, from: data),
              now.timeIntervalSince(turn.observedAt) <= maxTurnAge else {
            return nil
        }
        return turn
    }
}

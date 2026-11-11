// SPDX-License-Identifier: MIT

import Foundation

public struct ActiveAntigravityTurn: Equatable, Codable, Sendable {
    public let conversationId: String
    public let workspacePath: String?
    public let userPrompt: String
    public let observedAt: Date

    public init(
        conversationId: String,
        workspacePath: String?,
        userPrompt: String,
        observedAt: Date = Date()
    ) throws {
        let trimmedID = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = userPrompt
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedPrompt.isEmpty else {
            throw StashError.writeFailed("ActiveAntigravityTurn requires non-empty conversationId and userPrompt")
        }
        self.conversationId = trimmedID
        let trimmedWorkspace = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspacePath = (trimmedWorkspace?.isEmpty == false) ? trimmedWorkspace : nil
        self.userPrompt = trimmedPrompt
        self.observedAt = observedAt
    }
}

public struct ActiveTurnStore: Sendable {
    public static let maxRetainedTurnFiles = 4

    public let directoryURL: URL
    public let maxTurnAge: TimeInterval

    public init(directoryURL: URL, maxTurnAge: TimeInterval = 4 * 3600) throws {
        let resolved = directoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        self.directoryURL = resolved
        self.maxTurnAge = maxTurnAge
    }

    public func record(_ turn: ActiveAntigravityTurn) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(turn)

        let filename = "turn-\(Self.sanitizeFilenameComponent(turn.conversationId)).json"
        let targetURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        try AtomicFileWriter.writeData(data, to: targetURL, permissions: 0o600)
        try pruneSnapshotsExceedingCap()
    }

    public func latestTurn(
        forFrontmostBundleID bundleID: String,
        conversationId: String? = nil,
        now: Date = Date()
    ) throws -> ActiveAntigravityTurn? {
        guard bundleID == CapturedSelection.antigravityBundleIdentifier else {
            return nil
        }

        let snapshots = try readAllSnapshots()
        let freshSnapshots = snapshots.filter { snapshot in
            now.timeIntervalSince(snapshot.observedAt) <= maxTurnAge
        }

        if let conversationId, !conversationId.isEmpty {
            return freshSnapshots.first { $0.conversationId == conversationId }
        }
        return freshSnapshots.first
    }

    public func clearAll() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return }
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for url in urls where url.lastPathComponent.hasPrefix("turn-") && url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }

    public func retainedSnapshotFileURLs() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return urls.filter { $0.lastPathComponent.hasPrefix("turn-") && $0.pathExtension == "json" }
    }

    private func readAllSnapshots() throws -> [ActiveAntigravityTurn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var turns: [ActiveAntigravityTurn] = []
        for url in try retainedSnapshotFileURLs() {
            if let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode(ActiveAntigravityTurn.self, from: data) {
                turns.append(decoded)
            }
        }
        turns.sort { $0.observedAt > $1.observedAt }
        return turns
    }

    private func pruneSnapshotsExceedingCap() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [(url: URL, observedAt: Date)] = []

        for url in try retainedSnapshotFileURLs() {
            if let data = try? Data(contentsOf: url),
               let turn = try? decoder.decode(ActiveAntigravityTurn.self, from: data) {
                entries.append((url, turn.observedAt))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        entries.sort { $0.observedAt > $1.observedAt }
        if entries.count > Self.maxRetainedTurnFiles {
            for stale in entries.dropFirst(Self.maxRetainedTurnFiles) {
                try? FileManager.default.removeItem(at: stale.url)
            }
        }
    }

    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        var result = ""
        for scalar in raw.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        return result.isEmpty ? "default" : String(result.prefix(64))
    }
}

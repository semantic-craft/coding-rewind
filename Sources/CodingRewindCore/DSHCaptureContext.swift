// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public struct DSHSnapshotMessage: Codable, Equatable, Hashable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct DSHActiveSessionSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionId: String
    public let sessionTitle: String
    public let updatedAtMs: Int64
    public let messages: [DSHSnapshotMessage]

    public init(
        version: Int = 1,
        sessionId: String,
        sessionTitle: String,
        updatedAtMs: Int64,
        messages: [DSHSnapshotMessage]
    ) {
        self.version = version
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.updatedAtMs = updatedAtMs
        self.messages = messages
    }
}

public enum DSHCaptureContext {
    public static let maximumSnapshotBytes = 4 * 1024 * 1024
    public static let defaultMaxSnapshotAge: TimeInterval = 6 * 3600
    public static let defaultFreshMetadataWindow: TimeInterval = 15 * 60
    private static let maxFutureClockSkewSeconds: TimeInterval = 60

    public struct Resolution: Equatable, Sendable {
        public let sessionID: String?
        public let sourceTitle: String
        public let context: CaptureContext?

        public init(sessionID: String?, sourceTitle: String, context: CaptureContext?) {
            self.sessionID = sessionID
            self.sourceTitle = sourceTitle
            self.context = context
        }
    }

    public static func readSnapshot(
        from dataDirectoryURL: URL,
        maxAge: TimeInterval = defaultMaxSnapshotAge,
        now: Date = Date()
    ) -> DSHActiveSessionSnapshot? {
        let snapshotURL = dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("dsh-active-session.json", isDirectory: false)
        let fd = open(snapshotURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= maximumSnapshotBytes else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(),
              let snapshot = try? JSONDecoder().decode(DSHActiveSessionSnapshot.self, from: data),
              snapshot.version == 1 else {
            return nil
        }

        let cleanedID = sanitizeSessionID(snapshot.sessionId)
        guard let cleanedID else { return nil }

        let updatedSeconds = Double(snapshot.updatedAtMs) / 1000.0
        let age = now.timeIntervalSince1970 - updatedSeconds
        guard age >= -maxFutureClockSkewSeconds && age <= maxAge else {
            return nil
        }

        return DSHActiveSessionSnapshot(
            version: snapshot.version,
            sessionId: cleanedID,
            sessionTitle: snapshot.sessionTitle,
            updatedAtMs: snapshot.updatedAtMs,
            messages: snapshot.messages
        )
    }

    public static func sliceContext(
        selectedText: String,
        messages: [DSHSnapshotMessage],
        sessionTitle: String,
        sessionID: String?
    ) -> CaptureContext? {
        let mapped: [ConversationContextSlicer.Message] = messages.compactMap { msg in
            let role: ConversationContextSlicer.Role
            switch msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "user":
                role = .user
            case "assistant":
                role = .assistant
            default:
                return nil
            }
            return ConversationContextSlicer.Message(role: role, matchText: msg.text)
        }
        guard !mapped.isEmpty else { return nil }
        return ConversationContextSlicer.slice(
            selectedText: selectedText,
            messages: mapped,
            anchor: .uniqueSubstring,
            sessionTitle: sessionTitle,
            sessionID: sessionID
        )
    }

    public static func resolve(
        selectedText: String,
        fallbackTitle: String?,
        dataDirectoryURL: URL,
        now: Date = Date(),
        maxSnapshotAge: TimeInterval = defaultMaxSnapshotAge,
        freshMetadataWindow: TimeInterval = defaultFreshMetadataWindow
    ) -> Resolution {
        let cleanedFallback = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTitle = (cleanedFallback?.isEmpty == false) ? cleanedFallback! : "DSH"

        guard let snapshot = readSnapshot(from: dataDirectoryURL, maxAge: maxSnapshotAge, now: now) else {
            return Resolution(sessionID: nil, sourceTitle: defaultTitle, context: nil)
        }

        let cleanedSnapshotTitle = snapshot.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanedSnapshotTitle.isEmpty ? defaultTitle : cleanedSnapshotTitle
        let context = sliceContext(
            selectedText: selectedText,
            messages: snapshot.messages,
            sessionTitle: title,
            sessionID: snapshot.sessionId
        )

        let age = now.timeIntervalSince1970 - Double(snapshot.updatedAtMs) / 1000.0
        if context != nil || age <= freshMetadataWindow {
            return Resolution(sessionID: snapshot.sessionId, sourceTitle: title, context: context)
        }

        return Resolution(sessionID: nil, sourceTitle: defaultTitle, context: nil)
    }

    public static func sanitizeSessionID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed.rangeOfCharacter(from: forbidden) == nil else {
            return nil
        }
        return trimmed
    }
}

// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum ConversationHost: String, Codable, CaseIterable, Sendable {
    case antigravity, codex

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        }
    }

    public var requiresExplicitConversationOpen: Bool {
        switch self {
        case .antigravity: return false
        case .codex: return true
        }
    }

    fileprivate var handoffDirectory: String {
        switch self {
        case .antigravity: return "handoff"
        case .codex: return "codex-handoff"
        }
    }
}

public enum ConversationPrompt {
    public static func buildPrompt(
        for cards: [RewindCard],
        language: AppLanguage = .zhHans,
        aiAccessMode: AIAccessMode = .readWrite
    ) -> String {
        switch language {
        case .zhHans:
            var sections: [String] = [
                "请围绕以下我在 Coding Rewind 暂存的灵感卡片展开分析与写作推演，保留关键原文论据并在引用处附上出处链接："
            ]
            for (index, card) in cards.enumerated() {
                var lines: [String] = []
                let heading = card.title ?? card.sourceTitle
                lines.append("### 卡片 \(index + 1)：\(heading)")
                lines.append("- 卡片 ID：`\(card.id)`")
                if let session = card.sessionTopic, !session.isEmpty {
                    lines.append("- 会话主题：\(session)")
                }
                if let ctx = card.contextSummary, !ctx.isEmpty {
                    lines.append("- 上下文脉络：\(ctx)")
                }
                if let url = card.sourceURL, !url.isEmpty {
                    lines.append("- 原文出处：[出处](\(url))（\(card.sourceTitle)）")
                } else {
                    lines.append("- 原文出处：\(card.sourceTitle)")
                }
                lines.append("")
                let quoted = card.verbatimText
                    .components(separatedBy: "\n")
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                lines.append(quoted)
                sections.append(lines.joined(separator: "\n"))
            }
            if !cards.isEmpty && aiAccessMode == .readWrite {
                sections.append(
                    "完成梳理后，如需将推演结论写回 Coding Rewind，可按上方卡片 ID 调用 `append_snippet_note` 追加批注，或调用 `create_snippet` 将新整理出的提纲与草稿存回片段库。"
                )
            }
            return sections.joined(separator: "\n\n")
        case .en:
            var sections: [String] = [
                "Analyze and synthesize the following highlights I stashed in Coding Rewind, preserving key verbatim arguments and citing original provenance links:"
            ]
            for (index, card) in cards.enumerated() {
                var lines: [String] = []
                let heading = card.title ?? card.sourceTitle
                lines.append("### Clip \(index + 1): \(heading)")
                lines.append("- Clip ID: `\(card.id)`")
                if let session = card.sessionTopic, !session.isEmpty {
                    lines.append("- Session Topic: \(session)")
                }
                if let ctx = card.contextSummary, !ctx.isEmpty {
                    lines.append("- Context: \(ctx)")
                }
                if let url = card.sourceURL, !url.isEmpty {
                    lines.append("- Source: [Source](\(url)) (\(card.sourceTitle))")
                } else {
                    lines.append("- Source: \(card.sourceTitle)")
                }
                lines.append("")
                let quoted = card.verbatimText
                    .components(separatedBy: "\n")
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                lines.append(quoted)
                sections.append(lines.joined(separator: "\n"))
            }
            if !cards.isEmpty && aiAccessMode == .readWrite {
                sections.append(
                    "After synthesis, if you want to save conclusions back to Coding Rewind, you may call `append_snippet_note` (using the Clip ID above) to attach notes to the original card, or `create_snippet` to stash a newly synthesized outline or draft."
                )
            }
            return sections.joined(separator: "\n\n")
        }
    }
}

public struct ConversationReference: Equatable, Sendable {
    public let host: ConversationHost
    public let id: String

    public init(host: ConversationHost, id: String) {
        self.host = host
        self.id = id
    }
}

public enum ConversationLaunchResult: Equatable, Sendable {
    case succeeded(ConversationReference)
    case failed(state: ConversationReceipt.State)
}

public struct ConversationRequest: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 45
    public let version: Int
    public let requestId: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let prompt: String

    public init(requestId: UUID = UUID(), prompt: String, now: Date = Date()) {
        version = 1
        self.requestId = requestId
        createdAt = now
        expiresAt = now.addingTimeInterval(Self.lifetime)
        self.prompt = prompt
    }
}

public struct ConversationReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case dispatching, succeeded, rejected, expired, unknown

        var isTerminalFailure: Bool {
            switch self {
            case .rejected, .expired:
                return true
            case .dispatching, .succeeded, .unknown:
                return false
            }
        }
    }
    public let requestId: UUID
    public let state: State
    public let updatedAt: Date
    public let conversationId: String?

    public init(requestId: UUID, state: State, updatedAt: Date = Date(), conversationId: String? = nil) {
        self.requestId = requestId
        self.state = state
        self.updatedAt = updatedAt
        self.conversationId = conversationId
    }
}

public struct CurrentConversation: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let cardIDs: [String]
    public let markSynthesized: Bool
    public let expiresAt: Date
    public let remainingArchiveCardIDs: [String]?
    public var archiveCardIDs: [String] { remainingArchiveCardIDs ?? cardIDs }
}

public struct ConversationHandoffStore: Sendable {
    public let directory: URL
    private var requests: URL { directory.appendingPathComponent("requests", isDirectory: true) }
    private var receipts: URL { directory.appendingPathComponent("receipts", isDirectory: true) }
    private var currentURL: URL { directory.appendingPathComponent("current.json") }
    public static let maximumPromptBytes = 256 * 1024

    public init(dataDirectoryURL: URL, host: ConversationHost = .antigravity) throws {
        directory = dataDirectoryURL.standardizedFileURL.appendingPathComponent(host.handoffDirectory, isDirectory: true)
        try Self.checkAncestors(dataDirectoryURL.standardizedFileURL)
        for url in [directory, requests, receipts] {
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw Self.failure("create directory") }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw Self.failure("handoff directory must be private and owned by this user")
            }
        }
    }

    private static func failure(_ operation: String) -> RewindError {
        .ioError("Conversation handoff: \(operation)")
    }

    private static func checkAncestors(_ url: URL) throws {
        var candidate = url
        while candidate.path != "/" {
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw failure("unsafe data directory")
            }
            candidate.deleteLastPathComponent()
        }
    }

    private func requestURL(_ id: UUID) -> URL { requests.appendingPathComponent(id.uuidString + ".json") }
    private func receiptURL(_ id: UUID) -> URL { receipts.appendingPathComponent(id.uuidString + ".json") }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.failure("unsafe file") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= Self.maximumPromptBytes * 8 else { throw Self.failure("invalid private file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }

    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT != S_IFREG || info.st_uid != getuid() || info.st_nlink != 1) {
            throw Self.failure("unsafe destination")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("create private file") }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: JSONEncoder().encode(value))
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw Self.failure("persist file") }
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Self.failure("open directory") }
        defer { close(parentFD) }
        guard fsync(parentFD) == 0 else { throw Self.failure("persist directory") }
    }

    public func current() throws -> CurrentConversation? { try read(CurrentConversation.self, at: currentURL) }
    public func receipt(for id: UUID) throws -> ConversationReceipt? {
        let result = try read(ConversationReceipt.self, at: receiptURL(id))
        guard result == nil || result?.requestId == id else { throw Self.failure("receipt identity mismatch") }
        return result
    }

    public func submit(prompt: String, cardIDs: [String], markSynthesized: Bool, now: Date = Date()) throws -> CurrentConversation {
        let lockFD = try acquireLock(named: "submit.lock")
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        if let current = try current() { return current }
        guard !prompt.isEmpty, !prompt.utf8.contains(0), prompt.utf8.count <= Self.maximumPromptBytes else { throw Self.failure("prompt exceeds 256 KiB") }
        let request = ConversationRequest(prompt: prompt, now: now)
        let current = CurrentConversation(requestId: request.requestId, cardIDs: cardIDs, markSynthesized: markSynthesized, expiresAt: request.expiresAt, remainingArchiveCardIDs: markSynthesized ? cardIDs : [])
        try write(current, at: currentURL)
        try write(request, at: requestURL(request.requestId))
        return current
    }

    private func removeFile(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw Self.failure("remove private file") }
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Self.failure("persist removal") }
    }
    public func clearCurrent(requestId: UUID? = nil) throws {
        let lockFD = try acquireLock(named: "submit.lock")
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        if let requestId, try current()?.requestId != requestId { return }
        try removeFile(currentURL)
    }
    public func recordArchivedCard(_ cardID: String, requestId: UUID) throws {
        let lockFD = try acquireLock(named: "submit.lock")
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        guard let current = try current(), current.requestId == requestId else {
            throw Self.failure("archive request changed")
        }
        let updated = CurrentConversation(requestId: current.requestId, cardIDs: current.cardIDs, markSynthesized: current.markSynthesized, expiresAt: current.expiresAt, remainingArchiveCardIDs: current.archiveCardIDs.filter { $0 != cardID })
        try write(updated, at: currentURL)
    }

    public func saveReceipt(_ receipt: ConversationReceipt) throws { try write(receipt, at: receiptURL(receipt.requestId)) }
    public func removeRequest(_ id: UUID) throws { try removeFile(requestURL(id)) }

    public func pendingRequests() throws -> [ConversationRequest] {
        try FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            if let existing = try receipt(for: id), existing.state != .dispatching {
                try removeRequest(id)
                return nil
            }
            let value: ConversationRequest?
            do { value = try read(ConversationRequest.self, at: url) }
            catch is DecodingError {
                try saveReceipt(ConversationReceipt(requestId: id, state: .rejected))
                try removeRequest(id)
                return nil
            }
            guard let value, value.requestId == id, value.version == 1,
                  !value.prompt.isEmpty, !value.prompt.utf8.contains(0), value.prompt.utf8.count <= Self.maximumPromptBytes,
                  value.expiresAt > value.createdAt, value.expiresAt.timeIntervalSince(value.createdAt) <= ConversationRequest.lifetime else {
                try saveReceipt(ConversationReceipt(requestId: id, state: .rejected))
                try removeRequest(id)
                return nil
            }
            return value
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func expireUnpublishedCurrent(now: Date = Date()) throws {
        guard let current = try current(), current.expiresAt <= now,
              try receipt(for: current.requestId) == nil,
              try read(ConversationRequest.self, at: requestURL(current.requestId)) == nil else { return }
        try saveReceipt(ConversationReceipt(requestId: current.requestId, state: .expired, updatedAt: now))
    }

    public func recover(now: Date = Date()) throws {
        try expireUnpublishedCurrent(now: now)
        for folder in [directory, requests, receipts] {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(".write-") {
                var info = stat()
                if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                   now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 120 {
                    try removeFile(url)
                }
            }
        }
        let currentID = try current()?.requestId
        for url in try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let receipt = try receipt(for: id) else { continue }
            if receipt.state == .dispatching {
                try saveReceipt(ConversationReceipt(requestId: id, state: .unknown, updatedAt: now))
                try removeRequest(id)
            } else if id != currentID && now.timeIntervalSince(receipt.updatedAt) > 7 * 86400 {
                try removeRequest(id)
                try removeFile(url)
            } else {
                try removeRequest(id)
            }
        }
    }

    public func acquireWorkerLock() throws -> Int32 { try acquireLock(named: "worker.lock") }

    package func acquireWorkerLockIfUnlocked() throws -> Int32? { try acquireLockIfUnlocked(named: "worker.lock") }

    private func acquireLock(named name: String) throws -> Int32 {
        guard let fd = try acquireLockIfUnlocked(named: name) else {
            throw Self.failure("\(name) is already locked")
        }
        return fd
    }

    private func acquireLockIfUnlocked(named name: String) throws -> Int32? {
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("open \(name)") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw Self.failure("\(name) is unsafe")
        }
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return fd
            }
            if errno == EINTR {
                continue
            }
            let lockErrno = errno
            close(fd)
            if lockErrno == EWOULDBLOCK {
                return nil
            }
            throw Self.failure("lock \(name)")
        }
    }
}

package extension Process {
    func waitForExit(within seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func terminateGracefully(graceSeconds: TimeInterval = 0.2) {
        if isRunning {
            terminate()
            waitForExit(within: graceSeconds)
        }
        if isRunning {
            _ = kill(processIdentifier, SIGKILL)
        }
        waitUntilExit()
    }
}

public enum SidecarAgentAPI {
    public static func invoke(prompt: String, environment: [String: String], timeout: TimeInterval = 30) -> (ConversationReceipt.State, String?) {
        guard let binary = (environment["PATH"] ?? "").split(separator: ":").map({ URL(fileURLWithPath: String($0)).appendingPathComponent("agentapi") }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return (.rejected, nil)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["new-conversation", prompt]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (.rejected, nil) }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        var exceeded = false
        repeat {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if output.count + count <= 1024 * 1024 { output.append(contentsOf: buffer.prefix(count)) }
                else { exceeded = true }
            } else if !process.isRunning { break }
            if Date() >= deadline || exceeded {
                process.terminateGracefully()
                return (.unknown, nil)
            }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
        } while true
        process.waitUntilExit()
        struct Response: Decodable { struct Envelope: Decodable { struct Conversation: Decodable { let conversationId: String }; let newConversation: Conversation }; let response: Envelope }
        if let response = try? JSONDecoder().decode(Response.self, from: output),
           UUID(uuidString: response.response.newConversation.conversationId) != nil {
            return (.succeeded, response.response.newConversation.conversationId)
        }
        return (.unknown, nil)
    }
}

public final class ConversationSidecarWorker: Sendable {
    private let store: ConversationHandoffStore
    private let lockFD: Int32

    private init(store: ConversationHandoffStore, lockFD: Int32) {
        self.store = store
        self.lockFD = lockFD
    }

    public convenience init(store: ConversationHandoffStore) throws {
        let fd = try store.acquireWorkerLock()
        self.init(store: store, lockFD: fd)
        try store.recover()
    }

    public static func acquireIfUnlocked(store: ConversationHandoffStore) throws -> ConversationSidecarWorker? {
        guard let fd = try store.acquireWorkerLockIfUnlocked() else { return nil }
        let worker = ConversationSidecarWorker(store: store, lockFD: fd)
        try store.recover()
        return worker
    }

    deinit { _ = flock(lockFD, LOCK_UN); close(lockFD) }

    public func processPending(now: Date? = nil, invoke: (ConversationRequest) -> (ConversationReceipt.State, String?)) throws {
        for request in try pendingBatch(now: now ?? Date()) {
            guard try beginDispatch(for: request, now: now ?? Date()) else { continue }
            try completeDispatch(for: request, outcome: invoke(request), now: now ?? Date())
        }
    }

    public func processPending(now: Date? = nil, invoke: (ConversationRequest) async -> (ConversationReceipt.State, String?)) async throws {
        for request in try pendingBatch(now: now ?? Date()) {
            guard try beginDispatch(for: request, now: now ?? Date()) else { continue }
            try completeDispatch(for: request, outcome: await invoke(request), now: now ?? Date())
        }
    }

    private func pendingBatch(now: Date) throws -> [ConversationRequest] {
        try store.expireUnpublishedCurrent(now: now)
        return try store.pendingRequests()
    }

    private func beginDispatch(for request: ConversationRequest, now: Date) throws -> Bool {
        if let receipt = try store.receipt(for: request.requestId) {
            if receipt.state != .dispatching { try store.removeRequest(request.requestId) }
            return false
        }
        if request.expiresAt <= now || request.createdAt > now.addingTimeInterval(5) {
            try store.saveReceipt(ConversationReceipt(requestId: request.requestId, state: .expired, updatedAt: now))
            try store.removeRequest(request.requestId)
            return false
        }
        try store.saveReceipt(ConversationReceipt(requestId: request.requestId, state: .dispatching, updatedAt: now))
        return true
    }

    private func completeDispatch(for request: ConversationRequest, outcome: (ConversationReceipt.State, String?), now: Date) throws {
        let finalState: ConversationReceipt.State = outcome.0 == .dispatching ? .unknown : outcome.0
        try store.saveReceipt(ConversationReceipt(requestId: request.requestId, state: finalState, updatedAt: now, conversationId: outcome.1))
        try store.removeRequest(request.requestId)
    }
}

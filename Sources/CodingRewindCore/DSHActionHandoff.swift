// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public struct DSHActionRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let action: String
    public let sessionId: String
    public let createdAtMs: Int64
    public let expiresAtMs: Int64

    public init(
        version: Int = 1,
        requestId: String = UUID().uuidString,
        action: String = "openSession",
        sessionId: String,
        createdAtMs: Int64,
        expiresAtMs: Int64
    ) {
        self.version = version
        self.requestId = requestId
        self.action = action
        self.sessionId = sessionId
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
    }
}

public struct DSHActionReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case succeeded
        case failed
        case expired
    }

    public let requestId: String
    public let state: State
    public let sessionId: String?
    public let error: String?
    public let updatedAtMs: Int64

    public init(
        requestId: String,
        state: State,
        sessionId: String? = nil,
        error: String? = nil,
        updatedAtMs: Int64
    ) {
        self.requestId = requestId
        self.state = state
        self.sessionId = sessionId
        self.error = error
        self.updatedAtMs = updatedAtMs
    }
}

public struct DSHCaptureBridgeRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let captureId: String
    public let text: String
    public let sessionId: String?
    public let sessionTitle: String?
    public let messages: [DSHSnapshotMessage]?
    public let createdAtMs: Int64
    public let expiresAtMs: Int64

    public init(
        version: Int = 1,
        captureId: String = UUID().uuidString,
        text: String,
        sessionId: String? = nil,
        sessionTitle: String? = nil,
        messages: [DSHSnapshotMessage]? = nil,
        createdAtMs: Int64,
        expiresAtMs: Int64
    ) {
        self.version = version
        self.captureId = captureId
        self.text = text
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.messages = messages
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
    }
}

public struct DSHCaptureBridgeReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case saved
        case queuedOffline = "queued_offline"
        case failed
    }

    public let captureId: String
    public let state: State
    public let clipId: String?
    public let error: String?
    public let updatedAtMs: Int64

    public init(
        captureId: String,
        state: State,
        clipId: String? = nil,
        error: String? = nil,
        updatedAtMs: Int64
    ) {
        self.captureId = captureId
        self.state = state
        self.clipId = clipId
        self.error = error
        self.updatedAtMs = updatedAtMs
    }
}

private enum PrivateQueueIO {
    static func failure(_ label: String, _ operation: String) -> RewindError {
        .ioError("\(label): \(operation)")
    }

    static func prepareDirectories(
        dataDirectoryURL: URL,
        subdirectory: String,
        label: String
    ) throws -> (root: URL, requests: URL, receipts: URL) {
        let base = dataDirectoryURL.standardizedFileURL
        try checkAncestors(base, label: label)
        let root = base.appendingPathComponent(subdirectory, isDirectory: true)
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let receipts = root.appendingPathComponent("receipts", isDirectory: true)
        for url in [root, requests, receipts] {
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
                throw failure(label, "create directory")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  (info.st_mode & 0o077) == 0 else {
                throw failure(label, "directory must be private and owned by this user")
            }
        }
        return (root, requests, receipts)
    }

    private static func checkAncestors(_ url: URL, label: String) throws {
        var candidate = url
        while candidate.path != "/" {
            var info = stat()
            guard lstat(candidate.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw failure(label, "unsafe data directory")
            }
            candidate.deleteLastPathComponent()
        }
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        maxBytes: Int,
        label: String
    ) throws -> T? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure(label, "unsafe file") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size <= maxBytes else {
            throw failure(label, "invalid private file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }

    static func write<T: Encodable>(_ value: T, at url: URL, label: String) throws {
        var info = stat()
        if lstat(url.path, &info) == 0
            && ((info.st_mode & S_IFMT) != S_IFREG || info.st_uid != getuid() || info.st_nlink != 1) {
            throw failure(label, "unsafe destination")
        }
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure(label, "create private file") }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try handle.write(contentsOf: encoder.encode(value))
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw failure(label, "persist file")
        }
        try fsyncDirectory(parent, label: label)
    }

    static func removeFile(_ url: URL, label: String) throws {
        if unlink(url.path) != 0 && errno != ENOENT {
            throw failure(label, "remove private file")
        }
        try fsyncDirectory(url.deletingLastPathComponent(), label: label)
    }

    static func fsyncDirectory(_ url: URL, label: String) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(label, "open directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure(label, "persist directory") }
    }

    static func nowMs(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }
}

public struct DSHActionStore: Sendable {
    public static let defaultTimeout: TimeInterval = 2.5
    private static let maximumFileBytes = 256 * 1024
    private static let label = "DSH action handoff"

    public let directory: URL
    public let requestsDirectory: URL
    public let receiptsDirectory: URL

    public init(dataDirectoryURL: URL) throws {
        let dirs = try PrivateQueueIO.prepareDirectories(
            dataDirectoryURL: dataDirectoryURL,
            subdirectory: "dsh-actions",
            label: Self.label
        )
        self.directory = dirs.root
        self.requestsDirectory = dirs.requests
        self.receiptsDirectory = dirs.receipts
    }

    public func requestURL(for requestId: String) -> URL {
        requestsDirectory.appendingPathComponent(requestId + ".json", isDirectory: false)
    }

    public func receiptURL(for requestId: String) -> URL {
        receiptsDirectory.appendingPathComponent(requestId + ".json", isDirectory: false)
    }

    public func submitOpenSession(
        sessionID: String,
        lifetime: TimeInterval = 5,
        now: Date = Date()
    ) throws -> DSHActionRequest {
        guard let cleaned = DSHCaptureContext.sanitizeSessionID(sessionID) else {
            throw PrivateQueueIO.failure(Self.label, "invalid session ID")
        }
        let createdMs = PrivateQueueIO.nowMs(now)
        let expiresMs = createdMs + Int64(max(1.0, lifetime) * 1000.0)
        let request = DSHActionRequest(
            version: 1,
            requestId: UUID().uuidString,
            action: "openSession",
            sessionId: cleaned,
            createdAtMs: createdMs,
            expiresAtMs: expiresMs
        )
        try PrivateQueueIO.write(request, at: requestURL(for: request.requestId), label: Self.label)
        return request
    }

    public func receipt(for requestId: String) throws -> DSHActionReceipt? {
        guard let expectedUUID = UUID(uuidString: requestId) else { return nil }
        let result = try PrivateQueueIO.read(
            DSHActionReceipt.self,
            at: receiptURL(for: requestId),
            maxBytes: Self.maximumFileBytes,
            label: Self.label
        )
        guard result == nil || result.flatMap({ UUID(uuidString: $0.requestId) }) == expectedUUID else {
            throw PrivateQueueIO.failure(Self.label, "receipt identity mismatch")
        }
        return result
    }

    public func saveReceipt(_ receipt: DSHActionReceipt) throws {
        guard UUID(uuidString: receipt.requestId) != nil else {
            throw PrivateQueueIO.failure(Self.label, "invalid requestId")
        }
        try PrivateQueueIO.write(receipt, at: receiptURL(for: receipt.requestId), label: Self.label)
    }

    public func removeRequest(_ requestId: String) throws {
        guard UUID(uuidString: requestId) != nil else { return }
        try PrivateQueueIO.removeFile(requestURL(for: requestId), label: Self.label)
    }

    public func openSession(
        sessionID: String,
        timeout: TimeInterval = defaultTimeout,
        pollInterval: Duration = .milliseconds(50),
        beforePoll: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        let request: DSHActionRequest
        do {
            request = try submitOpenSession(sessionID: sessionID, lifetime: max(timeout + 2, 5))
        } catch {
            return false
        }
        await beforePoll?()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !Task.isCancelled {
            if let found = try? receipt(for: request.requestId) {
                try? removeRequest(request.requestId)
                return found.state == .succeeded
            }
            if Date() >= deadline {
                break
            }
            try? await Task.sleep(for: pollInterval)
        }
        try? removeRequest(request.requestId)
        return false
    }
}

public struct DSHCaptureBridgeStore: Sendable {
    public static let maximumTextBytes = 256 * 1024
    public static let maximumFileBytes = 4 * 1024 * 1024
    private static let label = "DSH capture bridge"

    public let directory: URL
    public let requestsDirectory: URL
    public let receiptsDirectory: URL

    public init(dataDirectoryURL: URL) throws {
        let dirs = try PrivateQueueIO.prepareDirectories(
            dataDirectoryURL: dataDirectoryURL,
            subdirectory: "dsh-captures",
            label: Self.label
        )
        self.directory = dirs.root
        self.requestsDirectory = dirs.requests
        self.receiptsDirectory = dirs.receipts
    }

    public func requestURL(for captureId: String) -> URL {
        requestsDirectory.appendingPathComponent(captureId + ".json", isDirectory: false)
    }

    public func receiptURL(for captureId: String) -> URL {
        receiptsDirectory.appendingPathComponent(captureId + ".json", isDirectory: false)
    }

    public func submit(_ request: DSHCaptureBridgeRequest) throws {
        guard UUID(uuidString: request.captureId) != nil else {
            throw PrivateQueueIO.failure(Self.label, "invalid captureId")
        }
        try PrivateQueueIO.write(request, at: requestURL(for: request.captureId), label: Self.label)
    }

    public func receipt(for captureId: String) throws -> DSHCaptureBridgeReceipt? {
        guard let expectedUUID = UUID(uuidString: captureId) else { return nil }
        let result = try PrivateQueueIO.read(
            DSHCaptureBridgeReceipt.self,
            at: receiptURL(for: captureId),
            maxBytes: Self.maximumFileBytes,
            label: Self.label
        )
        guard result == nil || result.flatMap({ UUID(uuidString: $0.captureId) }) == expectedUUID else {
            throw PrivateQueueIO.failure(Self.label, "receipt identity mismatch")
        }
        return result
    }

    public func consumeAndRecordReceipt(_ receipt: DSHCaptureBridgeReceipt) throws {
        guard UUID(uuidString: receipt.captureId) != nil else {
            throw PrivateQueueIO.failure(Self.label, "invalid captureId")
        }
        try PrivateQueueIO.write(receipt, at: receiptURL(for: receipt.captureId), label: Self.label)
        try PrivateQueueIO.removeFile(requestURL(for: receipt.captureId), label: Self.label)
    }

    public func pendingRequests(now: Date = Date()) throws -> [DSHCaptureBridgeRequest] {
        let nowMs = PrivateQueueIO.nowMs(now)
        let files = try FileManager.default.contentsOfDirectory(
            at: requestsDirectory,
            includingPropertiesForKeys: nil
        )
        var valid: [DSHCaptureBridgeRequest] = []

        for url in files where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }
            if (try? receipt(for: stem)) != nil {
                try? PrivateQueueIO.removeFile(url, label: Self.label)
                continue
            }
            let decoded: DSHCaptureBridgeRequest?
            do {
                decoded = try PrivateQueueIO.read(
                    DSHCaptureBridgeRequest.self,
                    at: url,
                    maxBytes: Self.maximumFileBytes,
                    label: Self.label
                )
            } catch {
                try? consumeAndRecordReceipt(
                    DSHCaptureBridgeReceipt(
                        captureId: stem,
                        state: .failed,
                        error: "invalid capture request",
                        updatedAtMs: nowMs
                    )
                )
                continue
            }
            guard let request = decoded else { continue }
            let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard request.version == 1,
                  let stemUUID = UUID(uuidString: stem),
                  UUID(uuidString: request.captureId) == stemUUID,
                  !trimmedText.isEmpty,
                  !request.text.utf8.contains(0),
                  request.text.utf8.count <= Self.maximumTextBytes,
                  request.expiresAtMs > request.createdAtMs else {
                try? consumeAndRecordReceipt(
                    DSHCaptureBridgeReceipt(
                        captureId: stem,
                        state: .failed,
                        error: "rejected capture request",
                        updatedAtMs: nowMs
                    )
                )
                continue
            }
            if request.expiresAtMs <= nowMs {
                try? consumeAndRecordReceipt(
                    DSHCaptureBridgeReceipt(
                        captureId: stem,
                        state: .failed,
                        error: "capture request expired",
                        updatedAtMs: nowMs
                    )
                )
                continue
            }
            valid.append(request)
        }

        return valid.sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs < rhs.createdAtMs
            }
            return lhs.captureId < rhs.captureId
        }
    }
}

// SPDX-License-Identifier: MIT

import Darwin
import Foundation

private final class CodexRPCProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline: Date
    private var buffer = Data()
    private var requestID = 0
    private var started = false

    init(binaryURL: URL, environment: [String: String], deadline: Date) throws {
        self.deadline = deadline
        process.executableURL = binaryURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        started = true
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        do {
            _ = try request("initialize", parameters: [
                "clientInfo": ["name": "coding-rewind", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized", "params": [:]])
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        guard started else { return }
        try? input.fileHandleForWriting.close()
        process.waitForExit(within: 0.3)
        process.terminateGracefully()
        started = false
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, parameters: [String: Any]) throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": parameters])
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw RewindError.ioError("Codex returned an invalid response")
                }
                guard message["id"] as? Int == id else { continue }
                guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                    throw RewindError.ioError("Codex did not confirm \(method)")
                }
                return result
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
            } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                throw RewindError.ioError("Codex connection closed before confirmation")
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw RewindError.ioError("Codex confirmation timed out")
    }
}

public struct CodexConversationClient: Sendable {
    private enum QueueStep: Sendable {
        case queued(threadID: UUID, rawThreadID: String, clientID: String)
        case failed(ConversationReceipt.State)
    }

    private let binaryURL: URL
    private let environment: [String: String]
    private let languageProvider: @Sendable () -> AppLanguage
    private let wakeThread: @Sendable (UUID) async -> Bool

    public init(
        binaryURL: URL,
        environment: [String: String],
        language: AppLanguage = .zhHans,
        wakeThread: @escaping @Sendable (UUID) async -> Bool
    ) {
        self.init(
            binaryURL: binaryURL,
            environment: environment,
            languageProvider: { language },
            wakeThread: wakeThread
        )
    }

    public init(
        binaryURL: URL,
        environment: [String: String],
        languageProvider: @escaping @Sendable () -> AppLanguage,
        wakeThread: @escaping @Sendable (UUID) async -> Bool
    ) {
        self.binaryURL = binaryURL
        self.environment = environment
        self.languageProvider = languageProvider
        self.wakeThread = wakeThread
    }

    public func deliver(_ request: ConversationRequest, timeout: TimeInterval = 40) async -> (ConversationReceipt.State, String?) {
        let deadline = Date().addingTimeInterval(timeout)
        let binaryURL = self.binaryURL
        let environment = self.environment
        let threadName = L10n.codexThreadName(in: languageProvider())
        let step = await Self.runBlocking {
            Self.enqueuePrompt(
                request,
                threadName: threadName,
                binaryURL: binaryURL,
                environment: environment,
                deadline: deadline
            )
        }
        let threadID: UUID
        let rawThreadID: String
        let clientID: String
        switch step {
        case .queued(let id, let raw, let client):
            threadID = id
            rawThreadID = raw
            clientID = client
        case .failed(let state):
            return (state, nil)
        }
        guard await wakeThread(threadID) else { return (.unknown, nil) }
        return await Self.runBlocking {
            Self.confirmFirstTurn(
                prompt: request.prompt,
                rawThreadID: rawThreadID,
                clientID: clientID,
                binaryURL: binaryURL,
                environment: environment,
                deadline: deadline
            )
        }
    }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }

    private static func enqueuePrompt(
        _ request: ConversationRequest,
        threadName: String,
        binaryURL: URL,
        environment: [String: String],
        deadline: Date
    ) -> QueueStep {
        var attemptedThreadCreation = false
        do {
            let creator = try CodexRPCProcess(binaryURL: binaryURL, environment: environment, deadline: deadline)
            defer { creator.stop() }
            attemptedThreadCreation = true
            let started = try creator.request("thread/start", parameters: [
                "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
                "config": ["thread_unload_delay_secs": 0]
            ])
            guard let thread = started["thread"] as? [String: Any],
                  let id = thread["id"] as? String, let threadID = UUID(uuidString: id) else {
                throw RewindError.ioError("Codex did not return a thread ID")
            }
            _ = try creator.request("thread/name/set", parameters: ["threadId": id, "name": threadName])
            let unsubscribed = try creator.request("thread/unsubscribe", parameters: ["threadId": id])
            guard ["unsubscribed", "notLoaded"].contains(unsubscribed["status"] as? String ?? "") else {
                throw RewindError.ioError("Codex did not release the new thread")
            }
            creator.stop()

            let reader = try CodexRPCProcess(binaryURL: binaryURL, environment: environment, deadline: deadline)
            defer { reader.stop() }
            let empty = try reader.request("thread/read", parameters: ["threadId": id, "includeTurns": true])
            guard isEmptyReleasedThread(empty, id: id) else {
                throw RewindError.ioError("Codex thread was not empty and released")
            }
            let clientID = request.requestId.uuidString.lowercased()
            let queued = try reader.request("thread/queue/add", parameters: [
                "threadId": id, "clientUserMessageId": clientID,
                "input": [["type": "text", "text": request.prompt]]
            ])
            guard let submission = queued["queuedSubmission"] as? [String: Any],
                  let submissionID = submission["id"] as? String, !submissionID.isEmpty,
                  submission["clientUserMessageId"] as? String == clientID,
                  text(in: submission["input"])?.utf8.elementsEqual(request.prompt.utf8) == true else {
                throw RewindError.ioError("Codex did not confirm the queued prompt")
            }
            let queue = try reader.request("thread/queue/list", parameters: ["threadId": id])
            guard let entries = queue["data"] as? [[String: Any]], entries.count == 1,
                  entries[0]["id"] as? String == submissionID,
                  entries[0]["clientUserMessageId"] as? String == clientID,
                  text(in: entries[0]["input"])?.utf8.elementsEqual(request.prompt.utf8) == true,
                  queue["nextCursor"] == nil || queue["nextCursor"] is NSNull else {
                throw RewindError.ioError("Codex queue readback did not match the prompt")
            }
            let queuedThread = try reader.request("thread/read", parameters: ["threadId": id, "includeTurns": true])
            guard isEmptyReleasedThread(queuedThread, id: id) else {
                throw RewindError.ioError("Codex started the thread before App handoff")
            }
            return .queued(threadID: threadID, rawThreadID: id, clientID: clientID)
        } catch {
            return .failed(attemptedThreadCreation ? .unknown : .rejected)
        }
    }

    private static func confirmFirstTurn(
        prompt: String,
        rawThreadID: String,
        clientID: String,
        binaryURL: URL,
        environment: [String: String],
        deadline: Date
    ) -> (ConversationReceipt.State, String?) {
        do {
            let observer = try CodexRPCProcess(binaryURL: binaryURL, environment: environment, deadline: deadline)
            defer { observer.stop() }
            while Date() < deadline {
                let readback = try observer.request("thread/read", parameters: ["threadId": rawThreadID, "includeTurns": true])
                if let received = readback["thread"] as? [String: Any], received["id"] as? String == rawThreadID,
                   let turns = received["turns"] as? [[String: Any]],
                   let firstTurn = turns.first, let turnID = firstTurn["id"] as? String, !turnID.isEmpty,
                   let items = firstTurn["items"] as? [[String: Any]],
                   let user = items.first(where: { $0["type"] as? String == "userMessage" }),
                   user["clientId"] as? String == clientID,
                   text(in: user["content"])?.utf8.elementsEqual(prompt.utf8) == true {
                    return (.succeeded, rawThreadID)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return (.unknown, nil)
        } catch {
            return (.unknown, nil)
        }
    }

    private static func isEmptyReleasedThread(_ response: [String: Any], id: String) -> Bool {
        guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == id,
              let status = thread["status"] as? [String: Any], status["type"] as? String == "notLoaded",
              let turns = thread["turns"] as? [[String: Any]] else { return false }
        return turns.isEmpty
    }

    private static func text(in value: Any?) -> String? {
        guard let content = value as? [[String: Any]], !content.isEmpty,
              content.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String }) else { return nil }
        return content.compactMap { $0["text"] as? String }.joined()
    }
}

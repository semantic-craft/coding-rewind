// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Darwin
import Foundation

actor FakeSnippetBackend: SnippetQuerying {
    private var records: [SnippetRecord]
    private let resolution: SnippetResolutionMode
    private let pendingOutboxCount: Int
    private(set) var recordedListQueries: [SnippetQuery] = []
    private(set) var recordedGetCalls: [(id: String, includeContext: Bool)] = []
    private(set) var recordedArchiveIDs: [String] = []

    init(
        records: [SnippetRecord],
        resolution: SnippetResolutionMode = .online,
        pendingOutboxCount: Int = 0
    ) {
        self.records = records
        self.resolution = resolution
        self.pendingOutboxCount = pendingOutboxCount
    }

    func listSnippets(_ query: SnippetQuery, now: Date) async throws -> SnippetQueryResult {
        recordedListQueries.append(query)
        let filtered = records.filter { record in
            if let windowHours = query.windowHours {
                let cutoff = now.addingTimeInterval(-windowHours * 3600)
                if record.createdAt < cutoff { return false }
            }
            switch query.status {
            case .active:
                if record.status == .synthesized { return false }
            case .ready:
                if record.status != .ready { return false }
            case .pending:
                if record.status != .pending { return false }
            case .synthesized:
                if record.status != .synthesized { return false }
            case .all:
                break
            }
            if let src = query.sourcePlatform?.lowercased(), record.sourcePlatform.lowercased() != src {
                return false
            }
            if let q = query.searchText?.lowercased(), !q.isEmpty {
                let haystacks = [
                    record.title ?? "",
                    record.sessionTopic ?? "",
                    record.contextSummary ?? "",
                    record.keywords.joined(separator: " "),
                    record.sourceTitle,
                    record.verbatimText
                ]
                if !haystacks.contains(where: { $0.lowercased().contains(q) }) {
                    return false
                }
            }
            return true
        }
        .sorted { $0.createdAt > $1.createdAt }

        return SnippetQueryResult(
            snippets: Array(filtered.prefix(query.limit)),
            resolution: resolution,
            pendingOutboxCount: pendingOutboxCount
        )
    }

    func getSnippet(id: String, includeContext: Bool, now: Date) async throws -> SnippetRecord {
        recordedGetCalls.append((id: id, includeContext: includeContext))
        let cleanID = try MemosWireFormat.normalizeSnippetID(id)
        guard let found = records.first(where: { $0.id == cleanID }) else {
            throw RewindError.snippetNotFound(cleanID)
        }
        return includeContext ? found : found.withConversationContext(nil)
    }

    func archiveSnippet(id: String) async throws -> SnippetRecord {
        recordedArchiveIDs.append(id)
        let cleanID = try MemosWireFormat.normalizeSnippetID(id)
        guard let idx = records.firstIndex(where: { $0.id == cleanID }) else {
            throw RewindError.snippetNotFound(cleanID)
        }
        let existing = records[idx]
        let updated = SnippetRecord(
            id: existing.id,
            status: .synthesized,
            sourcePlatform: existing.sourcePlatform,
            title: existing.title,
            sessionTopic: existing.sessionTopic,
            contextSummary: existing.contextSummary,
            keywords: existing.keywords,
            sourceTitle: existing.sourceTitle,
            sourceURL: existing.sourceURL,
            verbatimText: existing.verbatimText,
            createdAt: existing.createdAt,
            dataOrigin: existing.dataOrigin,
            conversationContext: existing.conversationContext
        )
        records[idx] = updated
        return updated
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

final class LoopbackMemosHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let authorization: String?
        let body: Data
    }

    let port: UInt16
    var baseURLString: String { "http://127.0.0.1:\(port)" }

    private let listenFD: Int32
    private let lock = NSLock()
    private var closed = false
    private let handler: @Sendable (Request) -> (Int, Data)

    init(handler: @escaping @Sendable (Request) -> (Int, Data)) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 32) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.handler = handler

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func shutdown() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let fd = listenFD
        lock.unlock()
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    deinit {
        shutdown()
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                lock.lock()
                let isClosed = closed
                lock.unlock()
                if isClosed { return }
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let headerSep = Data("\r\n\r\n".utf8)
        var headerEndIndex: Int?
        var expectedContentLength = 0

        while true {
            let n = Darwin.read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            raw.append(buf, count: n)
            if headerEndIndex == nil, let range = raw.range(of: headerSep) {
                headerEndIndex = range.upperBound
                let headerText = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
                for line in headerText.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
                       let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                        expectedContentLength = max(0, len)
                    }
                }
            }
            if let endIdx = headerEndIndex, raw.count >= endIdx + expectedContentLength {
                break
            }
        }

        guard let endIdx = headerEndIndex, let sepRange = raw.range(of: headerSep) else { return }
        let headerText = String(decoding: raw[..<sepRange.lowerBound], as: UTF8.self)
        let headerLines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = headerLines.first else { return }
        let reqTokens = requestLine.split(separator: " ")
        guard reqTokens.count >= 2 else { return }
        let method = String(reqTokens[0])
        let target = String(reqTokens[1])

        var authHeader: String?
        for line in headerLines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" {
                authHeader = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let bodySliceEnd = min(raw.count, endIdx + expectedContentLength)
        let body = Data(raw[endIdx..<bodySliceEnd])
        let (status, respBody) = handler(Request(method: method, target: target, authorization: authHeader, body: body))

        let statusLine = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(respBody.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(statusLine.utf8)
        responseData.append(respBody)
        _ = CLIRunner.writeAll(responseData, to: clientFD)
    }
}

enum SnippetCLIFixtures {
    static let fixedNow = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

    static func makeIsolatedDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-cli-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func builtExecutableURL(named binaryName: String) throws -> URL {
        for bundle in Bundle.allBundles {
            let candidate = bundle.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(binaryName, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let fallbackDebug = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/\(binaryName)", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: fallbackDebug.path) {
            return fallbackDebug
        }
        throw NSError(domain: "SnippetCLIFixtures", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate built executable \(binaryName)"
        ])
    }

    static func makeSampleRecords() -> [SnippetRecord] {
        let verbatimCode = """
            Here is the exact Swift actor snippet:

            ```swift
            actor Counter {
                private var value = 0

                func next() -> Int {
                    value += 1
                    return value
                }
            }
            ```
            #rewind/ready inside body must remain untouched!
            """
        let context = CaptureContext(
            sessionTitle: "Swift Concurrency Isolation",
            prompt: "Show me an actor counter\nwith blank lines preserved.",
            recentTurns: [
                ConversationTurn(role: "user", text: "How do actors isolate state?"),
                ConversationTurn(role: "assistant", text: "Actors serialize mutable state access.")
            ]
        )
        return [
            SnippetRecord(
                id: "rw-recent-ready",
                status: .ready,
                sourcePlatform: "antigravity",
                title: "Actor Counter Pattern",
                sessionTopic: "Swift 6 Concurrency",
                contextSummary: "Actor state isolation example",
                keywords: ["swift", "actor"],
                sourceTitle: "Antigravity Session",
                sourceURL: "conversation://a216ac8b-30fc-4662-b3a6-949aee033024",
                verbatimText: verbatimCode,
                createdAt: fixedNow.addingTimeInterval(-6 * 3600),
                dataOrigin: .remote,
                conversationContext: context
            ),
            SnippetRecord(
                id: "rw-old-120h",
                status: .ready,
                sourcePlatform: "chatgpt",
                title: "Historical Architecture Note",
                sessionTopic: "MCP Transport",
                contextSummary: "Comparison from 5 days ago",
                keywords: ["mcp", "stdio"],
                sourceTitle: "ChatGPT Thread",
                sourceURL: "https://chatgpt.com/c/thread-120h",
                verbatimText: "Single binary CLI + stdio MCP avoids 41 generic tools.",
                createdAt: fixedNow.addingTimeInterval(-120 * 3600),
                dataOrigin: .remote
            ),
            SnippetRecord(
                id: "rw-archived-synth",
                status: .synthesized,
                sourcePlatform: "claude",
                title: "Synthesized Essay Draft",
                sourceTitle: "Claude Chat",
                sourceURL: "https://claude.ai/chat/synth-1",
                verbatimText: "Already synthesized verbatim paragraph.",
                createdAt: fixedNow.addingTimeInterval(-12 * 3600),
                dataOrigin: .remote
            )
        ]
    }
}

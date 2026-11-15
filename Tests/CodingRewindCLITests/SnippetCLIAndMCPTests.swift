// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Darwin
import Foundation
import Testing

private actor FakeSnippetBackend: SnippetQuerying {
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
        let cleanID = id.hasPrefix("memos/") ? String(id.dropFirst("memos/".count)) : id
        guard let found = records.first(where: { $0.id == cleanID }) else {
            throw RewindError.invalidClipID(cleanID)
        }
        if includeContext {
            return found
        }
        return SnippetRecord(
            id: found.id,
            status: found.status,
            sourcePlatform: found.sourcePlatform,
            title: found.title,
            sessionTopic: found.sessionTopic,
            contextSummary: found.contextSummary,
            keywords: found.keywords,
            sourceTitle: found.sourceTitle,
            sourceURL: found.sourceURL,
            verbatimText: found.verbatimText,
            createdAt: found.createdAt,
            dataOrigin: found.dataOrigin,
            conversationContext: nil
        )
    }

    func archiveSnippet(id: String) async throws -> SnippetRecord {
        recordedArchiveIDs.append(id)
        let cleanID = id.hasPrefix("memos/") ? String(id.dropFirst("memos/".count)) : id
        guard let idx = records.firstIndex(where: { $0.id == cleanID }) else {
            throw RewindError.invalidClipID(cleanID)
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

private final class OutputCollector: @unchecked Sendable {
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
        responseData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(clientFD, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                remaining -= written
                offset += written
            }
        }
    }
}

@Suite("CodingRewind Single-Binary CLI & MCP Suite")
struct SnippetCLIAndMCPTests {
    private static let fixedNow = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

    private func makeIsolatedDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data", isDirectory: true)
            .appendingPathComponent("snippet-cli-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func builtExecutableURL(named binaryName: String) throws -> URL {
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
        throw NSError(domain: "SnippetCLIAndMCPTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate built executable \(binaryName)"
        ])
    }

    private func makeSampleRecords() -> [SnippetRecord] {
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
                createdAt: Self.fixedNow.addingTimeInterval(-6 * 3600),
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
                createdAt: Self.fixedNow.addingTimeInterval(-120 * 3600),
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
                createdAt: Self.fixedNow.addingTimeInterval(-12 * 3600),
                dataOrigin: .remote
            )
        ]
    }

    @Test("CLIParser supports defaults, >72h windows, synthesized status, global flags anywhere, and strict validation")
    func cliParserBehavior() throws {
        let defaultList = try CLIParser.parse(arguments: ["coding-rewind", "list"])
        #expect(defaultList == .list(
            query: SnippetQuery(windowHours: 72, status: .active, sourcePlatform: nil, searchText: nil, limit: 50),
            dataDir: nil,
            json: false
        ))

        let allHistoryList = try CLIParser.parse(arguments: [
            "coding-rewind", "--json", "--data-dir", "/Users/shared/cr-data",
            "list", "--window", "all", "--status", "synthesized", "--source", "claude", "--limit", "200"
        ])
        #expect(allHistoryList == .list(
            query: SnippetQuery(windowHours: nil, status: .synthesized, sourcePlatform: "claude", searchText: nil, limit: 200),
            dataDir: "/Users/shared/cr-data",
            json: true
        ))

        let windowHoursSearch = try CLIParser.parse(arguments: [
            "coding-rewind", "search", "--window-hours=168", "--status=all", "--", "-flagLikeQuery"
        ])
        #expect(windowHoursSearch == .search(
            query: SnippetQuery(windowHours: 168, status: .all, sourcePlatform: nil, searchText: "-flagLikeQuery", limit: 50),
            dataDir: nil,
            json: false
        ))

        let getNoCtx = try CLIParser.parse(arguments: ["coding-rewind", "get", "memos/rw-1", "--no-context", "--json"])
        #expect(getNoCtx == .get(id: "rw-1", includeContext: false, dataDir: nil, json: true))

        #expect(throws: CLIValidationError.self) {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "list", "--limit", "0"])
        }
        #expect(throws: CLIValidationError.self) {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "list", "--limit", "501"])
        }
        #expect(throws: CLIValidationError.self) {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "list", "--window", "invalid"])
        }
        #expect(throws: CLIValidationError.self) {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "list", "--status", "bogus"])
        }
        #expect(throws: CLIValidationError.self) {
            _ = try CLIParser.parse(arguments: ["coding-rewind", "search"])
        }
    }

    @Test("CLIRunner executes list, search, get, and archive in both JSON and human modes preserving verbatim text")
    func cliRunnerEndToEndWithBackend() async throws {
        let dir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = FakeSnippetBackend(records: makeSampleRecords())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let out1 = OutputCollector()
        let err1 = OutputCollector()
        let code1 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { Self.fixedNow },
            writeStdout: out1.append,
            writeStderr: err1.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code1 == 0)
        #expect(err1.value().isEmpty)
        #expect(out1.value().contains("conversation://a216ac8b-30fc-4662-b3a6-949aee033024"))
        let defaultResult = try decoder.decode(SnippetQueryResult.self, from: Data(out1.value().utf8))
        #expect(defaultResult.snippets.map(\.id) == ["rw-recent-ready"])

        let out2 = OutputCollector()
        let code2 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--window", "all", "--status", "all", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { Self.fixedNow },
            writeStdout: out2.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code2 == 0)
        let fullResult = try decoder.decode(SnippetQueryResult.self, from: Data(out2.value().utf8))
        #expect(fullResult.snippets.map(\.id) == ["rw-recent-ready", "rw-archived-synth", "rw-old-120h"])

        let outGetHuman = OutputCollector()
        let codeGet = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-recent-ready", "--data-dir", dir.path],
            environment: [:],
            now: { Self.fixedNow },
            writeStdout: outGetHuman.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeGet == 0)
        let humanText = outGetHuman.value()
        #expect(humanText.contains("[Antigravity Session](conversation://a216ac8b-30fc-4662-b3a6-949aee033024)"))
        #expect(humanText.contains("### Conversation Context"))
        #expect(humanText.contains("#rewind/ready inside body must remain untouched!"))

        let outArchive = OutputCollector()
        let codeArchive = await CLIRunner.run(
            arguments: ["coding-rewind", "archive", "rw-recent-ready", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { Self.fixedNow },
            writeStdout: outArchive.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeArchive == 0)
        let archived = try decoder.decode(SnippetRecord.self, from: Data(outArchive.value().utf8))
        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText == makeSampleRecords()[0].verbatimText)
    }

    @Test("MCPServer handles lifecycle, notifications, 4 strict tools, type checks, and error codes")
    func mcpProtocolAndToolsUnit() async throws {
        let backend = FakeSnippetBackend(records: makeSampleRecords())
        let server = MCPServer(repositoryProvider: { backend }, now: { Self.fixedNow })

        func send(_ json: String) async throws -> JSONValue? {
            guard let responseData = await server.handleLine(Data(json.utf8)) else { return nil }
            let rawString = String(decoding: responseData, as: UTF8.self)
            #expect(rawString.hasSuffix("\n"))
            #expect(!rawString.dropLast().contains("\n"))
            return try JSONValue.decode(from: responseData)
        }

        let initResp = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#)
        guard case .object(let initObj) = initResp,
              case .object(let initResult) = initObj["result"] else {
            Issue.record("Missing initialize result")
            return
        }
        #expect(initObj["id"] == .int(1))
        #expect(initResult["protocolVersion"] == .string("2025-03-26"))
        #expect(initResult["capabilities"] == .object(["tools": .object([:])]))
        #expect(initResult["serverInfo"] == .object([
            "name": .string("coding-rewind"),
            "version": .string("0.3.2")
        ]))

        let fallbackInit = try await send(#"{"jsonrpc":"2.0","id":"init-2","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        if case .object(let obj) = fallbackInit, case .object(let res) = obj["result"] {
            #expect(obj["id"] == .string("init-2"))
            #expect(res["protocolVersion"] == .string("2024-11-05"))
        } else {
            Issue.record("Expected fallback protocolVersion response")
        }

        let notifResp = await server.handleLine(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notifResp == nil)

        let pingResp = try await send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        if case .object(let obj) = pingResp {
            #expect(obj["result"] == .object([:]))
        } else {
            Issue.record("Expected ping response")
        }

        let resourcesResp = try await send(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        if case .object(let obj) = resourcesResp {
            #expect(obj["result"] == .object(["resources": .array([])]))
        }

        let promptsResp = try await send(#"{"jsonrpc":"2.0","id":4,"method":"prompts/list"}"#)
        if case .object(let obj) = promptsResp {
            #expect(obj["result"] == .object(["prompts": .array([])]))
        }

        let toolsResp = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)
        guard case .object(let toolsObj) = toolsResp,
              case .object(let toolsRes) = toolsObj["result"],
              case .array(let tools) = toolsRes["tools"] else {
            Issue.record("Expected tools array")
            return
        }
        #expect(tools.count == 4)
        let names = tools.compactMap { item -> String? in
            guard case .object(let d) = item, case .string(let n) = d["name"] else { return nil }
            return n
        }
        #expect(names == ["list_snippets", "search_snippets", "get_snippet", "archive_snippet"])

        if case .object(let listDef) = tools[0],
           case .string(let desc) = listDef["description"],
           case .object(let schema) = listDef["inputSchema"],
           case .object(let annotations) = listDef["annotations"] {
            #expect(desc.contains("72h"))
            #expect(desc.contains("all"))
            #expect(desc.contains("synthesized"))
            #expect(schema["additionalProperties"] == .bool(false))
            #expect(annotations["readOnlyHint"] == .bool(true))
        } else {
            Issue.record("Malformed list_snippets definition")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let searchCall = try await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"search_snippets","arguments":{"query":"41 generic tools","window":"all"}}}"#)
        if case .object(let obj) = searchCall,
           case .object(let res) = obj["result"],
           case .array(let content) = res["content"],
           case .object(let first) = content.first,
           case .string(let text) = first["text"] {
            #expect(res["isError"] == .bool(false))
            let queryResult = try decoder.decode(SnippetQueryResult.self, from: Data(text.utf8))
            #expect(queryResult.snippets.map(\.id) == ["rw-old-120h"])
        } else {
            Issue.record("Expected search_snippets tool result")
        }

        let boolAsIntCall = try await send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_snippets","arguments":{"limit":true}}}"#)
        if case .object(let obj) = boolAsIntCall,
           case .object(let res) = obj["result"] {
            #expect(res["isError"] == .bool(true))
        } else {
            Issue.record("Expected isError: true when boolean is passed for integer limit")
        }

        let unknownKeyCall = try await send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_snippet","arguments":{"id":"rw-recent-ready","unexpected":1}}}"#)
        if case .object(let obj) = unknownKeyCall,
           case .object(let res) = obj["result"] {
            #expect(res["isError"] == .bool(true))
        } else {
            Issue.record("Expected isError: true on unknown argument")
        }

        let unknownMethod = try await send(#"{"jsonrpc":"2.0","id":9,"method":"unknown/method"}"#)
        if case .object(let obj) = unknownMethod,
           case .object(let err) = obj["error"] {
            #expect(err["code"] == .int(-32601))
        } else {
            Issue.record("Expected -32601 Method not found")
        }

        let parseErr = try await send("{broken json")
        if case .object(let obj) = parseErr,
           case .object(let err) = obj["error"] {
            #expect(err["code"] == .int(-32700))
        } else {
            Issue.record("Expected -32700 Parse error")
        }
    }

    @Test("Real coding-rewind subprocess handles CLI offline cache and stdio MCP pipe session cleanly")
    func subprocessCLIAndMCPPipes() throws {
        let dir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        let recentDate = Date().addingTimeInterval(-3600)
        let rawMemo = """
            #rewind/ready #source/antigravity
            > **Title:** Cached Offline Card
            > **Source:** [AGY Session](conversation://cached-session-1) · \(MemosWireFormat.formatISO8601UTC(recentDate))

            Exact cached body line 1
            Exact cached body line 2
            """
        if let card = MemosWireFormat.parseMemo(
            id: "rw-cached-1",
            rawContent: rawMemo,
            createdAt: recentDate,
            now: Date()
        ) {
            try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card], now: Date())
        }

        let binary = try builtExecutableURL(named: "coding-rewind")

        let cliOutPipe = Pipe()
        let cliErrPipe = Pipe()
        let cliProc = Process()
        cliProc.executableURL = binary
        cliProc.arguments = ["list", "--data-dir", dataDir.path, "--json"]
        cliProc.environment = [
            "PATH": "/usr/bin:/bin",
            "CODING_REWIND_QA": "1"
        ]
        cliProc.standardInput = FileHandle.nullDevice
        cliProc.standardOutput = cliOutPipe
        cliProc.standardError = cliErrPipe
        try cliProc.run()
        let cliOutData = cliOutPipe.fileHandleForReading.readDataToEndOfFile()
        let cliErrData = cliErrPipe.fileHandleForReading.readDataToEndOfFile()
        cliProc.waitUntilExit()

        #expect(cliProc.terminationStatus == 0)
        #expect(cliErrData.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cliDecoded = try decoder.decode(SnippetQueryResult.self, from: cliOutData)
        #expect(cliDecoded.resolution == .localOnly)
        #expect(cliDecoded.snippets.map(\.id) == ["rw-cached-1"])
        #expect(cliDecoded.snippets.first?.verbatimText == "Exact cached body line 1\nExact cached body line 2")

        let mcpInPipe = Pipe()
        let mcpOutPipe = Pipe()
        let mcpErrPipe = Pipe()
        let mcpProc = Process()
        mcpProc.executableURL = binary
        mcpProc.arguments = ["mcp", "--data-dir", dataDir.path]
        mcpProc.environment = [
            "PATH": "/usr/bin:/bin",
            "CODING_REWIND_QA": "1"
        ]
        mcpProc.standardInput = mcpInPipe
        mcpProc.standardOutput = mcpOutPipe
        mcpProc.standardError = mcpErrPipe
        try mcpProc.run()

        let inputMessages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_snippets","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#
        ].joined(separator: "\n") + "\n"

        mcpInPipe.fileHandleForWriting.write(Data(inputMessages.utf8))
        try mcpInPipe.fileHandleForWriting.close()

        let mcpOutData = mcpOutPipe.fileHandleForReading.readDataToEndOfFile()
        let mcpErrData = mcpErrPipe.fileHandleForReading.readDataToEndOfFile()
        mcpProc.waitUntilExit()

        #expect(mcpProc.terminationStatus == 0)
        #expect(mcpErrData.isEmpty)

        let lines = String(decoding: mcpOutData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 4)

        let thirdLine = try JSONValue.decode(from: Data(lines[2].utf8))
        if case .object(let obj) = thirdLine,
           case .object(let res) = obj["result"],
           case .array(let content) = res["content"],
           case .object(let textItem) = content.first,
           case .string(let payload) = textItem["text"] {
            #expect(obj["id"] == .int(3))
            #expect(res["isError"] == .bool(false))
            let mcpListResult = try decoder.decode(SnippetQueryResult.self, from: Data(payload.utf8))
            #expect(mcpListResult.snippets.map(\.id) == ["rw-cached-1"])
        } else {
            Issue.record("Unexpected tools/call response on line 3: \(lines[2])")
        }
    }

    @Test("Real coding-rewind CLI and MCP subprocesses integrate with live SnippetRepository pagination, >72h/synthesized queries, verbatim archive, and credential isolation")
    func liveSubprocessHTTPPaginationArchiveAndIsolation() throws {
        let dir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let recentReadyTime = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-4 * 3600))
        let recentPendingTime = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-8 * 3600))
        let old120hTime = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-120 * 3600))
        let synthesizedTime = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-10 * 3600))

        let verbatimBody = """
            Exact multiline body:

            ```swift
            func preserveMe() -> String {
                return "#rewind/ready literal inside code"
            }
            ```
            Trailing line with UTF-8 中文保真.
            """

        let initialReadyContent = """
            #rewind/ready #source/antigravity
            > **Title:** Live Ready Card
            > **Session:** Native MCP Convergence
            > **Context:** Verifying single binary over loopback HTTP
            > **Keywords:** mcp, swift
            > **Source:** [AGY Live](conversation://live-conv-42) · \(recentReadyTime)

            \(verbatimBody)
            """

        let pendingContent = """
            #rewind/pending #source/chatgpt
            > **Source:** [ChatGPT Live](https://chatgpt.com/c/live-pending) · \(recentPendingTime)

            Pending snippet body.
            """

        let old120hContent = """
            #rewind/ready #source/claude
            > **Title:** Five Days Old Card
            > **Source:** [Claude Thread](https://claude.ai/chat/old-120h) · \(old120hTime)

            Deep historical insight from 120 hours ago.
            """

        let synthesizedContent = """
            #rewind/synthesized #source/gemini
            > **Title:** Archived Gemini Card
            > **Source:** [Gemini Chat](https://gemini.google.com/app/synth-99) · \(synthesizedTime)

            Previously synthesized body.
            """

        let commentMarkdown = """
            <!-- rewind-context-v1 -->
            Session Title: Native MCP Convergence
            Prompt: Explain why single binary beats 41 tools
            with zero Node runtime dependencies.

            ### Recent Turns
            user: Should we keep memos-mcp-bridge.sh?
            assistant: No, embed stdio MCP directly in coding-rewind.
            """

        final class MockMemosStore: @unchecked Sendable {
            private let lock = NSLock()
            var memosByID: [String: (content: String, createTime: String)]
            let page1IDs: [String]
            let page2IDs: [String]
            let commentsByMemoID: [String: String]
            let commentCreateTime: String

            init(
                memosByID: [String: (content: String, createTime: String)],
                page1IDs: [String],
                page2IDs: [String],
                commentsByMemoID: [String: String],
                commentCreateTime: String
            ) {
                self.memosByID = memosByID
                self.page1IDs = page1IDs
                self.page2IDs = page2IDs
                self.commentsByMemoID = commentsByMemoID
                self.commentCreateTime = commentCreateTime
            }

            func handle(_ req: LoopbackMemosHTTPServer.Request) -> (Int, Data) {
                guard req.authorization == "Bearer qa-live-token" else {
                    return (401, Data(#"{"message":"unauthorized"}"#.utf8))
                }
                guard let comps = URLComponents(string: "http://localhost\(req.target)") else {
                    return (400, Data(#"{"message":"bad url"}"#.utf8))
                }
                let path = comps.path
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]

                lock.lock()
                defer { lock.unlock() }

                if req.method == "GET" && path == "/api/memos" {
                    let pageToken = comps.queryItems?.first(where: { $0.name == "pageToken" })?.value ?? ""
                    let ids = pageToken == "page-2" ? page2IDs : page1IDs
                    let next = pageToken == "page-2" ? "" : "page-2"
                    let items: [[String: String]] = ids.compactMap { id in
                        guard let entry = memosByID[id] else { return nil }
                        return [
                            "name": "memos/\(id)",
                            "content": entry.content,
                            "createTime": entry.createTime
                        ]
                    }
                    let payload: [String: Any] = ["memos": items, "nextPageToken": next]
                    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                    return (200, data)
                }

                if req.method == "GET" && path.hasPrefix("/api/memos/") && path.hasSuffix("/comments") {
                    let mid = path
                        .replacingOccurrences(of: "/api/memos/", with: "")
                        .replacingOccurrences(of: "/comments", with: "")
                    if let comment = commentsByMemoID[mid] {
                        let payload: [String: Any] = [
                            "memos": [[
                                "name": "memos/\(mid)-ctx",
                                "content": comment,
                                "createTime": commentCreateTime
                            ]],
                            "nextPageToken": ""
                        ]
                        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                        return (200, data)
                    }
                    return (200, Data(#"{"memos":[],"nextPageToken":""}"#.utf8))
                }

                if req.method == "GET" && path.hasPrefix("/api/memos/") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    guard let entry = memosByID[mid] else {
                        return (404, Data(#"{"message":"not found"}"#.utf8))
                    }
                    let dto = MemoWireDTO(name: "memos/\(mid)", content: entry.content, createTime: entry.createTime)
                    return (200, (try? encoder.encode(dto)) ?? Data())
                }

                if req.method == "PATCH" && path.hasPrefix("/api/memos/") {
                    let mid = String(path.dropFirst("/api/memos/".count))
                    guard let existing = memosByID[mid],
                          let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
                          let updatedContent = obj["content"] as? String else {
                        return (400, Data(#"{"message":"bad patch"}"#.utf8))
                    }
                    memosByID[mid] = (content: updatedContent, createTime: existing.createTime)
                    let dto = MemoWireDTO(name: "memos/\(mid)", content: updatedContent, createTime: existing.createTime)
                    return (200, (try? encoder.encode(dto)) ?? Data())
                }

                return (404, Data(#"{"message":"unknown route"}"#.utf8))
            }
        }

        let store = MockMemosStore(
            memosByID: [
                "rw-live-ready": (initialReadyContent, recentReadyTime),
                "non-rewind-note": ("Just a shopping list without rewind tags", recentReadyTime),
                "rw-live-pending": (pendingContent, recentPendingTime),
                "rw-live-120h": (old120hContent, old120hTime),
                "rw-live-synth": (synthesizedContent, synthesizedTime)
            ],
            page1IDs: ["rw-live-ready", "non-rewind-note"],
            page2IDs: ["rw-live-pending", "rw-live-120h", "rw-live-synth"],
            commentsByMemoID: ["rw-live-ready": commentMarkdown],
            commentCreateTime: recentReadyTime
        )

        let server = try LoopbackMemosHTTPServer { store.handle($0) }
        defer { server.shutdown() }

        let dataDir = dir.appendingPathComponent("LiveData", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        try paths.saveMemosURLString(server.baseURLString)

        let binary = try builtExecutableURL(named: "coding-rewind")
        let baseEnv = [
            "PATH": "/usr/bin:/bin",
            "CODING_REWIND_QA": "1",
            "CODING_REWIND_MEMOS_TOKEN": "qa-live-token"
        ]

        func runCLI(_ args: [String], env: [String: String] = baseEnv) throws -> (Int32, Data, Data) {
            let outPipe = Pipe()
            let errPipe = Pipe()
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = args + ["--data-dir", dataDir.path]
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, out, err)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (stDefault, outDefault, errDefault) = try runCLI(["list", "--json"])
        #expect(stDefault == 0)
        #expect(errDefault.isEmpty)
        let resDefault = try decoder.decode(SnippetQueryResult.self, from: outDefault)
        #expect(resDefault.resolution == .online)
        #expect(resDefault.snippets.map(\.id) == ["rw-live-ready", "rw-live-pending"])

        let (stAllWin, outAllWin, _) = try runCLI(["list", "--window", "all", "--json"])
        #expect(stAllWin == 0)
        let resAllWin = try decoder.decode(SnippetQueryResult.self, from: outAllWin)
        #expect(resAllWin.snippets.map(\.id) == ["rw-live-ready", "rw-live-pending", "rw-live-120h"])

        let (stSynth, outSynth, _) = try runCLI(["list", "--window", "all", "--status", "synthesized", "--json"])
        #expect(stSynth == 0)
        let resSynth = try decoder.decode(SnippetQueryResult.self, from: outSynth)
        #expect(resSynth.snippets.map(\.id) == ["rw-live-synth"])

        let (stGet, outGet, _) = try runCLI(["get", "memos/rw-live-ready", "--json"])
        #expect(stGet == 0)
        let gotReady = try decoder.decode(SnippetRecord.self, from: outGet)
        #expect(gotReady.verbatimText == verbatimBody)
        #expect(gotReady.conversationContext?.prompt.contains("zero Node runtime dependencies") == true)
        #expect(gotReady.conversationContext?.recentTurns.count == 2)

        let mcpIn = Pipe()
        let mcpOut = Pipe()
        let mcpErr = Pipe()
        let mcpProc = Process()
        mcpProc.executableURL = binary
        mcpProc.arguments = ["mcp", "--data-dir", dataDir.path]
        mcpProc.environment = baseEnv
        mcpProc.standardInput = mcpIn
        mcpProc.standardOutput = mcpOut
        mcpProc.standardError = mcpErr
        try mcpProc.run()

        let mcpCalls = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_snippets","arguments":{"query":"120 hours","window":"all"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"archive_snippet","arguments":{"id":"memos/rw-live-ready"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_snippets","arguments":{"status":"synthesized","window":"all"}}}"#
        ].joined(separator: "\n") + "\n"
        mcpIn.fileHandleForWriting.write(Data(mcpCalls.utf8))
        try mcpIn.fileHandleForWriting.close()
        let mcpRespData = mcpOut.fileHandleForReading.readDataToEndOfFile()
        let mcpErrData = mcpErr.fileHandleForReading.readDataToEndOfFile()
        mcpProc.waitUntilExit()

        #expect(mcpProc.terminationStatus == 0)
        #expect(mcpErrData.isEmpty)
        let mcpLines = String(decoding: mcpRespData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(mcpLines.count == 3)

        if case .object(let archObj) = try JSONValue.decode(from: Data(mcpLines[1].utf8)),
           case .object(let archRes) = archObj["result"],
           case .array(let archContent) = archRes["content"],
           case .object(let archItem) = archContent.first,
           case .string(let archText) = archItem["text"] {
            #expect(archRes["isError"] == .bool(false))
            let archivedRecord = try decoder.decode(SnippetRecord.self, from: Data(archText.utf8))
            #expect(archivedRecord.status == .synthesized)
            #expect(archivedRecord.verbatimText == verbatimBody)
        } else {
            Issue.record("Expected archive_snippet result")
        }

        if case .object(let synthObj) = try JSONValue.decode(from: Data(mcpLines[2].utf8)),
           case .object(let synthRes) = synthObj["result"],
           case .array(let synthContent) = synthRes["content"],
           case .object(let synthItem) = synthContent.first,
           case .string(let synthText) = synthItem["text"] {
            let synthList = try decoder.decode(SnippetQueryResult.self, from: Data(synthText.utf8))
            #expect(synthList.snippets.map(\.id) == ["rw-live-ready", "rw-live-synth"])
        } else {
            Issue.record("Expected synthesized list_snippets result")
        }

        try AtomicFile.writeUTF8("not a valid plist", to: paths.developerCredentialsFileURL, permissions: 0o600)
        let (stIsolated, outIsolated, _) = try runCLI(
            ["list", "--json"],
            env: [
                "PATH": "/usr/bin:/bin",
                "CODING_REWIND_QA": "0"
            ]
        )
        #expect(stIsolated == 0)
        let isolatedRes = try decoder.decode(SnippetQueryResult.self, from: outIsolated)
        if case .offlineFallback = isolatedRes.resolution {
            #expect(isolatedRes.snippets.map(\.id) == ["rw-live-pending"])
        } else {
            Issue.record("Expected offlineFallback when DeveloperCredentials.plist is invalid without personal Keychain fallback, got \(isolatedRes.resolution)")
        }
    }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Darwin
import Foundation
import Testing

@Suite("CodingRewind Embedded MCP Server Suite")
struct SnippetMCPServerTests {
    @Test("MCPServer enforces strict JSON-RPC 2.0 id/header framing, v0.6.0 serverInfo, and window mutual exclusion")
    func mcpProtocolAndToolsUnit() async throws {
        let backend = FakeSnippetBackend(records: SnippetCLIFixtures.makeSampleRecords())
        let server = MCPServer(repositoryProvider: { backend }, now: { SnippetCLIFixtures.fixedNow })

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
            "version": .string("0.6.0")
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

        for nonScalarIDPayload in [
            #"{"id":true,"jsonrpc":"2.0","method":"ping"}"#,
            #"{"id":[1,2],"foo":"bar"}"#,
            #"{"id":{"nested":1}}"#
        ] {
            let badIDResp = try await send(nonScalarIDPayload)
            if case .object(let obj) = badIDResp,
               case .object(let err) = obj["error"] {
                #expect(obj["id"] == .null)
                #expect(err["code"] == .int(-32600))
                #expect(err["message"] == .string("Invalid Request: invalid id type"))
            } else {
                Issue.record("Expected -32600 with id:null for \(nonScalarIDPayload)")
            }
        }

        for invalidEnvelope in [
            #"{"foo":"bar"}"#,
            #"{"jsonrpc":"2.0","method":""}"#,
            #"{"jsonrpc":"1.0","method":"ping"}"#
        ] {
            let invalidResp = try await send(invalidEnvelope)
            if case .object(let obj) = invalidResp,
               case .object(let err) = obj["error"] {
                #expect(obj["id"] == .null)
                #expect(err["code"] == .int(-32600))
                #expect(err["message"] == .string("Invalid Request"))
            } else {
                Issue.record("Expected -32600 Invalid Request for \(invalidEnvelope)")
            }
        }

        let invalidWithScalarID = try await send(#"{"id":42,"jsonrpc":"1.0","method":"ping"}"#)
        if case .object(let obj) = invalidWithScalarID,
           case .object(let err) = obj["error"] {
            #expect(obj["id"] == .int(42))
            #expect(err["code"] == .int(-32600))
        } else {
            Issue.record("Expected -32600 echoing scalar id 42")
        }

        let toolsResp = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)
        guard case .object(let toolsObj) = toolsResp,
              case .object(let toolsRes) = toolsObj["result"],
              case .array(let tools) = toolsRes["tools"] else {
            Issue.record("Expected tools array")
            return
        }
        let toolNames: [String] = tools.compactMap { item in
            guard case .object(let obj) = item, case .string(let name) = obj["name"] else {
                return nil
            }
            return name
        }
        #expect(toolNames == [
            "list_snippets",
            "search_snippets",
            "get_snippet",
            "archive_snippet",
            "create_snippet",
            "update_snippet_metadata",
            "append_snippet_note"
        ])
        #expect(!toolNames.contains("delete_snippet"))
        #expect(!toolNames.contains("delete"))

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

        let bothWindowsCall = try await send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_snippets","arguments":{"window":"72h","window_hours":24}}}"#)
        if case .object(let obj) = bothWindowsCall,
           case .object(let res) = obj["result"],
           case .array(let content) = res["content"],
           case .object(let first) = content.first,
           case .string(let text) = first["text"] {
            #expect(res["isError"] == .bool(true))
            #expect(text.contains("Specify either 'window' or 'window_hours', not both."))
        } else {
            Issue.record("Expected mutual exclusion error when both window and window_hours are passed")
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

        let deleteToolCall = try await send(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"delete_snippet","arguments":{"id":"rw-recent-ready"}}}"#)
        if case .object(let obj) = deleteToolCall,
           case .object(let res) = obj["result"],
           case .array(let content) = res["content"],
           case .object(let first) = content.first,
           case .string(let text) = first["text"] {
            #expect(res["isError"] == .bool(true))
            #expect(text.contains("Unknown tool 'delete_snippet'"))
        } else {
            Issue.record("Expected isError: true when calling disallowed delete_snippet tool")
        }
        #expect(await backend.recordedDeleteIDs.isEmpty)
        let retained = try await backend.getSnippet(id: "rw-recent-ready", includeContext: false, now: SnippetCLIFixtures.fixedNow)
        #expect(retained.id == "rw-recent-ready")
    }

    @Test("MCPServer enforces 4 MiB line cap without stalling subsequent frames and terminates cleanly on broken output pipe")
    func mcpOversizedLineCapAndBrokenOutputPipe() async throws {
        let backend = FakeSnippetBackend(records: [])
        let server = MCPServer(repositoryProvider: { backend }, now: { SnippetCLIFixtures.fixedNow })

        let inPipe = Pipe()
        let outPipe = Pipe()
        let runTask = Task {
            await server.run(
                inputFD: inPipe.fileHandleForReading.fileDescriptor,
                outputFD: outPipe.fileHandleForWriting.fileDescriptor
            )
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var payload = Data(repeating: 0x61, count: MCPServer.maxLineBytes + 1024)
            payload.append(0x0A)
            payload.append(contentsOf: #"{"jsonrpc":"2.0","id":99,"method":"ping"}"#.utf8)
            payload.append(0x0A)
            _ = CLIRunner.writeAll(payload, to: inPipe.fileHandleForWriting.fileDescriptor)
            try? inPipe.fileHandleForWriting.close()
        }

        let exitCode = await runTask.value
        try? outPipe.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        #expect(exitCode == 0)

        let outLines = String(decoding: outData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(outLines.count == 2)
        if case .object(let errObj) = try JSONValue.decode(from: Data(outLines[0].utf8)),
           case .object(let errBody) = errObj["error"] {
            #expect(errObj["id"] == .null)
            #expect(errBody["code"] == .int(-32600))
        } else {
            Issue.record("Expected -32600 response for oversized line")
        }
        if case .object(let pingObj) = try JSONValue.decode(from: Data(outLines[1].utf8)) {
            #expect(pingObj["id"] == .int(99))
            #expect(pingObj["result"] == .object([:]))
        } else {
            Issue.record("Expected ping response after oversized line recovery")
        }

        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let subIn = Pipe()
        let subOut = Pipe()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["mcp", "--data-dir", dir.path]
        proc.environment = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
        proc.standardInput = subIn
        proc.standardOutput = subOut
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        try subOut.fileHandleForReading.close()
        _ = CLIRunner.writeUTF8(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n", to: subIn.fileHandleForWriting.fileDescriptor)
        proc.waitUntilExit()
        try? subIn.fileHandleForWriting.close()

        #expect(proc.terminationReason == .exit)
        #expect(proc.terminationStatus == 1)
    }

    @Test("Real coding-rewind mcp session caches resolved 1Password token across multiple tools/call requests")
    func mcpSessionCachesResolvedDeveloperCredentialsAcrossToolCalls() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let isoNow = MemosWireFormat.formatISO8601UTC(now)
        let memoContent = """
            #rewind/ready #source/antigravity
            > **Title:** Session Cached Token Card
            > **Source:** [AGY](conversation://token-cache-1) · \(isoNow)

            Verbatim body for session token caching test.
            """

        final class SingleMemoBox: @unchecked Sendable {
            private let lock = NSLock()
            var content: String
            init(_ content: String) { self.content = content }
            func get() -> String { lock.lock(); defer { lock.unlock() }; return content }
            func set(_ v: String) { lock.lock(); content = v; lock.unlock() }
        }
        let memoBox = SingleMemoBox(memoContent)

        let server = try LoopbackMemosHTTPServer { req in
            guard req.authorization == "Bearer session-cached-op-token" else {
                return (401, Data(#"{"message":"unauthorized"}"#.utf8))
            }
            guard let comps = URLComponents(string: "http://localhost\(req.target)") else {
                return (400, Data())
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]

            if req.method == "GET" && comps.path == "/api/memos" {
                let payload: [String: Any] = [
                    "memos": [[
                        "name": "memos/rw-tok-1",
                        "content": memoBox.get(),
                        "createTime": isoNow
                    ]],
                    "nextPageToken": ""
                ]
                return (200, try! JSONSerialization.data(withJSONObject: payload))
            }
            if req.method == "GET" && comps.path == "/api/memos/rw-tok-1/comments" {
                return (200, Data(#"{"memos":[],"nextPageToken":""}"#.utf8))
            }
            if req.method == "GET" && comps.path == "/api/memos/rw-tok-1" {
                let dto = MemoWireDTO(name: "memos/rw-tok-1", content: memoBox.get(), createTime: isoNow)
                return (200, try! encoder.encode(dto))
            }
            if req.method == "PATCH" && comps.path == "/api/memos/rw-tok-1" {
                let obj = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
                let updated = obj["content"] as? String ?? memoBox.get()
                memoBox.set(updated)
                let dto = MemoWireDTO(name: "memos/rw-tok-1", content: updated, createTime: isoNow)
                return (200, try! encoder.encode(dto))
            }
            return (404, Data())
        }
        defer { server.shutdown() }

        let dataDir = dir.appendingPathComponent("SessionData", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        try paths.saveMemosURLString(server.baseURLString)

        let opCountFile = dir.appendingPathComponent("op-invocations.log")
        let fakeOp = dir.appendingPathComponent("fake-op")
        try AtomicFile.writeUTF8(
            """
            #!/bin/sh
            printf 'invoked\\n' >> "\(opCountFile.path)"
            printf 'session-cached-op-token'
            """,
            to: fakeOp,
            permissions: 0o755
        )
        let plistData = try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://vault/memos/token",
            "op_executable": fakeOp.path
        ], format: .xml, options: 0)
        try AtomicFile.writeData(plistData, to: paths.developerCredentialsFileURL, permissions: 0o600)

        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let mcpIn = Pipe()
        let mcpOut = Pipe()
        let mcpErr = Pipe()
        let mcpProc = Process()
        mcpProc.executableURL = binary
        mcpProc.arguments = ["mcp", "--data-dir", dataDir.path]
        mcpProc.environment = [
            "PATH": "/usr/bin:/bin",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]
        mcpProc.standardInput = mcpIn
        mcpProc.standardOutput = mcpOut
        mcpProc.standardError = mcpErr
        try mcpProc.run()

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_snippets","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_snippet","arguments":{"id":"rw-tok-1"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"archive_snippet","arguments":{"id":"rw-tok-1"}}}"#
        ].joined(separator: "\n") + "\n"
        mcpIn.fileHandleForWriting.write(Data(requests.utf8))
        try mcpIn.fileHandleForWriting.close()

        let outData = mcpOut.fileHandleForReading.readDataToEndOfFile()
        let errData = mcpErr.fileHandleForReading.readDataToEndOfFile()
        mcpProc.waitUntilExit()

        #expect(mcpProc.terminationStatus == 0)
        #expect(errData.isEmpty)

        let lines = String(decoding: outData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        for line in lines {
            if case .object(let obj) = try JSONValue.decode(from: Data(line.utf8)),
               case .object(let res) = obj["result"] {
                #expect(res["isError"] == .bool(false))
            } else {
                Issue.record("Unexpected tool call failure: \(line)")
            }
        }

        let invocationLines = try String(contentsOf: opCountFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(invocationLines.count == 1)
    }

    @Test("Real coding-rewind CLI and MCP subprocesses integrate with live SnippetRepository pagination, >72h/synthesized queries, verbatim archive, and credential isolation")
    func liveSubprocessHTTPPaginationArchiveAndIsolation() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
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

        let seededReadyCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-live-ready",
            rawContent: initialReadyContent,
            createdAt: now.addingTimeInterval(-4 * 3600),
            now: now
        ))
        let seededPendingCard = try #require(MemosWireFormat.parseMemo(
            id: "rw-live-pending",
            rawContent: pendingContent,
            createdAt: now.addingTimeInterval(-8 * 3600),
            now: now
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([seededReadyCard, seededPendingCard], now: now)

        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
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

// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

@Suite("CodingRewindCLI Subprocess & Integration Suite")
struct CodingRewindCLITests {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-rewind-cli-tests-\(UUID().uuidString)", isDirectory: true)
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
        throw NSError(domain: "CodingRewindCLITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate built executable \(binaryName)"
        ])
    }

    private func runSubprocess(
        executableURL: URL,
        stdinData: Data,
        environmentOverrides: [String: String]
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data, elapsedMilliseconds: Double) {
        let process = Process()
        process.executableURL = executableURL

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environmentOverrides {
            env[k] = v
        }
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let startNanos = DispatchTime.now().uptimeNanoseconds
        try process.run()
        inPipe.fileHandleForWriting.write(stdinData)
        try? inPipe.fileHandleForWriting.close()

        let stdoutData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let endNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedMS = Double(endNanos - startNanos) / 1_000_000.0

        return (process.terminationStatus, stdoutData, stderrData, elapsedMS)
    }

    @Test("coding-rewind-hook subprocess finishes in <50ms on a multi-MB synthetic transcript and records ActiveAntigravityTurn")
    func hookSubprocessLatencyAndReverseTailExtraction() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appSupportDir = tempDir.appendingPathComponent("AppSupport", isDirectory: true)
        let transcriptURL = tempDir.appendingPathComponent("transcript.jsonl", isDirectory: false)

        let fillerLine = "{\"type\":\"MODEL_OUTPUT\",\"content\":\"[SYNTHETIC] padding line for multi-MB transcript test 0123456789abcdef\"}\n"
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        let chunk = Data(String(repeating: fillerLine, count: 1024).utf8)
        for _ in 0..<32 {
            handle.write(chunk)
        }
        let targetUserLine = """
        {"type":"USER_INPUT","source":"USER_EXPLICIT","content":[{"text":"[SYNTHETIC] 请问如何让 NSPanel 既能响应点击又不会抢走 Antigravity 的焦点？"}]}
        {"type":"MODEL_OUTPUT","content":"[SYNTHETIC] 使用 .nonactivatingPanel 样式掩码。"}
        """
        handle.write(Data((targetUserLine + "\n").utf8))
        try handle.close()

        let fileSize = (try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(fileSize > 2_500_000)

        let hookExe = try builtExecutableURL(named: "coding-rewind-hook")
        let warmupStdin = try JSONSerialization.data(withJSONObject: [
            "conversation_id": "warmup-conv",
            "transcript_path": transcriptURL.path,
            "cwd": "/tmp/synthetic-ws"
        ])
        _ = try runSubprocess(
            executableURL: hookExe,
            stdinData: warmupStdin,
            environmentOverrides: [StoragePaths.appSupportEnvironmentKey: appSupportDir.path]
        )

        let stdinPayload = try JSONSerialization.data(withJSONObject: [
            "conversationId": "synthetic-live-conv-42",
            "transcriptPath": transcriptURL.path,
            "cwd": "/tmp/synthetic-antigravity-repo"
        ])
        let runResult = try runSubprocess(
            executableURL: hookExe,
            stdinData: stdinPayload,
            environmentOverrides: [StoragePaths.appSupportEnvironmentKey: appSupportDir.path]
        )

        #expect(runResult.exitCode == 0)
        #expect(String(decoding: runResult.stdout, as: UTF8.self) == "{}\n")
        #expect(runResult.elapsedMilliseconds < 50.0)

        let paths = try StoragePaths(appSupportDirectoryURL: appSupportDir)
        let turnStore = try ActiveTurnStore(directoryURL: paths.runtimeDirectoryURL)
        let recorded = try turnStore.latestTurn(forFrontmostBundleID: CapturedSelection.antigravityBundleIdentifier)
        #expect(recorded?.conversationId == "synthetic-live-conv-42")
        #expect(recorded?.workspacePath == "/tmp/synthetic-antigravity-repo")
        #expect(recorded?.userPrompt == "[SYNTHETIC] 请问如何让 NSPanel 既能响应点击又不会抢走 Antigravity 的焦点？")
    }

    @Test("coding-rewind-hook skips subagents and handles malformed stdin while unconditionally printing {}")
    func hookSubprocessSkipsSubagentsAndHandlesMalformedInput() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appSupportDir = tempDir.appendingPathComponent("AppSupport", isDirectory: true)
        let transcriptURL = tempDir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        try "{\"type\":\"USER_INPUT\",\"source\":\"USER\",\"content\":\"[SYNTHETIC] Should be skipped\"}\n"
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let hookExe = try builtExecutableURL(named: "coding-rewind-hook")
        let stdinPayload = try JSONSerialization.data(withJSONObject: [
            "conversationId": "subagent-conv",
            "transcriptPath": transcriptURL.path
        ])

        for subEnv in [
            ["ANTIGRAVITY_SUBAGENT_ID": "sub-99"],
            ["SUBAGENT": "1"],
            ["IS_SUBAGENT": "1"]
        ] {
            var env = subEnv
            env[StoragePaths.appSupportEnvironmentKey] = appSupportDir.path
            let result = try runSubprocess(executableURL: hookExe, stdinData: stdinPayload, environmentOverrides: env)
            #expect(result.exitCode == 0)
            #expect(String(decoding: result.stdout, as: UTF8.self) == "{}\n")
        }

        let paths = try StoragePaths(appSupportDirectoryURL: appSupportDir)
        let turnStore = try ActiveTurnStore(directoryURL: paths.runtimeDirectoryURL)
        #expect(try turnStore.retainedSnapshotFileURLs().isEmpty)

        let malformedResult = try runSubprocess(
            executableURL: hookExe,
            stdinData: Data("<<<not-valid-json>>>".utf8),
            environmentOverrides: [StoragePaths.appSupportEnvironmentKey: appSupportDir.path]
        )
        #expect(malformedResult.exitCode == 0)
        #expect(String(decoding: malformedResult.stdout, as: UTF8.self) == "{}\n")
    }

    @Test("rewind-mcp subprocess serves newline-delimited and Content-Length JSON-RPC 2.0 concurrently over SQLite WAL")
    func rewindMCPSubprocessConcurrentWALReadAndProtocolFraming() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appSupportDir = tempDir.appendingPathComponent("AppSupport", isDirectory: true)
        let paths = try StoragePaths(appSupportDirectoryURL: appSupportDir)
        let writerStore = try StashStore(location: .sqliteFile(paths.stashDatabaseURL), mode: .readWrite)

        let initialClip = try await writerStore.capture(
            NewClip(
                excerpt: "[SYNTHETIC] Initial WAL clip before MCP launch: NSPanel nonactivatingPanel HUD.",
                promptContext: .captured("[SYNTHETIC] Initial prompt?"),
                source: .antigravity(conversationId: "conv-wal-1", workspacePath: "/tmp/wal", locator: "conversation://conv-wal-1")
            )
        )

        let concurrentClip = try await writerStore.capture(
            NewClip(
                excerpt: "[SYNTHETIC] Concurrent WAL write while writerStore is open: SQLite FTS5 zero residual tokens.",
                promptContext: .missing,
                source: .web(site: .claude, url: "https://claude.ai/chat/synthetic-wal", pageTitle: "WAL Test")
            )
        )

        let mcpExe = try builtExecutableURL(named: "rewind-mcp")
        let lineRequests = [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"rewind_list_hot_clips\",\"arguments\":{\"limit\":10}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"rewind_search_clips\",\"arguments\":{\"query\":\"FTS5 zero residual\"}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"rewind_get_clip\",\"arguments\":{\"clip_id\":\"\(initialClip.id.rawValue)\"}}}"
        ].joined(separator: "\n") + "\n"

        let lineRun = try runSubprocess(
            executableURL: mcpExe,
            stdinData: Data(lineRequests.utf8),
            environmentOverrides: [StoragePaths.appSupportEnvironmentKey: appSupportDir.path]
        )
        #expect(lineRun.exitCode == 0)
        #expect(lineRun.stderr.isEmpty)

        let stdoutLines = String(decoding: lineRun.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(stdoutLines.count == 5)

        let listResponse = String(stdoutLines[2])
        #expect(listResponse.contains(initialClip.id.rawValue))
        #expect(listResponse.contains(concurrentClip.id.rawValue))

        let searchResponse = String(stdoutLines[3])
        #expect(searchResponse.contains(concurrentClip.id.rawValue))

        let getResponse = String(stdoutLines[4])
        #expect(getResponse.contains("Initial WAL clip before MCP launch"))

        let pingBody = Data("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}".utf8)
        var framedInput = Data("Content-Length: \(pingBody.count)\r\n\r\n".utf8)
        framedInput.append(pingBody)

        let framedRun = try runSubprocess(
            executableURL: mcpExe,
            stdinData: framedInput,
            environmentOverrides: [StoragePaths.appSupportEnvironmentKey: appSupportDir.path]
        )
        #expect(framedRun.exitCode == 0)
        let framedStdout = String(decoding: framedRun.stdout, as: UTF8.self)
        #expect(framedStdout.hasPrefix("Content-Length:"))
        #expect(framedStdout.contains("\"id\":99"))
    }
}

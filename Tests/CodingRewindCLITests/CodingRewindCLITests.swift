// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

@Suite("CodingRewindCLI Subprocess Suite")
struct CodingRewindCLITests {
    private func makeIsolatedDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/test-data", isDirectory: true)
            .appendingPathComponent("coding-rewind-cli-\(UUID().uuidString)", isDirectory: true)
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
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        return (process.terminationStatus, stdoutData, stderrData, elapsedMS)
    }

    @Test("coding-rewind-hook subprocess finishes in <50ms on a multi-MB transcript and writes <dataDir>/active_turn.json")
    func hookSubprocessLatencyAndActiveTurnOutput() throws {
        let tempDir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dataDir = tempDir.appendingPathComponent("DataDir", isDirectory: true)
        let workspaceDir = tempDir.appendingPathComponent("coding-rewind", isDirectory: true)
        let transcriptURL = tempDir.appendingPathComponent("transcript.jsonl", isDirectory: false)

        let fillerLine = "{\"type\":\"TOOL_RESULT\",\"content\":\"padding line for multi-MB transcript test 0123456789abcdef\"}\n"
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        let chunk = Data(String(repeating: fillerLine, count: 1024).utf8)
        for _ in 0..<32 {
            handle.write(chunk)
        }
        let targetTurns = """
        {"type":"USER_INPUT","source":"USER_EXPLICIT","content":[{"text":"请问如何让 NSPanel 既能响应点击又不会抢走 Antigravity 的焦点？"}]}
        {"type":"PLANNER_RESPONSE","source":"MODEL","content":"使用 .nonactivatingPanel 配合 NSVisualEffectView .hudWindow。"}
        """
        handle.write(Data((targetTurns + "\n").utf8))
        try handle.close()

        let hookExe = try builtExecutableURL(named: "coding-rewind-hook")
        let warmupStdin = try JSONSerialization.data(withJSONObject: [
            "conversationId": "warmup-conv",
            "transcriptPath": transcriptURL.path,
            "workspacePaths": [workspaceDir.path]
        ])
        _ = try runSubprocess(
            executableURL: hookExe,
            stdinData: warmupStdin,
            environmentOverrides: [StoragePaths.dataDirEnvironmentKey: dataDir.path]
        )

        let stdinPayload = try JSONSerialization.data(withJSONObject: [
            "conversationId": "live-conv-42",
            "lastUserInput": "请问如何让 NSPanel 既能响应点击又不会抢走 Antigravity 的焦点？",
            "transcriptPath": transcriptURL.path,
            "workspacePaths": [workspaceDir.path],
            "hookEventName": "PostInvocation"
        ])
        let runResult = try runSubprocess(
            executableURL: hookExe,
            stdinData: stdinPayload,
            environmentOverrides: [StoragePaths.dataDirEnvironmentKey: dataDir.path]
        )

        #expect(runResult.exitCode == 0)
        #expect(String(decoding: runResult.stdout, as: UTF8.self) == "{}\n")
        #expect(runResult.elapsedMilliseconds < 50.0)

        let activeTurnFile = dataDir.appendingPathComponent("active_turn.json")
        #expect(FileManager.default.fileExists(atPath: activeTurnFile.path))

        let turnStore = try ActiveTurnStore(dataDirectoryURL: dataDir)
        let recorded = try #require(turnStore.latestTurn(forFrontmostBundleID: CapturedSelection.antigravityBundleIdentifier))
        #expect(recorded.conversationId == "live-conv-42")
        #expect(recorded.sessionTitle == "coding-rewind")
        #expect(recorded.lastUserInput == "请问如何让 NSPanel 既能响应点击又不会抢走 Antigravity 的焦点？")
        #expect(recorded.recentTurns.count == 2)
    }

    @Test("coding-rewind-hook skips subagents and handles malformed stdin while unconditionally printing {}")
    func hookSubprocessSkipsSubagentsAndMalformedJSON() throws {
        let tempDir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dataDir = tempDir.appendingPathComponent("DataDir", isDirectory: true)
        let hookExe = try builtExecutableURL(named: "coding-rewind-hook")
        let stdinPayload = try JSONSerialization.data(withJSONObject: [
            "conversationId": "subagent-conv",
            "lastUserInput": "Should be skipped"
        ])

        for subEnv in [
            ["ANTIGRAVITY_SUBAGENT_ID": "sub-99"],
            ["SUBAGENT": "1"],
            ["IS_SUBAGENT": "1"]
        ] {
            var env = subEnv
            env[StoragePaths.dataDirEnvironmentKey] = dataDir.path
            let result = try runSubprocess(executableURL: hookExe, stdinData: stdinPayload, environmentOverrides: env)
            #expect(result.exitCode == 0)
            #expect(String(decoding: result.stdout, as: UTF8.self) == "{}\n")
        }

        #expect(!FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("active_turn.json").path))

        let malformed = try runSubprocess(
            executableURL: hookExe,
            stdinData: Data("<<<not-valid-json>>>".utf8),
            environmentOverrides: [StoragePaths.dataDirEnvironmentKey: dataDir.path]
        )
        #expect(malformed.exitCode == 0)
        #expect(String(decoding: malformed.stdout, as: UTF8.self) == "{}\n")
    }

    @Test("coding-rewind-hook --install-plugin stages stable binary and writes official 2.x plugin manifests")
    func hookCLIInstallPluginFlag() throws {
        let tempDir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dataDir = tempDir.appendingPathComponent("DataDir", isDirectory: true)
        let configDir = tempDir.appendingPathComponent("GeminiConfig", isDirectory: true)
        let hookExe = try builtExecutableURL(named: "coding-rewind-hook")

        let process = Process()
        process.executableURL = hookExe
        process.arguments = ["--install-plugin"]
        var env = ProcessInfo.processInfo.environment
        env[StoragePaths.dataDirEnvironmentKey] = dataDir.path
        env[StoragePaths.antigravityConfigEnvironmentKey] = configDir.path
        process.environment = env
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: outData, as: UTF8.self).contains("\"installed\":true"))
        let status = AntigravityIntegration.verify(dataDirectoryURL: dataDir, configDirectoryURL: configDir)
        if case .needsInstallOrRepair(let reasons) = status {
            Issue.record("Unexpected repair needed: \(reasons)")
        }
    }
    @Test("A staged sidecar exits after its executable is atomically upgraded")
    func sidecarUpgradeLifecycle() throws {
        let dir = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try builtExecutableURL(named: "coding-rewind-sidecar")
        let staged = dir.appendingPathComponent("bin/coding-rewind-sidecar")
        let data = dir.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let binary = try Data(contentsOf: source)
        try AtomicFile.writeData(binary, to: staged, permissions: 0o755)
        let process = Process()
        process.executableURL = staged
        process.arguments = ["--data-dir", data.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: data.appendingPathComponent("handoff/worker.lock").path), process.isRunning, Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(process.isRunning)
        try AtomicFile.writeData(binary, to: staged, permissions: 0o755)
        let exitDeadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!process.isRunning)
        if !process.isRunning { #expect(process.terminationStatus == 0) }
    }

}

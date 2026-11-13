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

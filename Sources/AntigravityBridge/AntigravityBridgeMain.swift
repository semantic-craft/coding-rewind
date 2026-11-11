// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

@main
struct AntigravityBridgeMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--install-plugin") {
            do {
                let paths = try StoragePaths.resolve(environment: environment)
                let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                let siblingBridge = selfURL.deletingLastPathComponent().appendingPathComponent("memos-mcp-bridge.sh")
                let pluginDir = try AntigravityIntegration.installOrRepair(
                    dataDirectoryURL: paths.dataDirectoryURL,
                    configDirectoryURL: paths.antigravityConfigDirectoryURL,
                    sourceHookBinaryURL: selfURL,
                    sourceMCPBridgeURL: FileManager.default.fileExists(atPath: siblingBridge.path) ? siblingBridge : nil
                )
                let out = try JSONSerialization.data(
                    withJSONObject: ["installed": true, "pluginDir": pluginDir.path],
                    options: [.withoutEscapingSlashes]
                )
                FileHandle.standardOutput.write(out)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }

        let stdinData = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        guard let paths = try? StoragePaths.resolve(environment: environment),
              let activeTurnStore = try? ActiveTurnStore(dataDirectoryURL: paths.dataDirectoryURL) else {
            FileHandle.standardOutput.write(AntigravityHookRunner.emptyJSONAcknowledgement)
            return
        }

        _ = AntigravityHookRunner.run(
            stdin: stdinData,
            environment: environment,
            activeTurnStore: activeTurnStore,
            stdout: { data in FileHandle.standardOutput.write(data) }
        )
    }
}

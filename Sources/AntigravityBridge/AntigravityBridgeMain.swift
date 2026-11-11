// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

@main
struct AntigravityBridgeMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let stdinData = (try? FileHandle.standardInput.readToEnd()) ?? Data()

        guard let paths = try? StoragePaths.resolveFromEnvironment(environment),
              let activeTurnStore = try? ActiveTurnStore(directoryURL: paths.runtimeDirectoryURL) else {
            FileHandle.standardOutput.write(AntigravityHookRunner.emptyJSONAcknowledgement)
            return
        }

        _ = AntigravityHookRunner.run(
            stdin: stdinData,
            environment: environment,
            activeTurnStore: activeTurnStore,
            stdout: { data in
                FileHandle.standardOutput.write(data)
            }
        )
    }
}

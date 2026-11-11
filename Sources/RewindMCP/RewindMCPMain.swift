// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

@main
struct RewindMCPMain {
    static func main() async {
        do {
            let paths = try StoragePaths.resolveFromEnvironment(ProcessInfo.processInfo.environment)
            if !FileManager.default.fileExists(atPath: paths.stashDatabaseURL.path) {
                _ = try StashStore(location: .sqliteFile(paths.stashDatabaseURL), mode: .readWrite)
            }
            let readOnlyStore = try StashStore(location: .sqliteFile(paths.stashDatabaseURL), mode: .readOnly)
            let server = RewindMCPServer(stash: readOnlyStore)
            try await server.serve(
                input: FileHandle.standardInput,
                output: FileHandle.standardOutput
            )
        } catch {
            let message = "rewind-mcp error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
}

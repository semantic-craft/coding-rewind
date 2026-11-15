// SPDX-License-Identifier: MIT

import Darwin
import Foundation

@main
public enum CodingRewindCLIMain {
    public static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        let exitCode = await CLIRunner.run()
        Darwin.exit(exitCode)
    }
}

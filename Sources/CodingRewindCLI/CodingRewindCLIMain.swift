// SPDX-License-Identifier: MIT

import Darwin
import Foundation

@main
public enum CodingRewindCLIMain {
    public static func main() async {
        let exitCode = await CLIRunner.run()
        Darwin.exit(exitCode)
    }
}

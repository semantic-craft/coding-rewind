// SPDX-License-Identifier: MIT

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]), ["visible", "hidden"].contains(args[2]) else {
    fputs("Usage: swift scripts/verify-app-presence.swift PID visible|hidden\n", stderr)
    exit(2)
}
guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
    fputs("FAIL: target process is not a running application\n", stderr)
    exit(1)
}
let visible = app.activationPolicy == .regular
let matches = visible == (args[2] == "visible")
print("\(matches ? "PASS" : "FAIL"): PID \(pid) Dock activation policy is \(visible ? "visible" : "hidden")")
print("Bundle: \(app.bundleURL?.path ?? "unbundled")")
print("Verify the rendered Dock icon and menu separately on screen.")
exit(matches ? 0 : 1)

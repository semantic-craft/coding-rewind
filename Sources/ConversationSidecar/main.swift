// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation

private func executableIdentity(at url: URL) -> String? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
}

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "--data-dir", arguments[2].hasPrefix("/") else {
    exit(64)
}
do {
    let store = try ConversationHandoffStore(dataDirectoryURL: URL(fileURLWithPath: arguments[2], isDirectory: true))
    let worker = try ConversationSidecarWorker(store: store)
    let environment = ProcessInfo.processInfo.environment
    let executable = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath()
    guard let identity = executableIdentity(at: executable) else { exit(1) }
    var nextRecovery = Date().addingTimeInterval(3600)
    while true {
        guard executableIdentity(at: executable) == identity else { exit(0) }
        try worker.processPending { SidecarAgentAPI.invoke(prompt: $0, environment: environment) }
        if Date() >= nextRecovery {
            try store.recover()
            nextRecovery = Date().addingTimeInterval(3600)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
} catch {
    FileHandle.standardError.write(Data("Coding Rewind sidecar could not access its private queue.\n".utf8))
    exit(1)
}

// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

@Suite("Git source capture from the CLI")
struct GitSourceCLITests {
    @Test("A capture resolves the committed source, keeps the original text and survives HEAD moving")
    func captureGitSource() throws {
        let directory = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let sources = repo.appendingPathComponent("Sources", isDirectory: true)
        let dataDir = directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let cli = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let environment = [
            "HOME": directory.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "CODING_REWIND_QA": "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]
        try confirm(git, ["init", "-q", "-b", "main"], at: repo, environment: environment)
        try confirm(git, ["remote", "add", "origin", "git@github.com:sample-org/sample-repo.git"], at: repo, environment: environment)
        let fileName = "Worker [é] #.swift"
        let file = sources.appendingPathComponent(fileName)
        try Data("func run() {\n    work()\n}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: sources.appendingPathComponent("Link.swift").path, withDestinationPath: fileName)
        try confirm(git, ["add", "Sources"], at: repo, environment: environment)
        let commitArgs = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm"]
        try confirm(git, commitArgs + ["First"], at: repo, environment: environment)
        let revision = try run(git, ["rev-parse", "HEAD"], at: repo, environment: environment)
        let commit = String(decoding: revision.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(commit.utf8.count == 40)

        let text = "    work()\n}"
        let fileOptions = ["--git-file", "Sources/\(fileName)", "--git-lines", "2-3"]
        let create = ["create", "--text", text, "--data-dir", dataDir.path, "--json"]
        let first = try run(cli, create + fileOptions, at: sources, environment: environment)
        try #require(first.status == 0, "\(first.stderr)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let created = try decoder.decode(SnippetRecord.self, from: first.stdout)
        let link = "https://github.com/sample-org/sample-repo/blob/\(commit)/Sources/Worker%20%5B%C3%A9%5D%20%23.swift#L2-L3"
        #expect(created.sourceURL == link)
        #expect(created.sourceTitle == "sample-org/sample-repo/Sources/\(fileName)")
        #expect(created.verbatimText == text)

        try Data("replaced\n".utf8).write(to: file)
        try confirm(git, ["add", "Sources"], at: repo, environment: environment)
        try confirm(git, commitArgs + ["Move HEAD"], at: repo, environment: environment)
        let saved = try run(cli, ["get", created.id, "--data-dir", dataDir.path, "--json"], at: directory, environment: environment)
        try #require(saved.status == 0, "\(saved.stderr)")
        let record = try decoder.decode(SnippetRecord.self, from: saved.stdout)
        #expect(record.sourceURL == link)
        #expect(record.verbatimText == text)

        for badOptions in [
            fileOptions,
            ["--git-file", "../\(fileName)"],
            ["--git-file", file.path],
            ["--git-file", "Sources/Link.swift"],
            ["--git-file", "Sources/\(fileName)", "--git-lines", "0"],
            ["--git-file", "Sources/\(fileName)", "--git-lines", "3-2"],
            ["--git-file", "Sources/\(fileName)", "--git-commit", "main"],
            ["--git-lines", "2"],
            fileOptions + ["--source-url", "https://example.com/other"]
        ] {
            let result = try run(cli, create + badOptions, at: repo, environment: environment)
            #expect(result.status == 64, "\(badOptions)")
            #expect(result.stdout.isEmpty)
            #expect(!result.stderr.contains(directory.path))
        }
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        let queue = OfflineOutbox(fileURL: paths.outboxFileURL)
        #expect(queue.loadEntries().map(\.clientClipId) == [created.id])

        try confirm(git, ["remote", "set-url", "origin", "ssh://git@gitlab.com/group/subgroup/project.git"], at: repo, environment: environment)
        let gitlab = try run(cli, create + fileOptions + ["--git-commit", commit, "--git-root", repo.path], at: directory, environment: environment)
        try #require(gitlab.status == 0, "\(gitlab.stderr)")
        let explicit = try decoder.decode(SnippetRecord.self, from: gitlab.stdout)
        #expect(explicit.sourceURL == "https://gitlab.com/group/subgroup/project/-/blob/\(commit)/Sources/Worker%20%5B%C3%A9%5D%20%23.swift#L2-3")

        try confirm(git, ["remote", "set-url", "origin", "https://fixture-secret@github.com/sample-org/sample-repo.git"], at: repo, environment: environment)
        let denied = try run(cli, create + ["--git-file", "Sources/\(fileName)"], at: repo, environment: environment)
        #expect(denied.status == 64)
        #expect(!denied.stderr.contains("fixture-secret"))
        #expect(queue.loadEntries().count == 2)
    }

    private func confirm(_ binary: URL, _ arguments: [String], at cwd: URL, environment: [String: String]) throws {
        let result = try run(binary, arguments, at: cwd, environment: environment)
        try #require(result.status == 0, "\(result.stderr)")
    }

    private func run(_ binary: URL, _ arguments: [String], at cwd: URL, environment: [String: String]) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: error, as: UTF8.self))
    }
}

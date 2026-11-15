// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation

public enum CLIRunner {
    private struct VersionPayload: Codable, Equatable, Sendable {
        let name: String
        let version: String
    }

    public static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init,
        inputFD: Int32 = STDIN_FILENO,
        writeStdout: (String) -> Void = { writeUTF8($0, to: STDOUT_FILENO) },
        writeStderr: (String) -> Void = { writeUTF8($0, to: STDERR_FILENO) },
        mcpOutputFD: Int32 = STDOUT_FILENO,
        repositoryFactory: (@Sendable (StoragePaths, [String: String], URL?) -> any SnippetQuerying)? = nil
    ) async -> Int32 {
        let command: CLICommand
        do {
            command = try CLIParser.parse(arguments: arguments)
        } catch {
            writeStderr("Error: \(describeError(error))\n")
            return 64
        }

        let factory: @Sendable (StoragePaths, [String: String], URL?) -> any SnippetQuerying =
            repositoryFactory ?? { paths, env, bundledURL in
                SnippetRepository(
                    paths: paths,
                    environment: env,
                    bundledDeveloperCredentialsURL: bundledURL
                )
            }

        let executablePath = arguments.first
        switch command {
        case .help:
            writeStdout(CLIParser.usageText + "\n")
            return 0

        case .version(let json):
            if json {
                if let text = try? SnippetFormatter.encodePrettyJSON(
                    VersionPayload(name: "coding-rewind", version: CLIParser.versionString)
                ) {
                    writeStdout(text + "\n")
                    return 0
                }
            }
            writeStdout("coding-rewind \(CLIParser.versionString)\n")
            return 0

        case .list(let query, let dataDir, let json),
             .search(let query, let dataDir, let json):
            do {
                let repo = try makeRepository(
                    dataDirOverride: dataDir,
                    environment: environment,
                    executablePath: executablePath,
                    factory: factory
                )
                let result = try await repo.listSnippets(query, now: now())
                if json {
                    writeStdout(try SnippetFormatter.encodePrettyJSON(result) + "\n")
                } else {
                    writeStdout(SnippetFormatter.formatQueryResultMarkdown(result) + "\n")
                }
                return 0
            } catch {
                writeStderr("Error: \(describeError(error))\n")
                return 1
            }

        case .get(let id, let includeContext, let dataDir, let json):
            do {
                let repo = try makeRepository(
                    dataDirOverride: dataDir,
                    environment: environment,
                    executablePath: executablePath,
                    factory: factory
                )
                let record = try await repo.getSnippet(id: id, includeContext: includeContext, now: now())
                if json {
                    writeStdout(try SnippetFormatter.encodePrettyJSON(record) + "\n")
                } else {
                    writeStdout(SnippetFormatter.formatSnippetDetailMarkdown(record) + "\n")
                }
                return 0
            } catch {
                writeStderr("Error: \(describeError(error))\n")
                return 1
            }

        case .archive(let id, let dataDir, let json):
            do {
                let repo = try makeRepository(
                    dataDirOverride: dataDir,
                    environment: environment,
                    executablePath: executablePath,
                    factory: factory
                )
                let record = try await repo.archiveSnippet(id: id)
                if json {
                    writeStdout(try SnippetFormatter.encodePrettyJSON(record) + "\n")
                } else {
                    writeStdout(SnippetFormatter.formatArchivedMarkdown(record) + "\n")
                }
                return 0
            } catch {
                writeStderr("Error: \(describeError(error))\n")
                return 1
            }

        case .mcp(let dataDir):
            let server = MCPServer(
                repositoryProvider: {
                    try makeRepository(
                        dataDirOverride: dataDir,
                        environment: environment,
                        executablePath: executablePath,
                        factory: factory
                    )
                },
                now: now
            )
            return await server.run(inputFD: inputFD, outputFD: mcpOutputFD)
        }
    }

    private static func makeRepository(
        dataDirOverride: String?,
        environment: [String: String],
        executablePath: String?,
        factory: @Sendable (StoragePaths, [String: String], URL?) -> any SnippetQuerying
    ) throws -> any SnippetQuerying {
        var resolvedEnv = environment
        let hasCustomDataDir: Bool
        if let dataDirOverride {
            let expanded = (dataDirOverride as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            resolvedEnv[StoragePaths.dataDirEnvironmentKey] = url.path
            hasCustomDataDir = true
        } else {
            let envDataDir = environment[StoragePaths.dataDirEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hasCustomDataDir = !envDataDir.isEmpty
        }

        let paths = try StoragePaths.resolve(environment: resolvedEnv)
        let bundledCredentialsURL: URL?
        if !hasCustomDataDir,
           resolvedEnv[StoragePaths.qaEnvironmentKey] != "1",
           let executablePath, !executablePath.isEmpty {
            let execURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            let helpersDir = execURL.deletingLastPathComponent()
            let contentsDir = helpersDir.deletingLastPathComponent()
            if helpersDir.lastPathComponent == "Helpers", contentsDir.lastPathComponent == "Contents" {
                let candidate = contentsDir
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("DeveloperCredentials.plist", isDirectory: false)
                bundledCredentialsURL = FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
            } else {
                bundledCredentialsURL = nil
            }
        } else {
            bundledCredentialsURL = nil
        }

        return factory(paths, resolvedEnv, bundledCredentialsURL)
    }

    private static func describeError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription, !desc.isEmpty {
            return desc
        }
        return String(describing: error)
    }

    public static func writeUTF8(_ string: String, to fd: Int32) {
        let data = Data(string.utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                offset += written
            }
        }
    }
}

// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation

private final class MCPSessionTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedToken: String?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedToken
    }

    func set(_ token: String) {
        lock.lock()
        cachedToken = token
        lock.unlock()
    }
}

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
        writeStdout: (String) -> Void = { _ = writeUTF8($0, to: STDOUT_FILENO) },
        writeStderr: (String) -> Void = { _ = writeUTF8($0, to: STDERR_FILENO) },
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

        case .delete(let id, let dataDir, let json):
            do {
                let repo = try makeRepository(
                    dataDirOverride: dataDir,
                    environment: environment,
                    executablePath: executablePath,
                    factory: factory
                )
                let result = try await repo.deleteSnippet(id: id)
                if json {
                    writeStdout(try SnippetFormatter.encodePrettyJSON(result) + "\n")
                } else {
                    writeStdout(SnippetFormatter.formatDeletedMarkdown(result) + "\n")
                }
                return 0
            } catch {
                writeStderr("Error: \(describeError(error))\n")
                return 1
            }

        case .mcp(let dataDir):
            let sessionTokenBox = MCPSessionTokenBox()
            let server = MCPServer(
                repositoryProvider: {
                    if let repositoryFactory {
                        return try makeRepository(
                            dataDirOverride: dataDir,
                            environment: environment,
                            executablePath: executablePath,
                            factory: repositoryFactory
                        )
                    }
                    let context = try resolveRepositoryContext(
                        dataDirOverride: dataDir,
                        environment: environment,
                        executablePath: executablePath
                    )
                    var sessionEnv = context.environment
                    let envToken = sessionEnv[StoragePaths.memosTokenEnvironmentKey]?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var preResolvedToken: DeveloperCredentialsResolver.TokenResolution?
                    if envToken.isEmpty {
                        if let cached = sessionTokenBox.get() {
                            sessionEnv[StoragePaths.memosTokenEnvironmentKey] = cached
                        } else if context.paths.resolveMemosBaseURL(environment: sessionEnv) != nil {
                            let resolution = DeveloperCredentialsResolver.resolveToken(
                                paths: context.paths,
                                environment: sessionEnv,
                                bundledDeveloperCredentialsURL: context.bundledCredentialsURL
                            )
                            if case .resolved(let resolvedToken) = resolution {
                                sessionTokenBox.set(resolvedToken)
                                sessionEnv[StoragePaths.memosTokenEnvironmentKey] = resolvedToken
                            }
                            preResolvedToken = resolution
                        }
                    }
                    return SnippetRepository(
                        paths: context.paths,
                        environment: sessionEnv,
                        bundledDeveloperCredentialsURL: context.bundledCredentialsURL,
                        preResolvedToken: preResolvedToken
                    )
                },
                now: now
            )
            return await server.run(inputFD: inputFD, outputFD: mcpOutputFD)
        }
    }

    private static func resolveRepositoryContext(
        dataDirOverride: String?,
        environment: [String: String],
        executablePath: String?
    ) throws -> (paths: StoragePaths, environment: [String: String], bundledCredentialsURL: URL?) {
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
        let bundledCredentialsURL = resolveBundledCredentialsURL(
            executablePath: executablePath,
            hasCustomDataDir: hasCustomDataDir,
            environment: resolvedEnv
        )
        return (paths, resolvedEnv, bundledCredentialsURL)
    }

    package static func resolveBundledCredentialsURL(
        executablePath: String?,
        hasCustomDataDir: Bool,
        environment: [String: String],
        fallbackExecutableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        guard !hasCustomDataDir,
              environment[StoragePaths.qaEnvironmentKey] != "1" else {
            return nil
        }
        let execURL: URL?
        if let executablePath, !executablePath.isEmpty, executablePath.contains("/") {
            execURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        } else {
            execURL = fallbackExecutableURL?.resolvingSymlinksInPath()
        }
        guard let execURL else { return nil }
        let helpersDir = execURL.deletingLastPathComponent()
        let contentsDir = helpersDir.deletingLastPathComponent()
        guard helpersDir.lastPathComponent == "Helpers",
              contentsDir.lastPathComponent == "Contents" else {
            return nil
        }
        let candidate = contentsDir
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DeveloperCredentials.plist", isDirectory: false)
        return FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func makeRepository(
        dataDirOverride: String?,
        environment: [String: String],
        executablePath: String?,
        factory: @Sendable (StoragePaths, [String: String], URL?) -> any SnippetQuerying
    ) throws -> any SnippetQuerying {
        let context = try resolveRepositoryContext(
            dataDirOverride: dataDirOverride,
            environment: environment,
            executablePath: executablePath
        )
        return factory(context.paths, context.environment, context.bundledCredentialsURL)
    }

    private static func describeError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription, !desc.isEmpty {
            return desc
        }
        return String(describing: error)
    }

    @discardableResult
    public static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 {
                    return false
                }
                remaining -= written
                offset += written
            }
            return true
        }
    }

    @discardableResult
    public static func writeUTF8(_ string: String, to fd: Int32) -> Bool {
        writeAll(Data(string.utf8), to: fd)
    }
}

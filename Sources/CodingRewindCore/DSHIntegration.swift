// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum DSHPluginRepairReason: Equatable, Hashable, Sendable {
    case notInstalled
    case missingBundledPlugin
    case missingCLIBinary
    case missingProfilePackage
    case pluginNotRegisteredInProfile
    case stagedPluginMissingOrOutdated
    case invalidRuntimeConfig
}

public struct DSHCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public enum DSHIntegration {
    public static let pluginName = "coding-rewind-dsh"
    public static let pluginVersion = "0.1.0"
    public static let binaryEnvironmentKey = "CODING_REWIND_DSH_BIN"
    public static let requiredSourceRelativePaths = [
        "package.json",
        "cordis.patch.yml",
        "client.js",
        "lib/index.js",
        "lib/handoff.js"
    ]

    public typealias CommandRunner = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> DSHCommandResult

    public enum Status: Equatable, Sendable {
        case installed(stagedDirectoryURL: URL)
        case needsInstallOrRepair(reasons: [String])
    }

    public static func stagedPluginDirectoryURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.standardizedFileURL
            .appendingPathComponent("dsh-plugin", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
    }

    public static func desktopProfileDirectoryURL(in dshHomeURL: URL) -> URL {
        dshHomeURL.standardizedFileURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("desktop", isDirectory: true)
    }

    public static func isDisallowedInstallPath(_ url: URL) -> Bool {
        let candidates = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        for path in candidates {
            if path.contains("/.build/") || path.hasSuffix("/.build") {
                return true
            }
            if path == "/tmp" || path.hasPrefix("/tmp/") {
                return true
            }
            if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
                return true
            }
        }
        return false
    }

    public static func resolveDSHBinaryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configured = environment[binaryEnvironmentKey] {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil }
            let candidate = URL(fileURLWithPath: trimmed)
            return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }

        let candidates: [URL] = [
            applicationURL?.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh", isDirectory: false),
            URL(fileURLWithPath: "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh", isDirectory: false),
            homeDirectory.appendingPathComponent(".local/bin/dsh", isDirectory: false)
        ].compactMap { $0 }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func sanitizedChildEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        dshHomeURL: URL
    ) -> [String: String] {
        var sanitized = base.filter { !$0.key.hasPrefix("CODING_REWIND_") }
        sanitized["DSH_HOME"] = dshHomeURL.standardizedFileURL.path
        return sanitized
    }

    public static func isValidSourcePluginDirectory(
        _ directoryURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let directoryURL else { return false }
        let root = directoryURL.standardizedFileURL
        for rel in requiredSourceRelativePaths {
            let fileURL = root.appendingPathComponent(rel, isDirectory: false)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                return false
            }
        }
        return packageMatchesExpected(at: root.appendingPathComponent("package.json", isDirectory: false))
    }

    public static func repairReasons(
        dataDirectoryURL: URL,
        dshHomeURL: URL,
        dshBinaryURL: URL?,
        fileManager: FileManager = .default
    ) -> [DSHPluginRepairReason] {
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedDSHHome = dshHomeURL.standardizedFileURL
        let stagedDir = stagedPluginDirectoryURL(in: resolvedData)
        let profileDir = desktopProfileDirectoryURL(in: resolvedDSHHome)
        let profilePackageURL = profileDir.appendingPathComponent("package.json", isDirectory: false)
        let installedDir = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let installedPackageURL = installedDir.appendingPathComponent("package.json", isDirectory: false)

        var reasons: [DSHPluginRepairReason] = []

        if let dshBinaryURL {
            if !fileManager.isExecutableFile(atPath: dshBinaryURL.path) {
                reasons.append(.missingCLIBinary)
            }
        } else {
            reasons.append(.missingCLIBinary)
        }

        let stagedPackageURL = stagedDir.appendingPathComponent("package.json", isDirectory: false)
        let stagedExists = fileManager.fileExists(atPath: stagedPackageURL.path)
        let stagedValid = isValidSourcePluginDirectory(stagedDir, fileManager: fileManager)
        let stagedRuntimeConfigValid = runtimeConfigMatches(
            at: stagedDir.appendingPathComponent("runtime-config.json", isDirectory: false),
            expectedDataDir: resolvedData.path
        )

        let installedExists = fileManager.fileExists(atPath: installedPackageURL.path)
        let installedPackageValid = packageMatchesExpected(at: installedPackageURL)
        let resolvedInstalledDir = resolveInstalledModuleDirectory(
            dshHomeURL: resolvedDSHHome,
            stagedDir: stagedDir
        )
        let installedRuntimeConfigValid: Bool
        if let resolvedInstalledDir {
            installedRuntimeConfigValid = runtimeConfigMatches(
                at: resolvedInstalledDir.appendingPathComponent("runtime-config.json", isDirectory: false),
                expectedDataDir: resolvedData.path
            )
        } else {
            installedRuntimeConfigValid = !installedExists
        }

        let profilePackageObj = readJSONObject(at: profilePackageURL)
        let registeredInProfile = profileBundles(from: profilePackageObj).contains(pluginName)

        if !stagedExists && !installedExists && !registeredInProfile {
            reasons.append(.notInstalled)
            return reasons
        }

        if !stagedValid || !installedPackageValid {
            reasons.append(.stagedPluginMissingOrOutdated)
        }
        if !stagedRuntimeConfigValid || !installedRuntimeConfigValid {
            reasons.append(.invalidRuntimeConfig)
        }
        if profilePackageObj == nil {
            reasons.append(.missingProfilePackage)
        } else if !registeredInProfile {
            reasons.append(.pluginNotRegisteredInProfile)
        }

        return reasons
    }

    public static func verify(
        dataDirectoryURL: URL,
        dshHomeURL: URL,
        dshBinaryURL: URL?,
        language: AppLanguage = .zhHans
    ) -> Status {
        let reasons = repairReasons(
            dataDirectoryURL: dataDirectoryURL,
            dshHomeURL: dshHomeURL,
            dshBinaryURL: dshBinaryURL
        )
        return reasons.isEmpty
            ? .installed(stagedDirectoryURL: stagedPluginDirectoryURL(in: dataDirectoryURL))
            : .needsInstallOrRepair(reasons: reasons.map { L10n.dshPluginRepairReason($0, in: language) })
    }

    @discardableResult
    public static func installOrRepair(
        dataDirectoryURL: URL,
        dshHomeURL: URL,
        sourcePluginDirectoryURL: URL?,
        dshBinaryURL: URL?,
        language: AppLanguage = .zhHans,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: CommandRunner = defaultCommandRunner
    ) throws -> URL {
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedDSHHome = dshHomeURL.standardizedFileURL

        guard !isDisallowedInstallPath(resolvedData), !isDisallowedInstallPath(resolvedDSHHome) else {
            let detail = language == .en
                ? "Refusing to install DSH plugin inside transient .build/ or temporary path"
                : "拒绝将 DSH 插件安装到 .build/ 或临时目录"
            throw RewindError.ioError(detail)
        }

        guard let sourceDir = sourcePluginDirectoryURL?.standardizedFileURL,
              isValidSourcePluginDirectory(sourceDir) else {
            throw RewindError.ioError(L10n.dshPluginRepairReason(.missingBundledPlugin, in: language))
        }

        guard let dshBinaryURL, FileManager.default.isExecutableFile(atPath: dshBinaryURL.path) else {
            throw RewindError.ioError(L10n.dshPluginRepairReason(.missingCLIBinary, in: language))
        }

        _ = try ConversationHandoffStore(dataDirectoryURL: resolvedData, host: .dsh)
        _ = try DSHActionStore(dataDirectoryURL: resolvedData)
        _ = try DSHCaptureBridgeStore(dataDirectoryURL: resolvedData)

        let stagedDir = stagedPluginDirectoryURL(in: resolvedData)
        try stagePluginFiles(from: sourceDir, to: stagedDir, dataDirectoryPath: resolvedData.path)

        let childEnv = sanitizedChildEnvironment(base: baseEnvironment, dshHomeURL: resolvedDSHHome)
        let result = try commandRunner(
            dshBinaryURL,
            ["plugin", "--profile", "desktop", "add", "--config.strict-dep-builds=false", "file:\(stagedDir.path)"],
            childEnv
        )
        if result.exitCode != 0,
           !installedAfterUnrelatedReconcileFailure(
               result: result,
               dshHomeURL: resolvedDSHHome,
               stagedDir: stagedDir
           ) {
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "exit \(result.exitCode)" : String(trimmed.prefix(240))
            let detail = language == .en
                ? "dsh plugin install failed (\(suffix))"
                : "dsh 插件安装失败（\(suffix)）"
            throw RewindError.ioError(detail)
        }

        try ensureRegisteredInDesktopProfile(dshHomeURL: resolvedDSHHome, language: language)

        if let resolvedInstalledDir = resolveInstalledModuleDirectory(
            dshHomeURL: resolvedDSHHome,
            stagedDir: stagedDir
        ), resolvedInstalledDir != stagedDir.resolvingSymlinksInPath() {
            try writeRuntimeConfig(dataDirectoryPath: resolvedData.path, in: resolvedInstalledDir)
        }

        return stagedDir
    }

    public static func refreshInstalledPluginIfPresent(
        sourcePluginDirectoryURL: URL?,
        dataDirectoryURL: URL,
        dshHomeURL: URL
    ) throws {
        let resolvedData = dataDirectoryURL.standardizedFileURL
        let resolvedDSHHome = dshHomeURL.standardizedFileURL
        guard !isDisallowedInstallPath(resolvedData) else {
            throw RewindError.ioError("Refusing to refresh DSH plugin inside transient path")
        }
        guard let sourceDir = sourcePluginDirectoryURL?.standardizedFileURL,
              isValidSourcePluginDirectory(sourceDir) else {
            return
        }

        let fm = FileManager.default
        let stagedDir = stagedPluginDirectoryURL(in: resolvedData)
        let installedDir = desktopProfileDirectoryURL(in: resolvedDSHHome)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)

        let hasStaged = fm.fileExists(atPath: stagedDir.appendingPathComponent("package.json").path)
        let hasInstalled = fm.fileExists(atPath: installedDir.appendingPathComponent("package.json").path)
        guard hasStaged || hasInstalled else {
            return
        }

        try stagePluginFiles(from: sourceDir, to: stagedDir, dataDirectoryPath: resolvedData.path)
        if let resolvedInstalledDir = resolveInstalledModuleDirectory(
            dshHomeURL: resolvedDSHHome,
            stagedDir: stagedDir
        ), resolvedInstalledDir != stagedDir.resolvingSymlinksInPath() {
            try stagePluginFiles(from: sourceDir, to: resolvedInstalledDir, dataDirectoryPath: resolvedData.path)
        }
    }

    public static func defaultCommandRunner(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> DSHCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let fd = outputPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(60)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if output.count + count <= 512 * 1024 {
                    output.append(contentsOf: buffer.prefix(count))
                }
            } else if !process.isRunning {
                break
            } else if Date() >= deadline {
                process.terminateGracefully()
                return DSHCommandResult(exitCode: -1, output: "timed out")
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        process.waitUntilExit()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if output.count + count <= 512 * 1024 {
                    output.append(contentsOf: buffer.prefix(count))
                }
            } else {
                break
            }
        }
        return DSHCommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }

    private static func stagePluginFiles(
        from sourceDir: URL,
        to destinationDir: URL,
        dataDirectoryPath: String
    ) throws {
        let fm = FileManager.default
        let parentDir = destinationDir.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        _ = chmod(parentDir.path, 0o700)
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        _ = chmod(destinationDir.path, 0o700)

        let skippedDirectories: Set<String> = ["test", "tests", "node_modules", ".git"]
        var relativeFiles: [String] = []
        try collectFiles(
            in: sourceDir,
            relativePrefix: "",
            skippedDirectories: skippedDirectories,
            into: &relativeFiles
        )

        for rel in relativeFiles where rel != "runtime-config.json" {
            let src = sourceDir.appendingPathComponent(rel, isDirectory: false)
            let dst = destinationDir.appendingPathComponent(rel, isDirectory: false)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: src)
            try AtomicFile.writeData(data, to: dst, permissions: 0o644)
        }

        try writeRuntimeConfig(dataDirectoryPath: dataDirectoryPath, in: destinationDir)
    }

    private static func collectFiles(
        in directory: URL,
        relativePrefix: String,
        skippedDirectories: Set<String>,
        into result: inout [String]
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            let name = entry.lastPathComponent
            let rel = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            if values.isDirectory == true {
                if skippedDirectories.contains(name) { continue }
                try collectFiles(
                    in: entry,
                    relativePrefix: rel,
                    skippedDirectories: skippedDirectories,
                    into: &result
                )
            } else if values.isRegularFile == true {
                result.append(rel)
            }
        }
    }

    private static func writeRuntimeConfig(dataDirectoryPath: String, in directory: URL) throws {
        let payload: [String: String] = ["dataDir": dataDirectoryPath]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try AtomicFile.writeData(
            data,
            to: directory.appendingPathComponent("runtime-config.json", isDirectory: false),
            permissions: 0o600
        )
    }

    private static func ensureRegisteredInDesktopProfile(dshHomeURL: URL, language: AppLanguage) throws {
        let profilePackageURL = desktopProfileDirectoryURL(in: dshHomeURL)
            .appendingPathComponent("package.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: profilePackageURL.path) else {
            throw RewindError.ioError(L10n.dshPluginRepairReason(.missingProfilePackage, in: language))
        }
        guard var root = readJSONObject(at: profilePackageURL) else {
            throw RewindError.ioError(L10n.dshPluginRepairReason(.missingProfilePackage, in: language))
        }

        var dshObj = root["dsh"] as? [String: Any] ?? [:]
        var profileObj = dshObj["profile"] as? [String: Any] ?? [:]
        var bundles = profileObj["bundles"] as? [String] ?? []
        if !bundles.contains(pluginName) {
            bundles.append(pluginName)
            profileObj["bundles"] = bundles
            dshObj["profile"] = profileObj
            root["dsh"] = dshObj
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try AtomicFile.writeData(data, to: profilePackageURL, permissions: 0o600)
        }
    }

    private static func packageMatchesExpected(at packageJSONURL: URL) -> Bool {
        guard let obj = readJSONObject(at: packageJSONURL),
              obj["name"] as? String == pluginName,
              obj["version"] as? String == pluginVersion else {
            return false
        }
        return true
    }

    private static func runtimeConfigMatches(at url: URL, expectedDataDir: String) -> Bool {
        guard let obj = readJSONObject(at: url),
              let configured = obj["dataDir"] as? String else {
            return false
        }
        return URL(fileURLWithPath: configured).standardizedFileURL.path == expectedDataDir
    }

    private static func profileBundles(from packageObj: [String: Any]?) -> [String] {
        guard let dsh = packageObj?["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return []
        }
        return bundles
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func installedAfterUnrelatedReconcileFailure(
        result: DSHCommandResult,
        dshHomeURL: URL,
        stagedDir: URL
    ) -> Bool {
        guard !result.output.localizedCaseInsensitiveContains("installation rejected") else {
            return false
        }
        let profilePackageURL = desktopProfileDirectoryURL(in: dshHomeURL)
            .appendingPathComponent("package.json", isDirectory: false)
        guard let profileObj = readJSONObject(at: profilePackageURL),
              let dependencies = profileObj["dependencies"] as? [String: Any],
              let depSpec = dependencies[pluginName] as? String,
              !depSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let installedDir = resolveInstalledModuleDirectory(dshHomeURL: dshHomeURL, stagedDir: stagedDir),
              isValidSourcePluginDirectory(installedDir) else {
            return false
        }
        for rel in requiredSourceRelativePaths {
            let stagedFile = stagedDir.appendingPathComponent(rel, isDirectory: false)
            let installedFile = installedDir.appendingPathComponent(rel, isDirectory: false)
            guard let stagedBytes = try? Data(contentsOf: stagedFile),
                  let installedBytes = try? Data(contentsOf: installedFile),
                  stagedBytes == installedBytes else {
                return false
            }
        }
        return true
    }

    private static func resolveInstalledModuleDirectory(dshHomeURL: URL, stagedDir: URL) -> URL? {
        let installedLink = desktopProfileDirectoryURL(in: dshHomeURL)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let resolved = installedLink.resolvingSymlinksInPath().standardizedFileURL
        guard isRegularDirectory(resolved) else { return nil }
        let dshRoot = dshHomeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let stagedRoot = stagedDir.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = resolved.path
        if resolvedPath == stagedRoot || resolvedPath.hasPrefix(dshRoot + "/") {
            return resolved
        }
        return nil
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}

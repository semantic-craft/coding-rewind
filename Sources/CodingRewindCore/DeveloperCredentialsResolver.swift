// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Security

private final class LockedCredentialDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public enum DeveloperCredentialsResolver {
    public typealias ExecutableValidator = @Sendable (URL) -> Bool

    public static let onePasswordTeamIdentifier = "2BUA8C4S2C"
    public static let maxConfigurationBytes = 64 * 1024
    private static let onePasswordCLIRequirement =
        #"identifier "com.1password.op" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "2BUA8C4S2C""#
    private static let allowedOnePasswordPrefixes = [
        "/opt/homebrew/",
        "/usr/local/",
        "/Applications/1Password.app/"
    ]

    private struct Configuration: Decodable {
        let token_reference: String
        let op_executable: String

        var memosTokenReference: String { token_reference }
    }

    public enum Source: Equatable, Sendable {
        case none
        case bundled
        case externalFallback
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidConfiguration
        case credentialReadFailed
        case credentialReadTimedOut

        public func localizedDescription(in language: AppLanguage) -> String {
            switch language {
            case .zhHans:
                switch self {
                case .invalidConfiguration:
                    return "开发凭据配置无效，应用未连接 Memos。"
                case .credentialReadFailed:
                    return "无法从 1Password 读取开发凭据。请解锁 1Password 后重新打开 Coding Rewind。"
                case .credentialReadTimedOut:
                    return "从 1Password 读取开发凭据超时。请确认 1Password 已响应后重新同步。"
                }
            case .en:
                switch self {
                case .invalidConfiguration:
                    return "Developer credentials configuration is invalid; Memos was not connected."
                case .credentialReadFailed:
                    return "Could not read developer credentials from 1Password. Unlock 1Password and reopen Coding Rewind."
                case .credentialReadTimedOut:
                    return "Timed out reading developer credentials from 1Password. Check 1Password and sync again."
                }
            }
        }

        public var errorDescription: String? {
            localizedDescription(in: .zhHans)
        }
    }

    public enum TokenResolution: Equatable, Sendable {
        case resolved(String)
        case missing
        case developerCredentialsFailed(Failure)
    }

    public static func isValidSecretReference(_ reference: String) -> Bool {
        reference.range(of: #"^op://[^/]+/[^/]+/.+$"#, options: .regularExpression) != nil
            && reference.rangeOfCharacter(from: .newlines) == nil
    }

    public static func hasBundledConfiguration(
        at configurationURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let configurationURL else { return false }
        return fileManager.fileExists(atPath: configurationURL.path) || fileOrSymlinkExists(atPath: configurationURL.path)
    }

    public static func configurationSource(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> Source {
        if let token = environment[StoragePaths.memosTokenEnvironmentKey],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .none
        }
        if environment[StoragePaths.qaEnvironmentKey] == "1" {
            return .none
        }
        if hasBundledConfiguration(at: configurationURL, fileManager: fileManager) {
            return .bundled
        }
        if let extURL = externalConfigurationURL,
           fileManager.fileExists(atPath: extURL.path) || fileOrSymlinkExists(atPath: extURL.path) {
            return .externalFallback
        }
        return .none
    }

    public static func isTrustedOnePasswordCLI(_ resolvedExecutableURL: URL) -> Bool {
        let path = resolvedExecutableURL.path
        guard resolvedExecutableURL.lastPathComponent == "op",
              allowedOnePasswordPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return false
        }
        var st = stat()
        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0,
              (st.st_mode & 0o022) == 0,
              (st.st_uid == getuid() || st.st_uid == 0) else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolvedExecutableURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(onePasswordCLIRequirement as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }
        let checkFlags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
        )
        guard SecStaticCodeCheckValidityWithErrors(code, checkFlags, req, nil) == errSecSuccess else {
            return false
        }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &infoRef
        ) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return false
        }
        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        let flags: UInt32
        if let rawFlags = info[kSecCodeInfoFlags as String] as? UInt32 {
            flags = rawFlags
        } else if let rawInt = info[kSecCodeInfoFlags as String] as? Int {
            flags = UInt32(truncatingIfNeeded: rawInt)
        } else {
            flags = 0
        }
        return teamID == onePasswordTeamIdentifier
            && (flags & SecCodeSignatureFlags.runtime.rawValue) != 0
    }

    public static func resolveEnvironment(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String],
        timeoutSeconds: TimeInterval = 10.0,
        executableValidator: ExecutableValidator = isTrustedOnePasswordCLI
    ) throws -> [String: String] {
        if let token = environment[StoragePaths.memosTokenEnvironmentKey],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environment
        }
        if environment[StoragePaths.qaEnvironmentKey] == "1" {
            return environment
        }

        let fm = FileManager.default
        let activeData: Data
        let loadedFromBundle: Bool
        if let configurationURL {
            activeData = try readValidatedConfigurationData(
                at: configurationURL,
                requireStrictPrivatePermissions: false
            )
            loadedFromBundle = true
        } else if let extURL = externalConfigurationURL,
                  fm.fileExists(atPath: extURL.path) || fileOrSymlinkExists(atPath: extURL.path) {
            activeData = try readValidatedConfigurationData(
                at: extURL,
                requireStrictPrivatePermissions: true
            )
            loadedFromBundle = false
        } else {
            return environment
        }

        guard let configuration = try? PropertyListDecoder().decode(Configuration.self, from: activeData),
              isValidSecretReference(configuration.memosTokenReference),
              let resolvedExecutableURL = resolveCanonicalExecutableURL(atPath: configuration.op_executable),
              executableValidator(resolvedExecutableURL) else {
            throw Failure.invalidConfiguration
        }

        if loadedFromBundle, let extURL = externalConfigurationURL {
            try? AtomicFile.writeData(activeData, to: extURL, permissions: 0o600)
        }

        let sanitizedChildEnv = environment.filter { !$0.key.uppercased().hasPrefix("DYLD_") }

        let process = Process()
        let output = Pipe()
        let readHandle = output.fileHandleForReading
        let exitSemaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        let dataBox = LockedCredentialDataBox()

        process.executableURL = resolvedExecutableURL
        process.arguments = ["read", "--no-newline", configuration.memosTokenReference]
        process.environment = sanitizedChildEnv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let collected = (try? readHandle.readToEnd()) ?? Data()
            dataBox.set(collected)
            readGroup.leave()
        }

        do {
            try process.run()
            try? output.fileHandleForWriting.close()
        } catch {
            try? readHandle.close()
            throw Failure.credentialReadFailed
        }

        let waitResult = exitSemaphore.wait(timeout: .now() + max(0.01, timeoutSeconds))
        if waitResult == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
            try? readHandle.close()
            process.waitUntilExit()
            _ = readGroup.wait(timeout: .now() + 0.5)
            throw Failure.credentialReadTimedOut
        }

        process.waitUntilExit()
        if readGroup.wait(timeout: .now() + 1.0) == .timedOut {
            try? readHandle.close()
            _ = readGroup.wait(timeout: .now() + 0.5)
        }
        let tokenData = dataBox.get()

        guard process.terminationStatus == 0,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !token.hasPrefix("op://") else {
            throw Failure.credentialReadFailed
        }

        var resolved = environment
        resolved[StoragePaths.memosTokenEnvironmentKey] = token
        return resolved
    }

    public static func resolveToken(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledDeveloperCredentialsURL: URL? = nil,
        timeoutSeconds: TimeInterval = 10.0,
        executableValidator: ExecutableValidator = isTrustedOnePasswordCLI
    ) -> TokenResolution {
        if let envToken = environment[StoragePaths.memosTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return .resolved(envToken)
        }

        if environment[StoragePaths.qaEnvironmentKey] != "1" {
            let bundledURL: URL?
            if let candidate = bundledDeveloperCredentialsURL,
               hasBundledConfiguration(at: candidate) {
                bundledURL = candidate
            } else if bundledDeveloperCredentialsURL != nil {
                return .developerCredentialsFailed(.invalidConfiguration)
            } else {
                bundledURL = nil
            }

            let externalURL = paths.developerCredentialsFileURL
            if bundledURL != nil || FileManager.default.fileExists(atPath: externalURL.path) || fileOrSymlinkExists(atPath: externalURL.path) {
                do {
                    let resolvedEnv = try resolveEnvironment(
                        configurationURL: bundledURL,
                        externalConfigurationURL: externalURL,
                        environment: environment,
                        timeoutSeconds: timeoutSeconds,
                        executableValidator: executableValidator
                    )
                    if let token = resolvedEnv[StoragePaths.memosTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !token.isEmpty {
                        return .resolved(token)
                    }
                    return .developerCredentialsFailed(.credentialReadFailed)
                } catch let failure as Failure {
                    return .developerCredentialsFailed(failure)
                } catch {
                    return .developerCredentialsFailed(.credentialReadFailed)
                }
            }
        }

        if let keychainToken = KeychainTokenStore.resolveToken(environment: environment) {
            return .resolved(keychainToken)
        }
        return .missing
    }

    private static func readValidatedConfigurationData(
        at url: URL,
        requireStrictPrivatePermissions: Bool
    ) throws -> Data {
        let currentUID = getuid()
        let parentPath = url.deletingLastPathComponent().path
        var dirStat = stat()
        guard lstat(parentPath, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              (dirStat.st_mode & 0o022) == 0,
              (requireStrictPrivatePermissions
                  ? dirStat.st_uid == currentUID
                  : (dirStat.st_uid == currentUID || dirStat.st_uid == 0)) else {
            throw Failure.invalidConfiguration
        }

        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure.invalidConfiguration
        }
        defer { Darwin.close(fd) }

        var initialStat = stat()
        guard Darwin.fstat(fd, &initialStat) == 0,
              (initialStat.st_mode & S_IFMT) == S_IFREG,
              initialStat.st_nlink == 1,
              initialStat.st_size > 0,
              initialStat.st_size <= off_t(maxConfigurationBytes) else {
            throw Failure.invalidConfiguration
        }

        if requireStrictPrivatePermissions {
            guard initialStat.st_uid == currentUID,
                  (initialStat.st_mode & 0o077) == 0 else {
                throw Failure.invalidConfiguration
            }
        } else {
            guard initialStat.st_uid == currentUID || initialStat.st_uid == 0,
                  (initialStat.st_mode & 0o022) == 0 else {
                throw Failure.invalidConfiguration
            }
        }

        let expectedSize = Int(initialStat.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw Failure.invalidConfiguration
            }
            if bytesRead == 0 {
                break
            }
            if data.count + bytesRead > maxConfigurationBytes {
                throw Failure.invalidConfiguration
            }
            data.append(contentsOf: chunk[0..<bytesRead])
        }

        var finalStat = stat()
        guard data.count == expectedSize,
              Darwin.fstat(fd, &finalStat) == 0,
              (finalStat.st_mode & S_IFMT) == S_IFREG,
              finalStat.st_dev == initialStat.st_dev,
              finalStat.st_ino == initialStat.st_ino,
              finalStat.st_nlink == 1,
              finalStat.st_size == initialStat.st_size else {
            throw Failure.invalidConfiguration
        }
        return data
    }

    private static func resolveCanonicalExecutableURL(atPath rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/"),
              !rawPath.contains("\0"),
              rawPath.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        guard let resolvedCString = Darwin.realpath(rawPath, nil) else {
            return nil
        }
        defer { Darwin.free(resolvedCString) }
        let canonicalPath = String(cString: resolvedCString)
        guard canonicalPath.hasPrefix("/") else { return nil }
        var st = stat()
        guard lstat(canonicalPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0,
              (st.st_mode & 0o022) == 0,
              (st.st_uid == getuid() || st.st_uid == 0) else {
            return nil
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: false)
    }

    private static func fileOrSymlinkExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

// SPDX-License-Identifier: MIT

import Darwin
import Foundation

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
        if configurationURL != nil {
            return .bundled
        }
        if let extURL = externalConfigurationURL,
           fileManager.fileExists(atPath: extURL.path) || fileOrSymlinkExists(atPath: extURL.path) {
            return .externalFallback
        }
        return .none
    }

    public static func resolveEnvironment(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String],
        timeoutSeconds: TimeInterval = 10.0
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
            guard let data = try? Data(contentsOf: configurationURL) else {
                throw Failure.invalidConfiguration
            }
            activeData = data
            loadedFromBundle = true
        } else if let extURL = externalConfigurationURL,
                  fm.fileExists(atPath: extURL.path) || fileOrSymlinkExists(atPath: extURL.path) {
            guard let data = try? Data(contentsOf: extURL) else {
                throw Failure.invalidConfiguration
            }
            activeData = data
            loadedFromBundle = false
        } else {
            return environment
        }

        guard let configuration = try? PropertyListDecoder().decode(Configuration.self, from: activeData),
              isValidSecretReference(configuration.memosTokenReference),
              configuration.op_executable.hasPrefix("/"),
              fm.isExecutableFile(atPath: configuration.op_executable) else {
            throw Failure.invalidConfiguration
        }

        if loadedFromBundle, let extURL = externalConfigurationURL {
            try? AtomicFile.writeData(activeData, to: extURL, permissions: 0o600)
        }

        let process = Process()
        let output = Pipe()
        let readHandle = output.fileHandleForReading
        let exitSemaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        let dataBox = LockedCredentialDataBox()

        process.executableURL = URL(fileURLWithPath: configuration.op_executable)
        process.arguments = ["read", "--no-newline", configuration.memosTokenReference]
        process.environment = environment
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
        timeoutSeconds: TimeInterval = 10.0
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
                        timeoutSeconds: timeoutSeconds
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

    private static func fileOrSymlinkExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

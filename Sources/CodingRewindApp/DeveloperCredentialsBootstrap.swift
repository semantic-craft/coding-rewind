// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

enum DeveloperCredentialsBootstrap {
    private struct Configuration: Decodable {
        let token_reference: String
        let op_executable: String
    }

    enum Failure: LocalizedError, Equatable {
        case invalidConfiguration
        case credentialReadFailed

        func localizedDescription(in language: AppLanguage) -> String {
            switch language {
            case .zhHans:
                switch self {
                case .invalidConfiguration:
                    return "开发凭据配置无效，应用未连接 Memos。"
                case .credentialReadFailed:
                    return "无法从 1Password 读取开发凭据。请解锁 1Password 后重新打开 Coding Rewind。"
                }
            case .en:
                switch self {
                case .invalidConfiguration:
                    return "Developer credentials configuration is invalid; Memos was not connected."
                case .credentialReadFailed:
                    return "Could not read developer credentials from 1Password. Unlock 1Password and reopen Coding Rewind."
                }
            }
        }

        var errorDescription: String? {
            localizedDescription(in: .zhHans)
        }
    }

    static func resolveEnvironment(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String]
    ) throws -> [String: String] {
        if let token = environment[StoragePaths.memosTokenEnvironmentKey],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environment
        }
        if environment[StoragePaths.qaEnvironmentKey] == "1" { return environment }

        let fm = FileManager.default
        let activeData: Data
        if let configurationURL {
            guard let data = try? Data(contentsOf: configurationURL) else {
                throw Failure.invalidConfiguration
            }
            activeData = data
            if let extURL = externalConfigurationURL {
                try? AtomicFile.writeData(data, to: extURL, permissions: 0o600)
            }
        } else if let extURL = externalConfigurationURL, fm.fileExists(atPath: extURL.path) {
            guard let data = try? Data(contentsOf: extURL) else {
                throw Failure.invalidConfiguration
            }
            activeData = data
        } else {
            return environment
        }

        guard let configuration = try? PropertyListDecoder().decode(Configuration.self, from: activeData),
              configuration.token_reference.range(of: #"^op://[^/]+/[^/]+/.+$"#, options: .regularExpression) != nil,
              configuration.op_executable.hasPrefix("/"),
              fm.isExecutableFile(atPath: configuration.op_executable) else {
            throw Failure.invalidConfiguration
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.op_executable)
        process.arguments = ["read", "--no-newline", configuration.token_reference]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.credentialReadFailed
        }
        let tokenData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
}

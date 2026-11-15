// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation

enum DeveloperCredentialsBootstrap {
    typealias Source = DeveloperCredentialsResolver.Source
    typealias Failure = DeveloperCredentialsResolver.Failure

    static func isValidSecretReference(_ reference: String) -> Bool {
        DeveloperCredentialsResolver.isValidSecretReference(reference)
    }

    static func hasBundledConfiguration(
        at configurationURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        DeveloperCredentialsResolver.hasBundledConfiguration(at: configurationURL, fileManager: fileManager)
    }

    static func configurationSource(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> Source {
        DeveloperCredentialsResolver.configurationSource(
            configurationURL: configurationURL,
            externalConfigurationURL: externalConfigurationURL,
            environment: environment,
            fileManager: fileManager
        )
    }

    static func resolveEnvironment(
        configurationURL: URL?,
        externalConfigurationURL: URL? = nil,
        environment: [String: String],
        timeoutSeconds: TimeInterval = 10.0
    ) throws -> [String: String] {
        try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: configurationURL,
            externalConfigurationURL: externalConfigurationURL,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }
}

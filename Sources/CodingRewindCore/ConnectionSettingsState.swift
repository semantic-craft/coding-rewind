// SPDX-License-Identifier: MIT

import Foundation

public struct ConnectionSettingsState: Equatable, Sendable {
    public let memosURL: String
    public let isURLManaged: Bool
    public let isTokenManaged: Bool

    public init(paths: StoragePaths, environment: [String: String]) {
        memosURL = paths.readConfiguredMemosURLString(environment: environment) ?? ""
        isURLManaged = Self.hasValue(StoragePaths.memosURLEnvironmentKey, in: environment)
        isTokenManaged = Self.hasValue(StoragePaths.memosTokenEnvironmentKey, in: environment)
    }

    private static func hasValue(_ key: String, in environment: [String: String]) -> Bool {
        !(environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

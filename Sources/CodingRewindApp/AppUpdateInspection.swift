// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation
import Security

public struct StagedUpdate: Equatable, Sendable {
    public let candidate: GitHubReleaseCandidate
    public let stagingDirectoryURL: URL
    public let stagedAppURL: URL

    public init(candidate: GitHubReleaseCandidate, stagingDirectoryURL: URL, stagedAppURL: URL) {
        self.candidate = candidate
        self.stagingDirectoryURL = stagingDirectoryURL
        self.stagedAppURL = stagedAppURL
    }
}

public enum ManualUpdateReason: Equatable, Sendable {
    case missingChecksum
    case signatureDowngradeBlocked
    case bundleIdentifierMismatch
    case installLocationNotWritable
    case nonAppBundleInstall
}

public struct InspectedCodeSignature: Equatable, Sendable {
    public let authority: BundleSignatureAuthority
    public let bundleIdentifier: String?

    public init(authority: BundleSignatureAuthority, bundleIdentifier: String?) {
        self.authority = authority
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum CodeSignatureInspectionError: Error, Equatable, Sendable {
    case invalidOrTamperedSignature(OSStatus)
    case bundleIdentifierMismatch(plist: String, signed: String)
}

public typealias SignatureInspectionError = CodeSignatureInspectionError

public enum ReleaseTransportError: Error, Equatable, Sendable {
    case httpStatus(Int, String)
}

public protocol ReleaseTransport: Sendable {
    func fetchLatestReleaseJSON() async throws -> Data
    func fetchText(from url: URL) async throws -> String
    func downloadArchive(from url: URL, to destinationURL: URL) async throws
}

public struct URLSessionReleaseTransport: ReleaseTransport {
    public static let defaultLatestReleaseURL = URL(
        string: "https://api.github.com/repos/semantic-craft/coding-rewind/releases/latest"
    )!

    private let latestReleaseURL: URL
    private let session: URLSession

    public init(
        latestReleaseURL: URL = defaultLatestReleaseURL,
        session: URLSession = .shared
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.session = session
    }

    public func fetchLatestReleaseJSON() async throws -> Data {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseTransportError.httpStatus(
                http.statusCode,
                String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        return data
    }

    public func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReleaseTransportError.httpStatus(
                http.statusCode,
                String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func downloadArchive(from url: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (downloadedURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw ReleaseTransportError.httpStatus(http.statusCode, "archive download failed")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: downloadedURL, to: destinationURL)
        _ = chmod(destinationURL.path, 0o600)
    }
}

public protocol CodeSignatureInspecting: Sendable {
    func inspect(bundleURL: URL) throws -> InspectedCodeSignature
}

public struct SecStaticCodeSignatureInspector: CodeSignatureInspecting {
    private static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"
    private static let appleDevelopmentRequirement =
        "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.2] /* exists */ or certificate leaf[field.1.2.840.113635.100.6.1.12] /* exists */)"

    public init() {}

    public func inspect(bundleURL: URL) throws -> InspectedCodeSignature {
        let plistBundleID = Self.readPlistBundleIdentifier(at: bundleURL)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            if createStatus == errSecCSUnsigned {
                return InspectedCodeSignature(authority: .unsigned, bundleIdentifier: plistBundleID)
            }
            throw CodeSignatureInspectionError.invalidOrTamperedSignature(createStatus)
        }

        let checkFlags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
                | UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSRestrictSymlinks)
                | UInt32(kSecCSRestrictToAppLike)
        )
        let validStatus = SecStaticCodeCheckValidityWithErrors(code, checkFlags, nil, nil)
        if validStatus == errSecCSUnsigned {
            return InspectedCodeSignature(authority: .unsigned, bundleIdentifier: plistBundleID)
        }
        guard validStatus == errSecSuccess else {
            throw CodeSignatureInspectionError.invalidOrTamperedSignature(validStatus)
        }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &infoRef
        )
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            throw CodeSignatureInspectionError.invalidOrTamperedSignature(infoStatus)
        }

        let rawPlistID = plistBundleID ?? ""
        let rawSignedID = (info[kSecCodeInfoIdentifier as String] as? String) ?? ""
        guard !rawPlistID.isEmpty, !rawSignedID.isEmpty, rawPlistID == rawSignedID else {
            throw CodeSignatureInspectionError.bundleIdentifierMismatch(plist: rawPlistID, signed: rawSignedID)
        }

        let flags: UInt32
        if let rawFlags = info[kSecCodeInfoFlags as String] as? UInt32 {
            flags = rawFlags
        } else if let rawInt = info[kSecCodeInfoFlags as String] as? Int {
            flags = UInt32(truncatingIfNeeded: rawInt)
        } else {
            flags = 0
        }

        if (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0 {
            return InspectedCodeSignature(authority: .adhoc, bundleIdentifier: rawPlistID)
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        let authority: BundleSignatureAuthority
        if !teamID.isEmpty,
           (flags & SecCodeSignatureFlags.runtime.rawValue) != 0,
           Self.satisfiesRequirement(code: code, checkFlags: checkFlags, requirementString: Self.developerIDRequirement) {
            authority = .developerID(teamID: teamID)
        } else if !teamID.isEmpty,
                  Self.satisfiesRequirement(code: code, checkFlags: checkFlags, requirementString: Self.appleDevelopmentRequirement) {
            authority = .appleDevelopment(teamID: teamID)
        } else {
            authority = .otherSigned(teamID: teamID)
        }

        return InspectedCodeSignature(authority: authority, bundleIdentifier: rawPlistID)
    }

    private static func satisfiesRequirement(
        code: SecStaticCode,
        checkFlags: SecCSFlags,
        requirementString: String
    ) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidityWithErrors(code, checkFlags, requirement, nil) == errSecSuccess
    }

    private static func readPlistBundleIdentifier(at bundleURL: URL) -> String? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String,
              !id.isEmpty else {
            return nil
        }
        return id
    }
}

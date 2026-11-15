// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public struct SemanticVersion: Comparable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty,
              !trimmed.contains("-"),
              !trimmed.contains("+") else {
            return nil
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        values.reserveCapacity(3)
        for part in parts {
            guard !part.isEmpty,
                  part.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                  let number = Int(part),
                  number >= 0 else {
                return nil
            }
            values.append(number)
        }
        self.major = values[0]
        self.minor = values[1]
        self.patch = values[2]
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct SHA256Digest: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let hexValue: String

    public init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 64,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || (scalar.value >= 0x41 && scalar.value <= 0x46)
                      || (scalar.value >= 0x61 && scalar.value <= 0x66)
              }) else {
            return nil
        }
        self.hexValue = trimmed.lowercased()
    }

    public var description: String { hexValue }

    public static func compute(for data: Data) -> SHA256Digest {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SHA256Digest(hexString: hex)!
    }

    public static func compute(fileAt url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SHA256Digest(hexString: hex)!
    }

    public static func parseChecksumsFile(_ text: String) -> [String: SHA256Digest] {
        let horizontalWhitespace = CharacterSet(charactersIn: " \t")
        var table: [String: SHA256Digest] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard line.count >= 66 else { continue }
            let hexPrefix = String(line.prefix(64))
            guard let digest = SHA256Digest(hexString: hexPrefix) else { continue }
            let rest = line.dropFirst(64)
            guard rest.first == " " || rest.first == "\t" else { continue }
            var rawTarget = String(rest).trimmingCharacters(in: horizontalWhitespace)
            if rawTarget.hasPrefix("*") {
                rawTarget.removeFirst()
                rawTarget = rawTarget.trimmingCharacters(in: horizontalWhitespace)
            }
            guard !rawTarget.isEmpty else { continue }
            let cleanTarget = rawTarget.hasPrefix("./") ? String(rawTarget.dropFirst(2)) : rawTarget
            table[cleanTarget] = digest
            let basename = (cleanTarget as NSString).lastPathComponent
            if !basename.isEmpty && table[basename] == nil {
                table[basename] = digest
            }
        }
        return table
    }

    public static func lookup(archiveName: String, inChecksumsText text: String) -> SHA256Digest? {
        let table = parseChecksumsFile(text)
        if let exact = table[archiveName] {
            return exact
        }
        let basename = (archiveName as NSString).lastPathComponent
        return table[basename]
    }
}

public enum UpdateParseError: Error, Equatable, Sendable {
    case invalidJSON
    case draftOrPrerelease
    case invalidVersionTag(String)
    case invalidReleaseURL(String)
    case missingMacOSArchiveAsset
}

public struct GitHubReleaseCandidate: Codable, Equatable, Sendable {
    public let tagName: String
    public let version: SemanticVersion
    public let htmlURL: URL
    public let releaseNotes: String
    public let macosArchiveName: String
    public let macosArchiveURL: URL
    public let checksumsURL: URL?
    public var expectedSHA256: SHA256Digest?

    public init(
        tagName: String,
        version: SemanticVersion,
        htmlURL: URL,
        releaseNotes: String,
        macosArchiveName: String,
        macosArchiveURL: URL,
        checksumsURL: URL? = nil,
        expectedSHA256: SHA256Digest? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.htmlURL = htmlURL
        self.releaseNotes = releaseNotes
        self.macosArchiveName = macosArchiveName
        self.macosArchiveURL = macosArchiveURL
        self.checksumsURL = checksumsURL
        self.expectedSHA256 = expectedSHA256
    }

    private struct ReleaseDTO: Decodable {
        struct AssetDTO: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [AssetDTO]?
    }

    public static func parseLatestRelease(
        jsonData: Data,
        checksumsText: String? = nil
    ) throws -> GitHubReleaseCandidate {
        guard let dto = try? JSONDecoder().decode(ReleaseDTO.self, from: jsonData) else {
            throw UpdateParseError.invalidJSON
        }
        if dto.draft == true || dto.prerelease == true {
            throw UpdateParseError.draftOrPrerelease
        }
        guard let version = SemanticVersion(parsing: dto.tag_name) else {
            throw UpdateParseError.invalidVersionTag(dto.tag_name)
        }
        guard let htmlURL = validHTTPSURL(dto.html_url) else {
            throw UpdateParseError.invalidReleaseURL(dto.html_url)
        }
        let assets = dto.assets ?? []
        let macosCandidates = assets.filter { asset in
            let lower = asset.name.lowercased()
            return lower.hasSuffix(".zip")
                && !lower.contains("webclipper")
                && (lower.contains("macos") || lower.hasPrefix("codingrewind-"))
        }
        let preferredName = "CodingRewind-v\(version.description)-macos-arm64.zip".lowercased()
        let selectedAsset = macosCandidates.first { $0.name.lowercased() == preferredName }
            ?? macosCandidates.first { $0.name.lowercased().contains("macos-arm64") }
            ?? macosCandidates.first
        guard let archiveAsset = selectedAsset else {
            throw UpdateParseError.missingMacOSArchiveAsset
        }
        guard let archiveURL = validHTTPSURL(archiveAsset.browser_download_url) else {
            throw UpdateParseError.invalidReleaseURL(archiveAsset.browser_download_url)
        }
        let checksumsAsset = assets.first {
            let lower = $0.name.lowercased()
            return lower == "sha256sums.txt" || lower == "sha256sums"
        }
        let checksumsURL = checksumsAsset.flatMap { validHTTPSURL($0.browser_download_url) }
        let digest = checksumsText.flatMap {
            SHA256Digest.lookup(archiveName: archiveAsset.name, inChecksumsText: $0)
        }
        return GitHubReleaseCandidate(
            tagName: dto.tag_name,
            version: version,
            htmlURL: htmlURL,
            releaseNotes: dto.body ?? "",
            macosArchiveName: archiveAsset.name,
            macosArchiveURL: archiveURL,
            checksumsURL: checksumsURL,
            expectedSHA256: digest
        )
    }

    public func withChecksumsText(_ checksumsText: String) -> GitHubReleaseCandidate {
        var copy = self
        copy.expectedSHA256 = SHA256Digest.lookup(archiveName: macosArchiveName, inChecksumsText: checksumsText)
        return copy
    }

    private static func validHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

public enum BundleSignatureAuthority: Equatable, Sendable {
    case developerID(teamID: String)
    case appleDevelopment(teamID: String)
    case otherSigned(teamID: String)
    case adhoc
    case unsigned

    public static let defaultReleaseTeamID = "LQAVR62TK2"

    public var displayDescription: String {
        switch self {
        case .developerID(let teamID):
            return teamID.isEmpty ? "Developer ID" : "Developer ID (\(teamID))"
        case .appleDevelopment(let teamID):
            return teamID.isEmpty ? "Apple Development" : "Apple Development (\(teamID))"
        case .otherSigned(let teamID):
            return teamID.isEmpty ? "Signed" : "Signed (\(teamID))"
        case .adhoc:
            return "Ad-hoc"
        case .unsigned:
            return "Unsigned"
        }
    }

    public func canReplace(
        with candidate: BundleSignatureAuthority,
        expectedReleaseTeamID: String = defaultReleaseTeamID
    ) -> Bool {
        Self.canReplace(installed: self, with: candidate, expectedReleaseTeamID: expectedReleaseTeamID)
    }

    public static func canReplace(
        installed: BundleSignatureAuthority,
        with candidate: BundleSignatureAuthority,
        expectedReleaseTeamID: String = defaultReleaseTeamID
    ) -> Bool {
        switch (installed, candidate) {
        case (_, .unsigned), (_, .otherSigned), (.otherSigned, _):
            return false
        case (.developerID(let t1), .developerID(let t2)):
            return !t1.isEmpty && t1 == t2
        case (.developerID, _):
            return false
        case (.appleDevelopment(let t1), .developerID(let t2)):
            return !t1.isEmpty && t1 == t2
        case (.appleDevelopment(let t1), .appleDevelopment(let t2)):
            return !t1.isEmpty && t1 == t2
        case (.appleDevelopment, _):
            return false
        case (.adhoc, .developerID(let t2)):
            return !t2.isEmpty && t2 == expectedReleaseTeamID
        case (.adhoc, .appleDevelopment(let t2)):
            return !t2.isEmpty && t2 == expectedReleaseTeamID
        case (.adhoc, .adhoc):
            return true
        case (.unsigned, .developerID(let t2)):
            return !t2.isEmpty && t2 == expectedReleaseTeamID
        case (.unsigned, .appleDevelopment(let t2)):
            return !t2.isEmpty && t2 == expectedReleaseTeamID
        case (.unsigned, .adhoc):
            return true
        }
    }
}

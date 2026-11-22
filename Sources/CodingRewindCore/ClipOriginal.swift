// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public struct ClipOriginal: Codable, Equatable, Sendable {
    public static let maximumBytes = 8 * 1024 * 1024

    public let filename: String
    public let data: Data

    public init(filename: String, data: Data) throws {
        let name = filename
        guard !name.isEmpty, name.utf8.count <= 180,
              name != ".", name != "..",
              name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\"))) == nil,
              data.count <= Self.maximumBytes else {
            throw RewindError.invalidOriginal
        }
        self.filename = name
        self.data = data
    }

    private static let envelopeHeader = Data("coding-rewind-original-v1\n".utf8)
    private static let envelopePrefix = "rewind-"
    private static let envelopeSuffix = ".rewind-original"

    static func attachmentID(for clipID: String) -> String {
        let digest = SHA256.hash(data: Data(clipID.utf8))
        return "a-" + digest.prefix(17).map { String(format: "%02x", $0) }.joined()
    }

    var storedFilename: String { Self.envelopePrefix + filename + Self.envelopeSuffix }

    var envelope: Data {
        Self.envelopeHeader + data
    }

    static func decodeEnvelope(filename: String, data: Data) throws -> Self {
        guard filename.hasPrefix(envelopePrefix), filename.hasSuffix(envelopeSuffix), data.starts(with: envelopeHeader) else {
            throw RewindError.invalidServerResponse
        }
        return try Self(
            filename: String(filename.dropFirst(envelopePrefix.count).dropLast(envelopeSuffix.count)),
            data: Data(data.dropFirst(envelopeHeader.count))
        )
    }
}

// SPDX-License-Identifier: MIT

import Foundation

public enum PlaceKind: String, CaseIterable, Codable, Sendable {
    case project
    case topic
    case person

    var memoIDCode: String {
        switch self {
        case .project: return "p"
        case .topic: return "t"
        case .person: return "u"
        }
    }
}

public struct PlaceSlug: Hashable, Comparable, Codable, Sendable {
    public static let maxLength = 28

    public let rawValue: String

    public init?(_ raw: String) {
        guard Self.isValid(raw) else { return nil }
        self.rawValue = raw
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let slug = PlaceSlug(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid place slug '\(raw)'."))
        }
        self = slug
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: PlaceSlug, rhs: PlaceSlug) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isValid(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= maxLength else { return false }
        let isAlphaNum: (UInt8) -> Bool = { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) }
        var previousWasHyphen = true
        for byte in bytes {
            if byte == 0x2D {
                guard !previousWasHyphen else { return false }
                previousWasHyphen = true
            } else if isAlphaNum(byte) {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return !previousWasHyphen
    }
}

public struct PlaceRef: Hashable, Comparable, Codable, Sendable {
    public let kind: PlaceKind
    public let slug: PlaceSlug

    public init(kind: PlaceKind, slug: PlaceSlug) {
        self.kind = kind
        self.slug = slug
    }

    /// Accepts `kind/slug` with or without a leading `#`, case-insensitively.
    public init?(tag raw: String) {
        var cleaned = Substring(raw)
        if cleaned.hasPrefix("#") {
            cleaned = cleaned.dropFirst()
        }
        let parts = cleaned.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = PlaceKind(rawValue: String(parts[0])),
              let slug = PlaceSlug(String(parts[1])) else {
            return nil
        }
        self.init(kind: kind, slug: slug)
    }

    public var tag: String { "\(kind.rawValue)/\(slug.rawValue)" }

    public var memoID: String { "pl-\(kind.memoIDCode)-\(slug.rawValue)" }

    public static func < (lhs: PlaceRef, rhs: PlaceRef) -> Bool {
        let lhsKind = PlaceKind.allCases.firstIndex(of: lhs.kind) ?? 0
        let rhsKind = PlaceKind.allCases.firstIndex(of: rhs.kind) ?? 0
        return (lhsKind, lhs.slug) < (rhsKind, rhs.slug)
    }

    public static func refs(inTags tags: [String]) -> [PlaceRef] {
        var seen: Set<PlaceRef> = []
        return tags.compactMap(PlaceRef.init(tag:)).filter { seen.insert($0).inserted }
    }
}

public struct PlaceRecord: Codable, Equatable, Sendable {
    public let ref: PlaceRef
    public var title: String
    public var aliases: [String]
    public var externalRef: String?
    public var archived: Bool

    public init(ref: PlaceRef, title: String, aliases: [String] = [], externalRef: String? = nil, archived: Bool = false) {
        self.ref = ref
        self.title = title
        self.aliases = aliases
        self.externalRef = externalRef
        self.archived = archived
    }

    public func matches(_ needle: String) -> Bool {
        let lowered = needle.lowercased()
        return title.lowercased().contains(lowered)
            || aliases.contains { $0.lowercased().contains(lowered) }
            || ref.slug.rawValue.contains(lowered)
    }

    /// Lower is better: 0 prefix, 1 substring, 2 subsequence; nil when nothing matches.
    public func fuzzyScore(_ query: String) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let candidates = ([title, ref.tag] + aliases).map { $0.lowercased() }
        if candidates.contains(where: { $0.hasPrefix(needle) }) { return 0 }
        if candidates.contains(where: { $0.contains(needle) }) { return 1 }
        let isSubsequence: (String) -> Bool = { candidate in
            var remaining = Substring(needle)
            for character in candidate where character == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
            return false
        }
        return candidates.contains(where: isSubsequence) ? 2 : nil
    }

    public static func fuzzyMatches(_ query: String, in places: [PlaceRecord]) -> [PlaceRecord] {
        places
            .compactMap { place in place.fuzzyScore(query).map { (place, $0) } }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.ref < rhs.0.ref }
            .map(\.0)
    }
}

public struct PlaceListResult: Codable, Equatable, Sendable {
    public let places: [PlaceRecord]
    public let resolution: SnippetResolutionMode

    public init(places: [PlaceRecord], resolution: SnippetResolutionMode) {
        self.places = places
        self.resolution = resolution
    }
}

extension MemosWireFormat {
    public static let placeMarkerTag = "#rewind/place"

    private static let placeTitlePrefix = "> **Title:**"
    private static let placeAliasesPrefix = "> **Aliases:**"
    private static let placeRefPrefix = "> **Ref:**"
    private static let placeStatusPrefix = "> **Status:**"

    public static func formatPlaceMemo(_ place: PlaceRecord, body: String = "") -> String {
        let aliases = place.aliases.flatMap { $0.split(separator: ",") }.compactMap { sanitizePlaceField(String($0)) }
        var lines = [
            "\(placeMarkerTag) #\(place.ref.tag)",
            "",
            "\(placeTitlePrefix) \(sanitizePlaceField(place.title) ?? place.ref.slug.rawValue)",
            aliases.isEmpty ? placeAliasesPrefix : "\(placeAliasesPrefix) \(aliases.joined(separator: ", "))"
        ]
        if let externalRef = place.externalRef.flatMap(sanitizePlaceField) {
            lines.append("\(placeRefPrefix) \(externalRef)")
        }
        lines.append("\(placeStatusPrefix) \(place.archived ? "archived" : "active")")
        let header = lines.joined(separator: "\n")
        return body.isEmpty ? header : header + "\n\n" + body
    }

    public static func parsePlaceMemo(_ rawContent: String) -> (place: PlaceRecord, body: String)? {
        let tokens = headerTokens(rawContent)
        guard tokens.contains(where: { $0.lowercased() == placeMarkerTag }),
              let ref = tokens.lazy.compactMap({ PlaceRef(tag: String($0)) }).first else {
            return nil
        }

        var cursor = nextLine(in: rawContent, from: rawContent.startIndex)?.nextStart ?? rawContent.endIndex
        while let (line, afterLine) = nextLine(in: rawContent, from: cursor), isHorizontalBlank(line) {
            cursor = afterLine
        }

        let prefixes = [placeTitlePrefix, placeAliasesPrefix, placeRefPrefix, placeStatusPrefix]
        var title: String?
        var aliases: [String] = []
        var externalRef: String?
        var archived = false
        var sawMetadata = false
        while let (line, afterLine) = nextLine(in: rawContent, from: cursor),
              let prefix = prefixes.first(where: { line.hasPrefix($0) }) {
            let value = trimHorizontalWhitespace(line.dropFirst(prefix.count))
            switch prefix {
            case placeTitlePrefix:
                title = value.isEmpty ? nil : value
            case placeAliasesPrefix:
                aliases = value.split(separator: ",").map { trimHorizontalWhitespace($0) }.filter { !$0.isEmpty }
            case placeRefPrefix:
                externalRef = value.isEmpty ? nil : value
            default:
                archived = value.lowercased() == "archived"
            }
            sawMetadata = true
            cursor = afterLine
        }

        if sawMetadata,
           let (separatorLine, afterSeparator) = nextLine(in: rawContent, from: cursor),
           isHorizontalBlank(separatorLine) {
            cursor = afterSeparator
        }
        let place = PlaceRecord(
            ref: ref,
            title: title ?? ref.slug.rawValue,
            aliases: aliases,
            externalRef: externalRef,
            archived: archived
        )
        return (place, String(rawContent[cursor...]))
    }

    private static func sanitizePlaceField(_ raw: String) -> String? {
        let singleLine = raw
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return singleLine.isEmpty ? nil : singleLine
    }
}

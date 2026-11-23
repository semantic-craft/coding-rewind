// SPDX-License-Identifier: MIT

public struct CapturePreferences: Equatable, Sendable {
    public let defaultPlace: PlaceRef?
    public let defaultTags: [String]
    public let includeContext: Bool
    public let enrichWithAI: Bool

    public init(
        defaultPlace: PlaceRef? = nil,
        defaultTags: [String] = [],
        includeContext: Bool = true,
        enrichWithAI: Bool = true
    ) {
        self.defaultPlace = defaultPlace?.kind == .person ? nil : defaultPlace
        var seenTags: Set<String> = []
        self.defaultTags = defaultTags.compactMap { rawTag in
            guard let tag = Self.normalizedTag(rawTag),
                  seenTags.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
        self.includeContext = includeContext
        self.enrichWithAI = enrichWithAI
    }

    public static func normalizedTag(_ rawTag: String) -> String? {
        guard let tag = MemosWireFormat.sanitizeCustomTag(rawTag),
              PlaceKind(rawValue: tag.prefix { $0 != "/" }.lowercased()) == nil else {
            return nil
        }
        return tag
    }
}

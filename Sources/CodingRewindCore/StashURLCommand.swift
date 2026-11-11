// SPDX-License-Identifier: MIT

import Foundation

public enum StashURLError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedURL(String)
    case missingExcerpt
    case invalidSourceURL(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let raw):
            return "不支持的 URL 协议或路径: \(raw)"
        case .missingExcerpt:
            return "URL 或剪贴板中缺少要保存的片段原文。"
        case .invalidSourceURL(let raw):
            return "无效的来源网址: \(raw)"
        }
    }
}

public struct StashURLCommand: Equatable, Sendable {
    public static let scheme = "coding-rewind"
    public static let stashHost = "stash"

    public let newClip: NewClip
    public let isSilent: Bool

    public static func parse(
        _ url: URL,
        clipboardText: () -> String?,
        now: Date = Date()
    ) throws -> StashURLCommand {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == stashHost else {
            throw StashURLError.unsupportedURL(url.absoluteString)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func value(for name: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == name.lowercased() })?.value
        }

        let useClipboard = isTruthyFlag(value(for: "clipboard"))
        let isSilent = isTruthyFlag(value(for: "silent"))

        let resolvedExcerpt: String?
        if let directExcerpt = value(for: "excerpt"),
           !directExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedExcerpt = directExcerpt
        } else if useClipboard {
            resolvedExcerpt = clipboardText()
        } else {
            resolvedExcerpt = nil
        }

        guard let excerptText = resolvedExcerpt else {
            throw StashURLError.missingExcerpt
        }

        let sourceURLString = value(for: "url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedSourceURL: URL?
        if let sourceURLString, !sourceURLString.isEmpty {
            guard let candidate = URL(string: sourceURLString),
                  let candidateScheme = candidate.scheme?.lowercased(),
                  candidateScheme == "https" || candidateScheme == "http" else {
                throw StashURLError.invalidSourceURL(sourceURLString)
            }
            parsedSourceURL = candidate
        }

        let rawSourceParam = value(for: "source")
        let pageTitle = value(for: "title")
        let customNote = value(for: "note")
        let rawTags = value(for: "tags")
        let parsedTags = rawTags?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let clipSource: ClipSource
        if rawSourceParam?.lowercased() == "antigravity" {
            let convID = value(for: "conversation_id") ?? value(for: "conversationid")
            let workspace = value(for: "workspace")
            let locator = convID.map { "conversation://\($0)" }
            clipSource = .antigravity(conversationId: convID, workspacePath: workspace, locator: locator)
        } else {
            let site = WebChatSite.infer(sourceParam: rawSourceParam, url: parsedSourceURL, windowTitle: pageTitle)
            clipSource = .web(
                site: site,
                url: parsedSourceURL?.absoluteString,
                pageTitle: pageTitle
            )
        }

        let newClip: NewClip
        do {
            newClip = try NewClip(
                excerpt: excerptText,
                promptContext: PromptContext.from(raw: value(for: "prompt")),
                source: clipSource,
                capturedAt: now,
                annotation: ClipAnnotation(title: pageTitle, tags: parsedTags, userNote: customNote)
            )
        } catch StashError.emptyExcerpt {
            throw StashURLError.missingExcerpt
        }

        return StashURLCommand(newClip: newClip, isSilent: isSilent)
    }

    private static func isTruthyFlag(_ raw: String?) -> Bool {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }
}

// SPDX-License-Identifier: MIT

import Foundation
import CodingRewindCore

enum NativeSelectionMarkdown {
    static func codeBlock(_ text: String, language: String = "") -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(text) + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    static func convert(html: String, plainText: String, boldRanges: [NSRange] = []) -> String? {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodePreserveWhitespace]),
              let body = try? document.nodes(forXPath: "//body").first else { return nil }
        let renderedPlain = render(body, markdown: false)
        if renderedPlain == plainText { return render(body, markdown: true, boldRanges: boldRanges) }
        guard let range = renderedPlain.range(of: plainText, options: .literal),
              renderedPlain[..<range.lowerBound].allSatisfy(\.isWhitespace),
              renderedPlain[range.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
        let leading = renderedPlain.distance(from: renderedPlain.startIndex, to: range.lowerBound)
        let trailing = renderedPlain.distance(from: range.upperBound, to: renderedPlain.endIndex)
        let utf16Leading = renderedPlain[..<range.lowerBound].utf16.count
        let renderedMarkdown = render(body, markdown: true,
            boldRanges: boldRanges.map { NSRange(location: $0.location + utf16Leading, length: $0.length) })
        guard renderedMarkdown.hasPrefix(String(renderedPlain.prefix(leading))),
              renderedMarkdown.hasSuffix(String(renderedPlain.suffix(trailing))) else { return nil }
        return String(renderedMarkdown.dropFirst(leading).dropLast(trailing))
    }

    static func boldRanges(snapshot: NativeConversationSnapshot?, selectedText: String) -> [NSRange] {
        guard let snapshot else { return [] }
        let matching = snapshot.entries.compactMap { entry -> NativeConversationSnapshot.Message? in
            guard case .message(let message) = entry, message.renderedText.range(of: selectedText, options: .literal) != nil else { return nil }
            return message
        }
        guard matching.count == 1, let message = matching.first else { return [] }
        return boldRanges(description: message.contextText, renderedText: message.renderedText, selectedText: selectedText)
    }

    static func boldRanges(description: String, renderedText: String, selectedText: String) -> [NSRange] {
        var plain = ""
        var ranges: [NSRange] = []
        var cursor = description.startIndex
        while let start = description.range(of: "**", range: cursor..<description.endIndex),
              let end = description.range(of: "**", range: start.upperBound..<description.endIndex) {
            plain += description[cursor..<start.lowerBound]
            let content = String(description[start.upperBound..<end.lowerBound])
            ranges.append(NSRange(location: plain.utf16.count, length: content.utf16.count))
            plain += content
            cursor = end.upperBound
        }
        plain += description[cursor...]
        guard plain == renderedText, !selectedText.isEmpty,
              let selected = renderedText.range(of: selectedText, options: .literal),
              renderedText.range(of: selectedText, options: .literal, range: selected.upperBound..<renderedText.endIndex) == nil else { return [] }
        let selectedRange = NSRange(selected, in: renderedText)
        return ranges.compactMap { range in
            let overlap = NSIntersectionRange(range, selectedRange)
            return overlap.length == 0 ? nil : NSRange(location: overlap.location - selectedRange.location, length: overlap.length)
        }
    }

    private static func render(_ node: XMLNode, markdown: Bool, boldRanges: [NSRange] = []) -> String {
        var offset = 0
        return render(node, markdown: markdown, boldRanges: boldRanges, offset: &offset)
    }

    private static func render(_ node: XMLNode, markdown: Bool, boldRanges: [NSRange], offset: inout Int) -> String {
        if node.kind == .text {
            let text = node.stringValue ?? ""
            let range = NSRange(location: offset, length: text.utf16.count)
            offset += range.length
            guard markdown else { return text }
            let localRanges = boldRanges.map { NSIntersectionRange($0, range) }.filter { $0.length > 0 }
            let source = text as NSString
            var result = ""
            var cursor = 0
            for overlap in localRanges {
                let start = overlap.location - range.location
                result += source.substring(with: NSRange(location: cursor, length: start - cursor))
                result += "**" + source.substring(with: NSRange(location: start, length: overlap.length)) + "**"
                cursor = start + overlap.length
            }
            return result + source.substring(from: cursor)
        }
        let tag = node.name?.lowercased() ?? ""
        if ["head", "meta", "script", "style"].contains(tag) { return "" }
        if tag == "br" { offset += 1; return "\n" }
        let childBoldRanges = ["strong", "b"].contains(tag) ? [] : boldRanges
        let content = (node.children ?? []).map { render($0, markdown: markdown, boldRanges: childBoldRanges, offset: &offset) }.joined()
        guard markdown else { return content }
        switch tag {
        case "strong", "b": return "**\(content)**"
        case "em", "i": return "*\(content)*"
        case "code":
            if node.parent?.name?.lowercased() == "pre" { return content }
            let fence = String(repeating: "`", count: longestBacktickRun(content) + 1)
            let pad = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
            return "\(fence)\(pad)\(content)\(pad)\(fence)"
        case "pre":
            let code = (node.children ?? []).first { $0.name?.lowercased() == "code" } as? XMLElement
            let language = code?.attribute(forName: "class")?.stringValue?
                .split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("language-") }
                .map { String($0.dropFirst("language-".count)) } ?? ""
            return codeBlock(content, language: language)
        case "a":
            guard let href = (node as? XMLElement)?.attribute(forName: "href")?.stringValue else { return content }
            return "[\(content)](\(href))"
        default: return content
        }
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

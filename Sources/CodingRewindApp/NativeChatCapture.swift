// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CodingRewindCore
import Foundation

@MainActor
enum NativeChatAXCapture {
    @MainActor
    struct Observation {
        let host: NativeChatHost
        let title: String
        let window: AXUIElement
        let messages: [ObservedEntry]
        func isCodeSelection(_ selectedText: String) -> Bool {
            let matching = messages.filter { message in
                guard case .message(let entry) = message.entry,
                      let range = entry.renderedText.range(of: selectedText, options: .literal),
                      entry.renderedText.range(of: selectedText, options: .literal,
                          range: range.upperBound..<entry.renderedText.endIndex) == nil else { return false }
                return message.codeBlocks.contains { $0.range(of: selectedText, options: .literal) != nil }
            }
            return matching.count == 1
        }

        func result(app: AXUIElement, selectedText: String, backlink: URL? = nil) -> NativeChatCapture {
            guard let currentWindow = AXSupport.focusedWindow(app), CFEqual(window, currentWindow),
                  let current = read(host: host, window: currentWindow),
                  messages.map(\.entry) == current.map(\.entry) else { return NativeChatCapture(host: host, title: title) }
            let metadata = NativeChatCapture(host: host, title: title, backlink: backlink)
            let selection = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
            let matches = messages.indices.filter { index in
                guard case .message(let message) = messages[index].entry else { return false }
                return message.renderedText.replacingOccurrences(of: "\r\n", with: "\n")
                    .range(of: selection, options: .literal) != nil
            }
            let direct = matches.filter { messages[$0].selectedText == selectedText }
            let anchor: NativeConversationSnapshot.Anchor
            let selectedIndex: Int
            if direct.count == 1, let index = direct.first {
                anchor = .message(index)
                selectedIndex = index
            } else if matches.count == 1, let index = matches.first {
                anchor = .uniqueText
                selectedIndex = index
            } else {
                return metadata
            }
            guard CFEqual(messages[selectedIndex].element, current[selectedIndex].element) else { return metadata }
            return NativeChatCapture(host: host, title: title, backlink: backlink,
                snapshot: .init(entries: messages.map(\.entry), anchor: anchor), renderedSelection: selectedText)
        }
    }

    struct ObservedEntry {
        let entry: NativeConversationSnapshot.Entry
        let element: AXUIElement
        let selectedText: String?
        var codeBlocks: [String] = []
    }

    static func observe(app: AXUIElement, bundleIdentifier: String, windowTitle: String?, focused: AXUIElement?) -> Observation? {
        guard let host = host(bundleIdentifier: bundleIdentifier),
              let window = AXSupport.focusedWindow(app) else { return nil }
        let selectedCode = host == .chatGPT ? focused.flatMap(renderedCodeEditor(owning:)) : nil
        var ancestor = focused
        while let node = ancestor {
            let role = AXSupport.role(node) ?? ""
            if ([kAXTextAreaRole, kAXTextFieldRole, kAXOutlineRole].contains(role) &&
                !(selectedCode.map { CFEqual(node, $0) } ?? false)) ||
                (host == .chatGPT && role == "AXWebArea" && !isChatGPTShell(node)) {
                return Observation(host: host, title: title(host: host, windowTitle: windowTitle), window: window, messages: [])
            }
            ancestor = AXSupport.parent(node)
        }
        return Observation(host: host, title: title(host: host, windowTitle: windowTitle), window: window,
            messages: read(host: host, window: window) ?? [])
    }

    static func host(bundleIdentifier: String) -> NativeChatHost? {
        switch bundleIdentifier {
        case AppBundleID.codex: .chatGPT
        case AppBundleID.gemini: .gemini
        default: nil
        }
    }

    static func title(host: NativeChatHost, windowTitle: String?) -> String {
        var title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host == .gemini, title.hasPrefix("Gemini - ") {
            title = String(title.dropFirst("Gemini - ".count))
        }
        return title.isEmpty ? (host == .chatGPT ? "ChatGPT" : "Gemini") : title
    }

    private static func read(host: NativeChatHost, window: AXUIElement) -> [ObservedEntry]? {
        switch host {
        case .chatGPT: chatGPTMessages(window: window)
        case .gemini: geminiMessages(window: window)
        }
    }

    private static func chatGPTMessages(window: AXUIElement) -> [ObservedEntry]? {
        guard let area = descendants(window).first(where: isChatGPTShell),
              let conversation = AXSupport.children(area).flatMap({ descendants($0, excludingWebAreas: true) }).first(where: {
                  AXSupport.subrole($0) == "AXLandmarkRegion" && AXSupport.title($0) == "Conversation"
              }) else { return nil }
        let groups = descendants(conversation, excludingWebAreas: true).filter { AXSupport.children($0).contains { messageRole($0) != nil } }
        var result: [ObservedEntry] = []
        for group in groups {
            var heading: AXUIElement?
            var role: NativeConversationSnapshot.Message.Role?
            var bodies: [AXUIElement] = []
            var selected: String?
            func appendMessage() {
                guard let heading, let role else { return }
                let rendered = renderedMessage(bodies: bodies, area: area)
                let text = rendered?.text ?? ""
                let entry: NativeConversationSnapshot.Entry = text.isEmpty ? .gap : .message(.init(
                    role: role, renderedText: text, contextText: rendered?.contextText))
                result.append(ObservedEntry(entry: entry, element: heading, selectedText: selected, codeBlocks: rendered?.codeBlocks ?? []))
            }
            for node in AXSupport.children(group) {
                if let nextRole = messageRole(node) {
                    appendMessage()
                    heading = node
                    role = nextRole
                    bodies = []
                    selected = nil
                } else if role != nil {
                    guard [kAXGroupRole, kAXStaticTextRole].contains(AXSupport.role(node) ?? ""),
                          let text = renderedMessage(bodies: [node], area: area)?.text, !text.isEmpty else { continue }
                    bodies.append(node)
                    if let selection = AXSupport.string(node, kAXSelectedTextAttribute), !selection.isEmpty {
                        selected = selection
                    }
                }
            }
            appendMessage()
        }
        return result
    }

    private static func isChatGPTShell(_ node: AXUIElement) -> Bool {
        AXSupport.role(node) == "AXWebArea" && ChatGPTWebAreaClassification.classify(webArea: node) == .shell
    }

    private struct RenderedMessage {
        let text: String
        let contextText: String
        var codeBlocks: [String] = []
    }

    private static func renderedMessage(bodies: [AXUIElement], area: AXUIElement) -> RenderedMessage? {
        guard bodies.contains(where: { descendants($0).contains(where: isCodeEditor) }) else {
            return renderedText(bodies: bodies, area: area).map { RenderedMessage(text: $0, contextText: $0) }
        }
        func render(_ node: AXUIElement) -> RenderedMessage? {
            let nodes = descendants(node)
            if classes(node).contains(where: { $0.hasPrefix("CodeSurface-") }),
               let editor = nodes.first(where: isCodeEditor), let code = codeBlock(editor) {
                return RenderedMessage(text: code.text, contextText: NativeSelectionMarkdown.codeBlock(code.text), codeBlocks: [code.text])
            }
            guard nodes.contains(where: isCodeEditor) else {
                return renderedText(bodies: [node], area: area).map { RenderedMessage(text: $0, contextText: $0) }
            }
            let parts = AXSupport.children(node).compactMap(render)
            return RenderedMessage(text: parts.map(\.text).joined(separator: "\n\n"),
                contextText: parts.map(\.contextText).joined(separator: "\n\n"), codeBlocks: parts.flatMap(\.codeBlocks))
        }
        let parts = bodies.compactMap(render)
        return RenderedMessage(text: parts.map(\.text).joined(separator: "\n\n"),
            contextText: parts.map(\.contextText).joined(separator: "\n\n"), codeBlocks: parts.flatMap(\.codeBlocks))
    }

    private static func renderedCodeEditor(owning focused: AXUIElement) -> AXUIElement? {
        var node: AXUIElement? = focused
        var editor: AXUIElement?
        var inConversation = false
        while let current = node {
            if isCodeEditor(current) { editor = current }
            if AXSupport.subrole(current) == "AXLandmarkRegion",
               AXSupport.title(current) == "Conversation" { inConversation = true }
            if isChatGPTShell(current) { return inConversation ? editor : nil }
            node = AXSupport.parent(current)
        }
        return nil
    }

    private static func isCodeEditor(_ node: AXUIElement) -> Bool {
        NativeChatCodeBlock.isEditor(role: AXSupport.role(node),
            title: AXSupport.title(node), classes: classes(node))
    }

    private static func codeBlock(_ editor: AXUIElement) -> NativeChatCodeBlock? {
        let lines = AXSupport.children(editor).filter { classes($0).contains("cm-line") }
        guard !lines.isEmpty else { return nil }
        return NativeChatCodeBlock(lines: lines.map { line in
            descendants(line).filter { AXSupport.role($0) == kAXStaticTextRole }
                .compactMap { AXSupport.string($0, kAXValueAttribute) }
        })
    }

    private static func classes(_ node: AXUIElement) -> [String] {
        AXSupport.value(node, "AXDOMClassList") as? [String] ?? []
    }

    private static func renderedText(bodies: [AXUIElement], area: AXUIElement) -> String? {
        guard let first = bodies.first, let last = bodies.last else { return nil }
        let range: CFTypeRef?
        if bodies.count == 1 {
            range = AXSupport.parameterizedValue(area, "AXTextMarkerRangeForUIElement", first)
        } else if let start = AXSupport.value(first, "AXStartTextMarker"), let end = AXSupport.value(last, "AXEndTextMarker") {
            range = AXSupport.parameterizedValue(area, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
        } else {
            range = nil
        }
        guard let range else { return nil }
        return AXSupport.parameterizedValue(area, "AXStringForTextMarkerRange", range) as? String
    }

    private static func messageRole(_ node: AXUIElement) -> NativeConversationSnapshot.Message.Role? {
        guard AXSupport.role(node) == "AXHeading" else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { AXSupport.string(node, $0) }.first { !$0.isEmpty }
        switch label {
        case "You said:": return .user
        case "ChatGPT said:": return .assistant
        default: return nil
        }
    }

    private static func geminiMessages(window: AXUIElement) -> [ObservedEntry]? {
        guard let column = descendants(window).first(where: {
            AXSupport.role($0) == kAXColumnRole && AXSupport.identifier($0) == "content"
        }), let content = AXSupport.parent(column) else { return nil }
        return AXSupport.children(content).filter { AXSupport.role($0) == kAXRowRole }.map { row in
            let nodes = descendants(row)
            if let heading = nodes.first(where: { AXSupport.role($0) == "AXHeading" }),
               let text = AXSupport.descriptionText(heading), !text.isEmpty {
                return ObservedEntry(entry: .message(.init(role: .user, renderedText: text)), element: row,
                    selectedText: AXSupport.string(heading, kAXSelectedTextAttribute))
            }
            let staticTexts = nodes.filter { AXSupport.role($0) == kAXStaticTextRole }
            let parts = nodes.compactMap { node -> RenderedMessage? in
                if AXSupport.role(node) == kAXStaticTextRole,
                   let text = AXSupport.string(node, kAXValueAttribute), !text.isEmpty {
                    return RenderedMessage(text: text, contextText: AXSupport.descriptionText(node) ?? text)
                }
                guard let attachment = NativeChatCodeBlock.geminiAttachment(
                    identifier: AXSupport.identifier(node), description: AXSupport.descriptionText(node),
                    renderedText: AXSupport.string(node, kAXValueAttribute)) else { return nil }
                return RenderedMessage(text: attachment.text, contextText: attachment.markdown)
            }
            let text = parts.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { return ObservedEntry(entry: .gap, element: row, selectedText: nil) }
            let description = parts.map(\.contextText).joined(separator: "\n")
            let descriptions = description.hasSuffix("\n") ? [description, String(description.dropLast())] : [description]
            let contextText = descriptions.first {
                !NativeSelectionMarkdown.boldRanges(description: $0, renderedText: text, selectedText: text).isEmpty
            } ?? (nodes.contains(where: AXSupport.isGeminiCodeAttachment) ? description : text)
            return ObservedEntry(entry: .message(.init(role: .assistant, renderedText: text, contextText: contextText)), element: row,
                selectedText: staticTexts.compactMap { AXSupport.string($0, kAXSelectedTextAttribute) }.first { !$0.isEmpty })
        }
    }

    private static func descendants(_ root: AXUIElement, excludingWebAreas: Bool = false) -> [AXUIElement] {
        let role = AXSupport.role(root)
        if excludingWebAreas, role == "AXWebArea" { return [] }
        if [kAXOutlineRole, kAXMenuBarRole, kAXTextFieldRole].contains(role ?? "") ||
            (role == kAXButtonRole && !AXSupport.isGeminiCodeAttachment(root)) ||
            (role == kAXTextAreaRole && !isCodeEditor(root)) { return [] }
        return [root] + AXSupport.children(root).flatMap { descendants($0, excludingWebAreas: excludingWebAreas) }
    }
}

struct NativeChatCodeBlock {
    let lines: [[String]]

    var text: String { lines.map { $0.joined() }.joined(separator: "\n") }

    static func geminiAttachment(
        identifier: String?, description: String?, renderedText: String?
    ) -> (text: String, markdown: String)? {
        guard identifier == "code-widget-download-button-code-widget-download-button-code-widget-copy-button-code-widget-copy-button",
              let description, let renderedText, let attachment = renderedText.range(of: "\u{fffc}"),
              let fence = description.range(of: "```"),
              let start = description[fence.upperBound...].firstIndex(of: "\n"),
              let end = description.range(of: "\n```", options: .backwards), start < end.lowerBound else { return nil }
        let code = String(description[description.index(after: start)..<end.lowerBound])
        return (renderedText.replacingCharacters(in: attachment, with: code), description)
    }

    static func isEditor(role: String?, title: String?, classes: [String]) -> Bool {
        role == "AXTextArea" && title == "Edit code" && classes.contains("cm-content")
    }
}

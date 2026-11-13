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
            guard let currentWindow = element(value(app, kAXFocusedWindowAttribute)), CFEqual(window, currentWindow),
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
              let window = element(value(app, kAXFocusedWindowAttribute)) else { return nil }
        let selectedCode = host == .chatGPT ? focused.flatMap(renderedCodeEditor(owning:)) : nil
        var ancestor = focused
        while let node = ancestor {
            let role = string(node, kAXRoleAttribute) ?? ""
            if ([kAXTextAreaRole, kAXTextFieldRole, kAXOutlineRole].contains(role) &&
                !(selectedCode.map { CFEqual(node, $0) } ?? false)) ||
                (host == .chatGPT && role == "AXWebArea" && !isChatGPTShell(node)) {
                return Observation(host: host, title: title(host: host, windowTitle: windowTitle), window: window, messages: [])
            }
            ancestor = element(value(node, kAXParentAttribute))
        }
        return Observation(host: host, title: title(host: host, windowTitle: windowTitle), window: window,
            messages: read(host: host, window: window) ?? [])
    }

    static func host(bundleIdentifier: String) -> NativeChatHost? {
        switch bundleIdentifier {
        case "com.openai.codex": .chatGPT
        case "com.google.GeminiMacOS": .gemini
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
              let conversation = children(area).flatMap({ descendants($0, excludingWebAreas: true) }).first(where: {
                  string($0, kAXSubroleAttribute) == "AXLandmarkRegion" && string($0, kAXTitleAttribute) == "Conversation"
              }) else { return nil }
        let groups = descendants(conversation, excludingWebAreas: true).filter { children($0).contains { messageRole($0) != nil } }
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
            for node in children(group) {
                if let nextRole = messageRole(node) {
                    appendMessage()
                    heading = node
                    role = nextRole
                    bodies = []
                    selected = nil
                } else if role != nil {
                    guard [kAXGroupRole, kAXStaticTextRole].contains(string(node, kAXRoleAttribute) ?? ""),
                          let text = renderedMessage(bodies: [node], area: area)?.text, !text.isEmpty else { continue }
                    bodies.append(node)
                    if let selection = string(node, kAXSelectedTextAttribute), !selection.isEmpty {
                        selected = selection
                    }
                }
            }
            appendMessage()
        }
        return result
    }

    private static func isChatGPTShell(_ node: AXUIElement) -> Bool {
        guard string(node, kAXRoleAttribute) == "AXWebArea" else { return false }
        let rawURL = value(node, kAXURLAttribute)
        let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
        return url?.absoluteString == "app://-/index.html"
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
            let parts = children(node).compactMap(render)
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
            if string(current, kAXSubroleAttribute) == "AXLandmarkRegion",
               string(current, kAXTitleAttribute) == "Conversation" { inConversation = true }
            if isChatGPTShell(current) { return inConversation ? editor : nil }
            node = element(value(current, kAXParentAttribute))
        }
        return nil
    }

    private static func isCodeEditor(_ node: AXUIElement) -> Bool {
        NativeChatCodeBlock.isEditor(role: string(node, kAXRoleAttribute),
            title: string(node, kAXTitleAttribute), classes: classes(node))
    }

    private static func codeBlock(_ editor: AXUIElement) -> NativeChatCodeBlock? {
        let lines = children(editor).filter { classes($0).contains("cm-line") }
        guard !lines.isEmpty else { return nil }
        return NativeChatCodeBlock(lines: lines.map { line in
            descendants(line).filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }
                .compactMap { string($0, kAXValueAttribute) }
        })
    }

    private static func classes(_ node: AXUIElement) -> [String] {
        value(node, "AXDOMClassList") as? [String] ?? []
    }

    private static func renderedText(bodies: [AXUIElement], area: AXUIElement) -> String? {
        guard let first = bodies.first, let last = bodies.last else { return nil }
        let range: CFTypeRef?
        if bodies.count == 1 {
            range = parameter(area, "AXTextMarkerRangeForUIElement", first)
        } else if let start = value(first, "AXStartTextMarker"), let end = value(last, "AXEndTextMarker") {
            range = parameter(area, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
        } else {
            range = nil
        }
        guard let range else { return nil }
        return parameter(area, "AXStringForTextMarkerRange", range) as? String
    }

    private static func messageRole(_ node: AXUIElement) -> NativeConversationSnapshot.Message.Role? {
        guard string(node, kAXRoleAttribute) == "AXHeading" else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { string(node, $0) }.first { !$0.isEmpty }
        switch label {
        case "You said:": return .user
        case "ChatGPT said:": return .assistant
        default: return nil
        }
    }

    private static func geminiMessages(window: AXUIElement) -> [ObservedEntry]? {
        guard let column = descendants(window).first(where: {
            string($0, kAXRoleAttribute) == kAXColumnRole && string($0, kAXIdentifierAttribute) == "content"
        }), let content = element(value(column, kAXParentAttribute)) else { return nil }
        return children(content).filter { string($0, kAXRoleAttribute) == kAXRowRole }.map { row in
            let nodes = descendants(row)
            if let heading = nodes.first(where: { string($0, kAXRoleAttribute) == "AXHeading" }),
               let text = string(heading, kAXDescriptionAttribute), !text.isEmpty {
                return ObservedEntry(entry: .message(.init(role: .user, renderedText: text)), element: row,
                    selectedText: string(heading, kAXSelectedTextAttribute))
            }
            let staticTexts = nodes.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }
            let parts = nodes.compactMap { node -> RenderedMessage? in
                if string(node, kAXRoleAttribute) == kAXStaticTextRole,
                   let text = string(node, kAXValueAttribute), !text.isEmpty {
                    return RenderedMessage(text: text, contextText: string(node, kAXDescriptionAttribute) ?? text)
                }
                guard let attachment = NativeChatCodeBlock.geminiAttachment(
                    identifier: string(node, kAXIdentifierAttribute), description: string(node, kAXDescriptionAttribute),
                    renderedText: string(node, kAXValueAttribute)) else { return nil }
                return RenderedMessage(text: attachment.text, contextText: attachment.markdown)
            }
            let text = parts.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { return ObservedEntry(entry: .gap, element: row, selectedText: nil) }
            let description = parts.map(\.contextText).joined(separator: "\n")
            let descriptions = description.hasSuffix("\n") ? [description, String(description.dropLast())] : [description]
            let contextText = descriptions.first {
                !NativeSelectionMarkdown.boldRanges(description: $0, renderedText: text, selectedText: text).isEmpty
            } ?? (nodes.contains(where: isGeminiCodeAttachment) ? description : text)
            return ObservedEntry(entry: .message(.init(role: .assistant, renderedText: text, contextText: contextText)), element: row,
                selectedText: staticTexts.compactMap { string($0, kAXSelectedTextAttribute) }.first { !$0.isEmpty })
        }
    }

    private static func isGeminiCodeAttachment(_ node: AXUIElement) -> Bool {
        string(node, kAXRoleAttribute) == kAXButtonRole && NativeChatCodeBlock.geminiAttachment(
            identifier: string(node, kAXIdentifierAttribute), description: string(node, kAXDescriptionAttribute),
                    renderedText: string(node, kAXValueAttribute)) != nil
    }

    private static func descendants(_ root: AXUIElement, excludingWebAreas: Bool = false) -> [AXUIElement] {
        let role = string(root, kAXRoleAttribute)
        if excludingWebAreas, role == "AXWebArea" { return [] }
        if [kAXOutlineRole, kAXMenuBarRole, kAXTextFieldRole].contains(role ?? "") ||
            (role == kAXButtonRole && !isGeminiCodeAttachment(root)) ||
            (role == kAXTextAreaRole && !isCodeEditor(root)) { return [] }
        return [root] + children(root).flatMap { descendants($0, excludingWebAreas: excludingWebAreas) }
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        value(node, attribute) as? String
    }

    private static func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func parameter(_ node: AXUIElement, _ attribute: String, _ input: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(node, attribute as CFString, input, &result) == .success else { return nil }
        return result
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
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

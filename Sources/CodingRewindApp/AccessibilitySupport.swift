// SPDX-License-Identifier: MIT

import ApplicationServices
import CodingRewindCore
import Foundation

public enum AppBundleID {
    public static let selfApp = "dev.codingrewind.app"
    public static let antigravity = CapturedSelection.antigravityBundleIdentifier
    public static let gemini = "com.google.GeminiMacOS"
    public static let codex = "com.openai.codex"
    public static let safari = "com.apple.Safari"
    public static let chrome = "com.google.Chrome"
    public static let arc = "company.thebrowser.Browser"
    public static let brave = "com.brave.Browser"
    public static let supportedBrowserPrefixes = [safari, chrome, arc, brave]

    public static func isSelf(
        _ bundleIdentifier: String?,
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == selfApp || bundleIdentifier == mainBundleIdentifier
    }

    public static func isSupportedBrowser(_ bundleIdentifier: String) -> Bool {
        supportedBrowserPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }
}

package enum AntigravityWebAreaClassification: Equatable, Sendable {
    case conversation
    case childFrame
    case disallowed

    package static func classify(url: URL?) -> AntigravityWebAreaClassification {
        guard let url else { return .disallowed }
        if AntigravityConversationID(webAreaURL: url) != nil {
            return .conversation
        }
        if let scheme = url.scheme?.lowercased(), scheme == "data" || scheme == "about" {
            return .childFrame
        }
        return .disallowed
    }

    package static func classify(rawURLString: String?) -> AntigravityWebAreaClassification {
        guard let rawURLString, let url = URL(string: rawURLString) else {
            return .disallowed
        }
        return classify(url: url)
    }

    package static func classify(webArea: AXUIElement) -> AntigravityWebAreaClassification {
        classify(url: AXSupport.url(webArea))
    }
}

package enum AXSupport {
    @MainActor
    package static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    package static func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    package static func parameterizedValue(
        _ node: AXUIElement,
        _ attribute: String,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(node, attribute as CFString, parameter, &result) == .success else {
            return nil
        }
        return result
    }

    package static func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
    }

    package static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        element(value(node, attribute))
    }

    package static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        value(node, attribute) as? String
    }

    package static func bool(_ node: AXUIElement, _ attribute: String) -> Bool? {
        value(node, attribute) as? Bool
    }

    package static func int(_ node: AXUIElement, _ attribute: String) -> Int? {
        value(node, attribute) as? Int
    }

    package static func children(_ node: AXUIElement) -> [AXUIElement] {
        value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    package static func parent(_ node: AXUIElement) -> AXUIElement? {
        element(node, kAXParentAttribute)
    }

    package static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute)
    }

    package static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedUIElementAttribute)
    }

    package static func role(_ node: AXUIElement) -> String? {
        string(node, kAXRoleAttribute)
    }

    package static func subrole(_ node: AXUIElement) -> String? {
        string(node, kAXSubroleAttribute)
    }

    package static func identifier(_ node: AXUIElement) -> String? {
        string(node, kAXIdentifierAttribute)
    }

    package static func title(_ node: AXUIElement) -> String? {
        string(node, kAXTitleAttribute)
    }

    package static func descriptionText(_ node: AXUIElement) -> String? {
        string(node, kAXDescriptionAttribute)
    }

    package static func url(_ node: AXUIElement) -> URL? {
        let raw = value(node, kAXURLAttribute)
        return (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
    }

    package static func urlString(_ node: AXUIElement) -> String? {
        let raw = value(node, kAXURLAttribute)
        return (raw as? URL)?.absoluteString ?? (raw as? String)
    }

    package static func nearestWebArea(_ element: AXUIElement?, maxDepth: Int = 48) -> AXUIElement? {
        var current = element
        var depth = 0
        while let node = current, depth < maxDepth {
            depth += 1
            if role(node) == "AXWebArea" {
                return node
            }
            current = parent(node)
        }
        return nil
    }

    package static func cfRange(_ raw: CFTypeRef?) -> CFRange? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axVal) == .cfRange,
              AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    package static func cgRect(_ raw: CFTypeRef?) -> CGRect? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(axVal) == .cgRect,
              AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }

    package static func hasEditableAncestorValue(_ node: AXUIElement) -> Bool {
        guard let editable = value(node, "AXEditableAncestor"),
              CFGetTypeID(editable) != CFNullGetTypeID() else {
            return false
        }
        if let flag = editable as? Bool { return flag }
        return true
    }

    package static func isGeminiCodeAttachment(_ node: AXUIElement) -> Bool {
        role(node) == kAXButtonRole && NativeChatCodeBlock.geminiAttachment(
            identifier: identifier(node),
            description: descriptionText(node),
            renderedText: string(node, kAXValueAttribute)
        ) != nil
    }
}

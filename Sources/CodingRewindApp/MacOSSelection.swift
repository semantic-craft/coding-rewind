// SPDX-License-Identifier: MIT
// Selection capture via Accessibility + pasteboard-preserving Cmd+C adapted from tisfeng/SelectedTextKit (MIT) and p0deje/Maccy (MIT).

import AppKit
import ApplicationServices
import Carbon
import CodingRewindCore
import Foundation

public struct MacOSAccessibilitySelectionCapturer: SelectionCapturing {
    private let fallbackApplicationProvider: (@MainActor @Sendable () -> NSRunningApplication?)?

    public init(fallbackApplicationProvider: (@MainActor @Sendable () -> NSRunningApplication?)? = nil) {
        self.fallbackApplicationProvider = fallbackApplicationProvider
    }

    @MainActor
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    @MainActor
    public func captureFrontmostSelection() async throws -> CapturedSelection {
        let provider = fallbackApplicationProvider
        let resolvedTarget: (pid: pid_t, bundleID: String, appName: String)? = await MainActor.run {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let currentBundleID = Bundle.main.bundleIdentifier
            let candidate: NSRunningApplication?
            if let frontmost,
               frontmost.bundleIdentifier != currentBundleID,
               frontmost.bundleIdentifier != "dev.codingrewind.app" {
                candidate = frontmost
            } else {
                candidate = provider?()
            }
            guard let app = candidate, !app.isTerminated else { return nil }
            return (
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier ?? "unknown.bundle",
                appName: app.localizedName ?? "macOS"
            )
        }
        guard let target = resolvedTarget else { throw RewindError.noFrontmostApplication }
        let bundleID = target.bundleID
        let appName = target.appName
        let appElement = AXUIElementCreateApplication(target.pid)
        if bundleID == CapturedSelection.antigravityBundleIdentifier {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var windowTitle = Self.copyAXWindowString(appElement: appElement, attribute: kAXTitleAttribute as CFString)
        var documentURL = Self.copyAXWindowString(appElement: appElement, attribute: kAXDocumentAttribute as CFString)
        var selectedText: String?
        var selectedHTML: String?
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusStatus == .apiDisabled {
            await MainActor.run { _ = Self.isAccessibilityTrusted(prompt: true) }
            throw RewindError.accessibilityPermissionDenied
        }
        let focused = focusStatus == .success ? Self.axElement(focusedRef) : nil
        let chatDocument = bundleID == CapturedSelection.antigravityBundleIdentifier
            ? Self.chatDocument(owning: focused) : nil
        let nativeObservation = NativeChatAXCapture.observe(
            app: appElement, bundleIdentifier: bundleID, windowTitle: windowTitle, focused: focused
        )
        var conversationID: AntigravityConversationID?
        if let focused, let text = Self.axValue(focused, kAXSelectedTextAttribute) as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedText = text
            if let chatDocument, chatDocument.matches(Self.focusedChatDocument(in: appElement)) {
                conversationID = chatDocument.conversationID
            }
            if nativeObservation != nil {
                let copied = await Self.copyViaCommandCPreservingPasteboard(targetPID: target.pid, expectedChatURL: nil)
                selectedText = copied.text
                selectedHTML = copied.html
            }
        } else {
            let copied = await Self.copyViaCommandCPreservingPasteboard(
                targetPID: target.pid, expectedChatURL: chatDocument?.url
            )
            selectedText = copied.text
            if nativeObservation != nil { selectedHTML = copied.html }
            if copied.sameChatDocument { conversationID = chatDocument?.conversationID }
        }
        guard let finalSelection = selectedText, !finalSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        if Self.isSupportedBrowser(bundleID: bundleID), !(documentURL?.hasPrefix("http") ?? false) {
            let tab = await MainActor.run { Self.queryBrowserActiveTab(bundleID: bundleID) }
            if let t = tab.title, !t.isEmpty { windowTitle = t }
            if let u = tab.url, !u.isEmpty { documentURL = u }
        }
        var backlink: URL?
        if let nativeObservation {
            backlink = await NativeChatBacklink.capture(
                host: nativeObservation.host, application: appElement, window: nativeObservation.window
            )
        }
        let nativeChat = nativeObservation?.result(app: appElement, selectedText: finalSelection, backlink: backlink)
        let boldRanges = nativeChat?.host == .gemini
            ? NativeSelectionMarkdown.boldRanges(snapshot: nativeChat?.snapshot, selectedText: finalSelection) : []
        let htmlMarkdown = selectedHTML.flatMap {
            NativeSelectionMarkdown.convert(html: $0, plainText: finalSelection, boldRanges: boldRanges)
        }
        let verbatimText: String
        if nativeChat?.snapshot != nil,
           nativeObservation?.isCodeSelection(finalSelection) == true {
            verbatimText = NativeSelectionMarkdown.codeBlock(finalSelection)
        } else {
            verbatimText = htmlMarkdown ?? finalSelection
        }
        return CapturedSelection(
            text: verbatimText, bundleIdentifier: bundleID, appName: appName,
            windowTitle: windowTitle, documentURL: documentURL, antigravityConversationID: conversationID,
            nativeChat: nativeChat
        )
    }

    private struct ChatDocument {
        let area: AXUIElement
        let url: URL
        let conversationID: AntigravityConversationID

        func matches(_ other: ChatDocument?) -> Bool {
            guard let other else { return false }
            return CFEqual(area, other.area) && url == other.url
        }
    }

    private static func focusedChatDocument(in app: AXUIElement) -> ChatDocument? {
        chatDocument(owning: axElement(axValue(app, kAXFocusedUIElementAttribute)))
    }

    private static func chatDocument(owning focused: AXUIElement?) -> ChatDocument? {
        var element = focused
        while let current = element {
            let role = axValue(current, kAXRoleAttribute) as? String
            if role == kAXTextAreaRole || role == kAXTextFieldRole { return nil }
            if role == "AXWebArea" {
                let rawURL = axValue(current, kAXURLAttribute)
                let url = (rawURL as? URL) ?? (rawURL as? String).flatMap { URL(string: $0) }
                guard let url, let id = AntigravityConversationID(webAreaURL: url) else { return nil }
                return ChatDocument(area: current, url: url, conversationID: id)
            }
            element = axElement(axValue(current, kAXParentAttribute))
        }
        return nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private static func copyAXWindowString(appElement: AXUIElement, attribute: CFString) -> String? {
        guard let window = axElement(axValue(appElement, kAXFocusedWindowAttribute)) else { return nil }
        return axValue(window, attribute as String) as? String
    }

    @MainActor
    private static func copyViaCommandCPreservingPasteboard(
        targetPID: pid_t, expectedChatURL: URL?
    ) async -> (text: String?, html: String?, sameChatDocument: Bool) {
        guard await waitForReleasedModifiers() else { return (nil, nil, false) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID,
           let targetApp = NSRunningApplication(processIdentifier: targetPID) {
            _ = targetApp.activate()
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return (nil, nil, false) }
        let pasteboardSnapshot = PasteboardSnapshot()
        defer { pasteboardSnapshot.restoreIfChanged() }
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return (nil, nil, false) }
        let appElement = AXUIElementCreateApplication(targetPID)
        let beforeCopy = expectedChatURL == nil ? nil : focusedChatDocument(in: appElement)
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        for _ in 0..<20 {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return (nil, nil, false) }
            if pasteboard.changeCount != initialChangeCount {
                let text = pasteboard.string(forType: .string)
                let html = pasteboard.string(forType: .html)
                guard let beforeCopy, beforeCopy.url == expectedChatURL,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                    return (text, html, false)
                }
                return (text, html, beforeCopy.matches(focusedChatDocument(in: appElement)))
            }
        }
        return (nil, nil, false)
    }

    @MainActor
    private struct PasteboardSnapshot {
        let changeCount: Int
        let items: [[(NSPasteboard.PasteboardType, Data)]]

        init() {
            let pasteboard = NSPasteboard.general
            changeCount = pasteboard.changeCount
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }

        func restoreIfChanged() {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != changeCount else { return }
            pasteboard.clearContents()
            let restored = items.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    @MainActor
    static func waitForReleasedModifiers(
        timeout: Duration = .seconds(1),
        flags: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        while !flags().intersection(modifiers).isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return !Task.isCancelled
    }

    private static func isSupportedBrowser(bundleID: String) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser"].contains { bundleID.hasPrefix($0) }
    }

    @MainActor
    private static func queryBrowserActiveTab(bundleID: String) -> (title: String?, url: String?) {
        let isSafari = bundleID.hasPrefix("com.apple.Safari")
        let script = isSafari
            ? "tell application id \"com.apple.Safari\" to if (count of windows) > 0 then return (name of current tab of front window) & \"\\n\" & (URL of current tab of front window)"
            : "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\\n\" & (URL of active tab of front window)"
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue else { return (nil, nil) }
        let parts = out.components(separatedBy: "\n")
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}

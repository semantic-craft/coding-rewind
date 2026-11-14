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
    public func captureFrontmostSelection() async throws -> CapturedSelection {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let candidate: NSRunningApplication?
        if let frontmost, !AppBundleID.isSelf(frontmost.bundleIdentifier) {
            candidate = frontmost
        } else {
            candidate = fallbackApplicationProvider?()
        }
        guard let app = candidate, !app.isTerminated else {
            throw RewindError.noFrontmostApplication
        }
        let targetPID = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "unknown.bundle"
        let appName = app.localizedName ?? "macOS"
        let appElement = AXUIElementCreateApplication(targetPID)
        if bundleID == AppBundleID.antigravity {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let initialWindow = AXSupport.focusedWindow(appElement)
        var windowTitle = initialWindow.flatMap(AXSupport.title)
        var documentURL = initialWindow.flatMap { AXSupport.string($0, kAXDocumentAttribute) }
        var selectedText: String?
        var selectedHTML: String?
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusStatus == .apiDisabled {
            _ = AXSupport.isTrusted(prompt: true)
            throw RewindError.accessibilityPermissionDenied
        }
        let focused = focusStatus == .success ? AXSupport.element(focusedRef) : nil
        let isAntigravity = bundleID == AppBundleID.antigravity
        let directChatDocument = isAntigravity ? Self.chatDocument(owning: focused) : nil
        let fallbackWindowSelection: (document: ChatDocument, selectedText: String)? = {
            guard isAntigravity,
                  directChatDocument == nil,
                  AXSupport.nearestWebArea(focused) == nil,
                  !Self.hasEditableAncestor(focused),
                  let window = AXSupport.focusedWindow(appElement) else {
                return nil
            }
            return Self.uniqueSelectedChatDocument(in: window)
        }()
        let chatDocument = directChatDocument ?? fallbackWindowSelection?.document
        let nativeObservation = NativeChatAXCapture.observe(
            app: appElement, bundleIdentifier: bundleID, windowTitle: windowTitle, focused: focused
        )
        var conversationID: AntigravityConversationID?
        if let focused, let text = AXSupport.string(focused, kAXSelectedTextAttribute),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedText = text
            if let directChatDocument, directChatDocument.matches(Self.focusedChatDocument(in: appElement)) {
                conversationID = directChatDocument.conversationID
            } else if let fallback = fallbackWindowSelection, fallback.selectedText == text {
                conversationID = fallback.document.conversationID
            }
            if nativeObservation != nil {
                let copied = await Self.copyViaCommandCPreservingPasteboard(targetPID: targetPID, expectedChatURL: nil)
                selectedText = copied.text
                selectedHTML = copied.html
            }
        } else if let directChatDocument,
                  let areaText = AXSupport.string(directChatDocument.area, kAXSelectedTextAttribute),
                  !areaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedText = areaText
            if directChatDocument.matches(Self.focusedChatDocument(in: appElement)) {
                conversationID = directChatDocument.conversationID
            }
        } else if let fallback = fallbackWindowSelection {
            selectedText = fallback.selectedText
            if let window = AXSupport.focusedWindow(appElement),
               let rechecked = Self.uniqueSelectedChatDocument(in: window),
               rechecked.document.matches(fallback.document) {
                conversationID = fallback.document.conversationID
            }
        } else {
            let copied = await Self.copyViaCommandCPreservingPasteboard(
                targetPID: targetPID, expectedChatURL: chatDocument?.url
            )
            selectedText = copied.text
            if nativeObservation != nil { selectedHTML = copied.html }
            if copied.sameChatDocument { conversationID = chatDocument?.conversationID }
        }
        guard let finalSelection = selectedText, !finalSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        if AppBundleID.isSupportedBrowser(bundleID), !(documentURL?.hasPrefix("http") ?? false) {
            let tab = Self.queryBrowserActiveTab(bundleID: bundleID)
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
        chatDocument(owning: AXSupport.focusedElement(app))
    }

    private static func chatDocument(owning focused: AXUIElement?) -> ChatDocument? {
        var element = focused
        var depth = 0
        while let current = element, depth < 48 {
            depth += 1
            let role = AXSupport.role(current)
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole { return nil }
            if AXSupport.hasEditableAncestorValue(current) { return nil }
            if role == "AXWebArea" {
                if let document = chatDocument(forWebArea: current) {
                    return document
                }
                if AntigravityWebAreaClassification.classify(webArea: current) != .childFrame {
                    return nil
                }
            }
            element = AXSupport.parent(current)
        }
        return nil
    }

    private static func chatDocument(forWebArea area: AXUIElement) -> ChatDocument? {
        guard let url = AXSupport.url(area), let id = AntigravityConversationID(webAreaURL: url) else { return nil }
        return ChatDocument(area: area, url: url, conversationID: id)
    }

    private static func hasEditableAncestor(_ element: AXUIElement?) -> Bool {
        var current = element
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            let role = AXSupport.role(node)
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole { return true }
            if AXSupport.hasEditableAncestorValue(node) { return true }
            current = AXSupport.parent(node)
        }
        return false
    }

    private static func uniqueSelectedChatDocument(in window: AXUIElement) -> (document: ChatDocument, selectedText: String)? {
        var matches: [(document: ChatDocument, selectedText: String)] = []
        collectSelectedChatDocuments(in: window, depth: 0, into: &matches)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func collectSelectedChatDocuments(
        in element: AXUIElement,
        depth: Int,
        into matches: inout [(document: ChatDocument, selectedText: String)]
    ) {
        guard depth < 24, matches.count <= 1 else { return }
        let role = AXSupport.role(element)
        if let role, [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return
        }
        if role == "AXWebArea",
           !AXSupport.hasEditableAncestorValue(element),
           let document = chatDocument(forWebArea: element),
           let selected = AXSupport.string(element, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !matches.contains(where: { $0.document.matches(document) }) {
            matches.append((document, selected))
            if matches.count > 1 { return }
        }
        for child in AXSupport.children(element) {
            collectSelectedChatDocuments(in: child, depth: depth + 1, into: &matches)
            if matches.count > 1 { return }
        }
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

    @MainActor
    private static func queryBrowserActiveTab(bundleID: String) -> (title: String?, url: String?) {
        let isSafari = bundleID.hasPrefix(AppBundleID.safari)
        let script = isSafari
            ? "tell application id \"\(AppBundleID.safari)\" to if (count of windows) > 0 then return (name of current tab of front window) & \"\\n\" & (URL of current tab of front window)"
            : "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\\n\" & (URL of active tab of front window)"
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue else { return (nil, nil) }
        let parts = out.components(separatedBy: "\n")
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}

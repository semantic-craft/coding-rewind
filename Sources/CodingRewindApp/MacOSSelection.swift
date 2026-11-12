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
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusStatus == .apiDisabled {
            await MainActor.run { _ = Self.isAccessibilityTrusted(prompt: true) }
            throw RewindError.accessibilityPermissionDenied
        }
        if focusStatus == .success, let focusedObj = focusedRef, CFGetTypeID(focusedObj) == AXUIElementGetTypeID() {
            var selRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(unsafeDowncast(focusedObj as AnyObject, to: AXUIElement.self), kAXSelectedTextAttribute as CFString, &selRef) == .success,
               let text = selRef as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedText = text
            }
        }
        if selectedText == nil {
            let targetPID = target.pid
            selectedText = await Self.copyViaCommandCPreservingPasteboard(targetPID: targetPID)
        }
        guard let finalSelection = selectedText, !finalSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewindError.emptySelection
        }
        if Self.isSupportedBrowser(bundleID: bundleID), !(documentURL?.hasPrefix("http") ?? false) {
            let tab = await MainActor.run { Self.queryBrowserActiveTab(bundleID: bundleID) }
            if let t = tab.title, !t.isEmpty { windowTitle = t }
            if let u = tab.url, !u.isEmpty { documentURL = u }
        }
        return CapturedSelection(text: finalSelection, bundleIdentifier: bundleID, appName: appName, windowTitle: windowTitle, documentURL: documentURL)
    }

    private static func copyAXWindowString(appElement: AXUIElement, attribute: CFString) -> String? {
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winObj = winRef, CFGetTypeID(winObj) == AXUIElementGetTypeID() else { return nil }
        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(winObj as AnyObject, to: AXUIElement.self), attribute, &valRef) == .success else { return nil }
        return valRef as? String
    }

    @MainActor
    private static func copyViaCommandCPreservingPasteboard(targetPID: pid_t) async -> String? {
        guard await waitForReleasedModifiers() else { return nil }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID,
           let targetApp = NSRunningApplication(processIdentifier: targetPID) {
            _ = targetApp.activate()
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return nil }
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored: [NSPasteboardItem] = snapshot.compactMap { entries in
                guard !entries.isEmpty else { return nil }
                let pbItem = NSPasteboardItem()
                for (type, data) in entries { pbItem.setData(data, forType: type) }
                return pbItem
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        for _ in 0..<20 {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
            if pasteboard.changeCount != initialChangeCount { return pasteboard.string(forType: .string) }
        }
        return nil
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

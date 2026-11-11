// SPDX-License-Identifier: MIT
// Selection capture via Accessibility + pasteboard-preserving Cmd+C adapted from tisfeng/SelectedTextKit (MIT) and p0deje/Maccy (MIT).

import AppKit
import ApplicationServices
import Carbon
import CodingRewindCore
import Foundation

public struct MacOSAccessibilitySelectionCapturer: SelectionCapturing {
    public init() {}

    public func captureFrontmostSelection() async throws -> CapturedSelection {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { throw RewindError.noFrontmostApplication }
        let bundleID = frontmost.bundleIdentifier ?? "unknown.bundle"
        let appName = frontmost.localizedName ?? "macOS"
        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        if bundleID == CapturedSelection.antigravityBundleIdentifier {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var windowTitle = Self.copyAXWindowString(appElement: appElement, attribute: kAXTitleAttribute as CFString)
        var documentURL = Self.copyAXWindowString(appElement: appElement, attribute: kAXDocumentAttribute as CFString)
        var selectedText: String?
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusStatus == .apiDisabled { throw RewindError.accessibilityPermissionDenied }
        if focusStatus == .success, let focusedObj = focusedRef, CFGetTypeID(focusedObj) == AXUIElementGetTypeID() {
            var selRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(unsafeDowncast(focusedObj as AnyObject, to: AXUIElement.self), kAXSelectedTextAttribute as CFString, &selRef) == .success,
               let text = selRef as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedText = text
            }
        }
        if selectedText == nil {
            selectedText = await MainActor.run { Self.copyViaCommandCPreservingPasteboard() }
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
    private static func copyViaCommandCPreservingPasteboard() -> String? {
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
        for _ in 0..<12 {
            usleep(10_000)
            if pasteboard.changeCount != initialChangeCount { return pasteboard.string(forType: .string) }
        }
        return nil
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

@MainActor
public final class GlobalShortcutMonitor {
    private final class DispatchBox {
        let handler: @MainActor @Sendable (UInt32) -> Void
        init(handler: @escaping @MainActor @Sendable (UInt32) -> Void) { self.handler = handler }
    }
    private let onCapture: @MainActor () -> Void
    private let onToggleHUD: @MainActor () -> Void
    private var captureRef: EventHotKeyRef?
    private var toggleRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var box: DispatchBox?

    public init(onCapture: @escaping @MainActor () -> Void, onToggleHUD: @escaping @MainActor () -> Void) {
        self.onCapture = onCapture
        self.onToggleHUD = onToggleHUD
    }

    public func register() {
        let box = DispatchBox { [weak self] id in if id == 1 { self?.onCapture() } else if id == 2 { self?.onToggleHUD() } }
        self.box = box
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID) == noErr else { return noErr }
            let dispatch = Unmanaged<DispatchBox>.fromOpaque(userData).takeUnretainedValue().handler
            let pressedID = hkID.id
            Task { @MainActor in dispatch(pressedID) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(box).toOpaque(), &handlerRef)
        let mods = UInt32(controlKey | optionKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), mods, EventHotKeyID(signature: 0x4352_5744, id: 1), GetApplicationEventTarget(), 0, &captureRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), mods, EventHotKeyID(signature: 0x4352_5744, id: 2), GetApplicationEventTarget(), 0, &toggleRef)
    }
}

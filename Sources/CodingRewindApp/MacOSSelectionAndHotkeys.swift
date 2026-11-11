// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import Carbon
import CodingRewindCore
import Foundation

public struct MacOSAccessibilitySelectionCapturer: SelectionCapturing {
    public init() {}

    public func captureFrontmostSelection() async throws -> CapturedSelection {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw CaptureError.noFrontmostApplication
        }

        let bundleID = frontmostApp.bundleIdentifier ?? "unknown.bundle"
        let appName = frontmostApp.localizedName ?? "macOS Application"
        let pid = frontmostApp.processIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        if bundleID == CapturedSelection.antigravityBundleIdentifier {
            _ = AXUIElementSetAttributeValue(
                appElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        }

        var windowTitle: String?
        var documentURL: String?
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowElement = windowRef {
            let axWindow = windowElement as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let titleStr = titleRef as? String {
                windowTitle = titleStr
            }
            var docRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
               let docStr = docRef as? String {
                documentURL = docStr
            }
        }

        var selectedText: String?
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusStatus == .apiDisabled {
            throw CaptureError.accessibilityPermissionDenied
        }
        if focusStatus == .success, let focusedElement = focusedRef {
            let axFocused = focusedElement as! AXUIElement
            var selectedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axFocused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
               let text = selectedRef as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedText = text
            }
        }

        if selectedText == nil {
            if let fallbackText = await MainActor.run(body: {
                Self.readPasteboardWithSnapshotFallback()
            }), !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedText = fallbackText
            }
        }

        guard let finalSelection = selectedText,
              !finalSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.emptySelection
        }

        return CapturedSelection(
            text: finalSelection,
            bundleIdentifier: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            documentURL: documentURL,
            capturedAt: Date()
        )
    }

    @MainActor
    private static func readPasteboardWithSnapshotFallback() -> String? {
        let pasteboard = NSPasteboard.general
        return pasteboard.string(forType: .string)
    }
}

@MainActor
public final class GlobalShortcutMonitor {
    public struct KeyCombo: Equatable, Codable, Sendable {
        public let keyCode: UInt32
        public let carbonModifiers: UInt32

        public init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }

        public static let defaultCaptureSelection = KeyCombo(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(controlKey | optionKey)
        )

        public static let defaultToggleHUD = KeyCombo(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(controlKey | optionKey)
        )
    }

    private final class HotKeyDispatchBox {
        let dispatch: @MainActor @Sendable (UInt32) -> Void

        init(dispatch: @escaping @MainActor @Sendable (UInt32) -> Void) {
            self.dispatch = dispatch
        }
    }

    private let onCaptureSelection: @MainActor () -> Void
    private let onToggleHUD: @MainActor () -> Void
    private var captureHotKeyRef: EventHotKeyRef?
    private var toggleHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var dispatchBox: HotKeyDispatchBox?

    public init(
        onCaptureSelection: @escaping @MainActor () -> Void,
        onToggleHUD: @escaping @MainActor () -> Void
    ) {
        self.onCaptureSelection = onCaptureSelection
        self.onToggleHUD = onToggleHUD
    }

    public func register(
        captureCombo: KeyCombo = .defaultCaptureSelection,
        toggleHUDCombo: KeyCombo = .defaultToggleHUD
    ) {
        unregisterAll()
        let box = HotKeyDispatchBox { [weak self] idValue in
            guard let self else { return }
            if idValue == 1 {
                self.onCaptureSelection()
            } else if idValue == 2 {
                self.onToggleHUD()
            }
        }
        self.dispatchBox = box

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return noErr }
                let idValue = hotKeyID.id
                let retainedBox = Unmanaged<HotKeyDispatchBox>.fromOpaque(userData).takeUnretainedValue()
                let handler = retainedBox.dispatch
                Task { @MainActor in
                    handler(idValue)
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(box).toOpaque(),
            &eventHandlerRef
        )

        let signature: OSType = 0x4352_5744
        let captureID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            captureCombo.keyCode,
            captureCombo.carbonModifiers,
            captureID,
            GetApplicationEventTarget(),
            0,
            &captureHotKeyRef
        )

        let toggleID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(
            toggleHUDCombo.keyCode,
            toggleHUDCombo.carbonModifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
    }

    public func unregisterAll() {
        if let captureHotKeyRef {
            UnregisterEventHotKey(captureHotKeyRef)
            self.captureHotKeyRef = nil
        }
        if let toggleHotKeyRef {
            UnregisterEventHotKey(toggleHotKeyRef)
            self.toggleHotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        self.dispatchBox = nil
    }
}

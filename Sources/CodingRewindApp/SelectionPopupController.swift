// SPDX-License-Identifier: MIT
// Two-phase non-intrusive selection probe and floating capsule adapted from GaimsDevSoftware/linuxpop (MIT) and p0deje/Maccy (MIT).

import AppKit
import ApplicationServices
import CodingRewindCore
import KeyboardShortcuts
import Observation
import SwiftUI

package enum SelectionPopupHost: String, Equatable, Sendable {
    case antigravity = "com.google.antigravity"
    case geminiApp = "com.google.GeminiMacOS"

    package init?(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return nil }
        self.init(rawValue: bundleIdentifier)
    }
}

package struct SelectionGestureEvaluator: Equatable, Sendable {
    package static let minimumDragDistance: CGFloat = 6.0

    package struct Sample: Equatable, Sendable {
        package let mouseDownPoint: CGPoint
        package let mouseUpPoint: CGPoint
        package let clickCount: Int
        package let modifierFlags: NSEvent.ModifierFlags

        package init(
            mouseDownPoint: CGPoint,
            mouseUpPoint: CGPoint,
            clickCount: Int,
            modifierFlags: NSEvent.ModifierFlags = []
        ) {
            self.mouseDownPoint = mouseDownPoint
            self.mouseUpPoint = mouseUpPoint
            self.clickCount = clickCount
            self.modifierFlags = modifierFlags
        }

        package var dragDistance: CGFloat {
            hypot(mouseUpPoint.x - mouseDownPoint.x, mouseUpPoint.y - mouseDownPoint.y)
        }

        package var qualifies: Bool {
            dragDistance >= SelectionGestureEvaluator.minimumDragDistance
                || clickCount >= 2
                || modifierFlags.contains(.shift)
        }
    }

    package private(set) var mouseDownPoint: CGPoint?
    package private(set) var mouseDownClickCount: Int = 0
    package private(set) var mouseDownModifierFlags: NSEvent.ModifierFlags = []

    package init() {}

    package mutating func recordMouseDown(
        at point: CGPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        mouseDownPoint = point
        mouseDownClickCount = clickCount
        mouseDownModifierFlags = modifierFlags
    }

    package mutating func reset() {
        mouseDownPoint = nil
        mouseDownClickCount = 0
        mouseDownModifierFlags = []
    }

    package mutating func evaluateMouseUp(
        at point: CGPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Sample {
        let start = mouseDownPoint ?? point
        let effectiveClicks = max(mouseDownClickCount, clickCount)
        let effectiveModifiers = mouseDownModifierFlags.union(modifierFlags)
        reset()
        return Sample(
            mouseDownPoint: start,
            mouseUpPoint: point,
            clickCount: effectiveClicks,
            modifierFlags: effectiveModifiers
        )
    }
}

package enum SelectionPopupLayout {
    package static func primaryScreenHeight(screens: [NSScreen] = NSScreen.screens) -> CGFloat {
        screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 900
    }

    package static func quartzPoint(fromAppKit point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    package static func appKitRect(fromQuartz quartzRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: quartzRect.origin.x,
            y: primaryScreenHeight - quartzRect.maxY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    package static func panelOrigin(
        panelSize: CGSize,
        selectionRect: CGRect?,
        releasePoint: CGPoint,
        visibleFrame: CGRect
    ) -> CGPoint {
        let anchorMidX = selectionRect?.midX ?? releasePoint.x
        let minX = visibleFrame.minX + 8
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - 8)
        let x = min(max(anchorMidX - panelSize.width / 2, minX), maxX)

        let preferredY = if let selectionRect {
            selectionRect.maxY + 8
        } else {
            releasePoint.y + 12
        }
        let minY = visibleFrame.minY + 8
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 8)
        let rawY: CGFloat
        if preferredY + panelSize.height > visibleFrame.maxY - 8 {
            rawY = (selectionRect?.minY ?? releasePoint.y) - panelSize.height - 10
        } else {
            rawY = preferredY
        }
        let y = min(max(rawY, minY), maxY)
        return CGPoint(x: round(x), y: round(y))
    }

    package static func preferredVisibleFrame(
        selectionRect: CGRect?,
        releasePoint: CGPoint,
        screens: [(frame: CGRect, visibleFrame: CGRect)],
        mainVisibleFrame: CGRect?
    ) -> CGRect {
        let matched = (selectionRect.flatMap { rect in screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame })
            ?? (releasePoint != .zero ? screens.first(where: { $0.frame.contains(releasePoint) })?.visibleFrame : nil)
            ?? mainVisibleFrame
            ?? screens.first?.visibleFrame
        return matched ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
}

package enum SelectionPopupPhase: Equatable, Sendable {
    case hidden
    case ready(shortcutHint: String?)
    case saving
    case saved(offline: Bool)

    package struct CaptureResolution: Equatable, Sendable {
        package let nextPhase: SelectionPopupPhase
        package let shouldPresentErrorHUD: Bool
    }

    package static func resolveCaptureOutcome(_ outcome: SelectionCaptureOutcome) -> CaptureResolution {
        switch outcome {
        case .saved:
            CaptureResolution(nextPhase: .saved(offline: false), shouldPresentErrorHUD: false)
        case .queuedOffline:
            CaptureResolution(nextPhase: .saved(offline: true), shouldPresentErrorHUD: false)
        case .ignoredBusy:
            CaptureResolution(nextPhase: .saving, shouldPresentErrorHUD: false)
        case .failed(.emptySelection):
            CaptureResolution(nextPhase: .hidden, shouldPresentErrorHUD: false)
        case .failed:
            CaptureResolution(nextPhase: .hidden, shouldPresentErrorHUD: true)
        }
    }
}

@MainActor
enum SelectionPopupAXProbe {
    struct Result: Equatable {
        let selectionRect: CGRect?
    }

    static func probe(
        pid: pid_t,
        host: SelectionPopupHost,
        sample: SelectionGestureEvaluator.Sample,
        primaryScreenHeight: CGFloat
    ) -> Result? {
        guard MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false) else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        let quartzUp = SelectionPopupLayout.quartzPoint(fromAppKit: sample.mouseUpPoint, primaryScreenHeight: primaryScreenHeight)
        let quartzDown = SelectionPopupLayout.quartzPoint(fromAppKit: sample.mouseDownPoint, primaryScreenHeight: primaryScreenHeight)

        let hitUpOutcome = hitTestElement(at: quartzUp, expectedPID: pid, appElement: appElement)
        if case .foreignApplication = hitUpOutcome {
            return nil
        }
        let hitUp: AXUIElement? = if case .element(let el) = hitUpOutcome { el } else { nil }

        switch host {
        case .antigravity:
            return probeAntigravity(
                appElement: appElement,
                hitUp: hitUp,
                primaryScreenHeight: primaryScreenHeight
            )
        case .geminiApp:
            return probeGeminiApp(
                pid: pid,
                appElement: appElement,
                hitUp: hitUp,
                quartzDown: quartzDown,
                sample: sample,
                primaryScreenHeight: primaryScreenHeight
            )
        }
    }

    private enum HitTestOutcome {
        case element(AXUIElement)
        case foreignApplication
        case none
    }

    private static func hitTestElement(
        at quartzPoint: CGPoint,
        expectedPID: pid_t,
        appElement: AXUIElement
    ) -> HitTestOutcome {
        let systemWide = AXUIElementCreateSystemWide()
        var systemHit: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(quartzPoint.x), Float(quartzPoint.y), &systemHit) == .success,
           let systemHit {
            var hitPID: pid_t = 0
            if AXUIElementGetPid(systemHit, &hitPID) == .success {
                return hitPID == expectedPID ? .element(systemHit) : .foreignApplication
            }
        }
        var appHit: AXUIElement?
        if AXUIElementCopyElementAtPosition(appElement, Float(quartzPoint.x), Float(quartzPoint.y), &appHit) == .success,
           let appHit {
            return .element(appHit)
        }
        return .none
    }

    private static func probeAntigravity(
        appElement: AXUIElement,
        hitUp: AXUIElement?,
        primaryScreenHeight: CGFloat
    ) -> Result? {
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let focused = axElement(axValue(appElement, kAXFocusedUIElementAttribute))
        guard !hasDisallowedAntigravityAncestor(focused),
              !hasDisallowedAntigravityAncestor(hitUp) else {
            return nil
        }

        let window = axElement(axValue(appElement, kAXFocusedWindowAttribute))
        let rawHitWebArea = nearestRawWebArea(hitUp)
        if let rawHitWebArea, !isAllowedAntigravityWebArea(rawHitWebArea, in: window) {
            return nil
        }
        let rawFocusedWebArea = nearestRawWebArea(focused)
        if let rawFocusedWebArea, !isAllowedAntigravityWebArea(rawFocusedWebArea, in: window) {
            return nil
        }

        let directWebArea = owningWebArea(hitUp, in: window) ?? owningWebArea(focused, in: window)
        let parentConversationArea = directWebArea.flatMap(enclosingConversationWebArea(of:))
        var resolvedWebArea = directWebArea
        var hasSelection = hasNonEmptySelectedText(hitUp)
            || hasNonEmptySelectedText(focused)
            || hasNonEmptySelectedText(directWebArea)
            || hasNonEmptySelectedText(parentConversationArea)

        if !hasSelection,
           directWebArea == nil,
           let window,
           let uniqueArea = uniqueSelectedWebArea(in: window) {
            resolvedWebArea = uniqueArea
            hasSelection = true
        }
        guard hasSelection else { return nil }

        let rect = resolvedWebArea.flatMap { markerSelectionBounds(on: $0, primaryScreenHeight: primaryScreenHeight) }
            ?? parentConversationArea.flatMap { markerSelectionBounds(on: $0, primaryScreenHeight: primaryScreenHeight) }
        return Result(selectionRect: rect)
    }

    private static func probeGeminiApp(
        pid: pid_t,
        appElement: AXUIElement,
        hitUp: AXUIElement?,
        quartzDown: CGPoint,
        sample: SelectionGestureEvaluator.Sample,
        primaryScreenHeight: CGFloat
    ) -> Result? {
        let focused = axElement(axValue(appElement, kAXFocusedUIElementAttribute))
        guard !hasDisallowedGeminiAncestor(focused),
              !hasDisallowedGeminiAncestor(hitUp) else {
            return nil
        }

        let editState = editMenuCommandStates(in: appElement)
        if editState.cutEnabled {
            return nil
        }

        let directSelection = hasNonEmptySelectedTextOrRange(focused) || hasNonEmptySelectedTextOrRange(hitUp)
        let menuCopyConfirmed = editState.copyEnabled
        let gestureConfirmed: Bool = {
            guard sample.dragDistance >= 8.0 || sample.clickCount >= 2 else { return false }
            guard isGeminiMessageContentElement(hitUp) else { return false }
            if sample.dragDistance >= 8.0 {
                guard case .element(let hitDown) = hitTestElement(at: quartzDown, expectedPID: pid, appElement: appElement),
                      isGeminiMessageContentElement(hitDown) else {
                    return false
                }
            }
            return true
        }()

        guard directSelection || menuCopyConfirmed || gestureConfirmed else {
            return nil
        }

        let rect = rangeSelectionBounds(on: hitUp, primaryScreenHeight: primaryScreenHeight)
            ?? rangeSelectionBounds(on: focused, primaryScreenHeight: primaryScreenHeight)
        return Result(selectionRect: rect)
    }

    private static func hasDisallowedAntigravityAncestor(_ element: AXUIElement?) -> Bool {
        var current = element
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
                return true
            }
            if MacOSAccessibilitySelectionCapturer.hasEditableAncestorValue(node) {
                return true
            }
            if role == "AXWebArea" {
                return false
            }
            current = axElement(axValue(node, kAXParentAttribute))
        }
        return false
    }

    private static func hasDisallowedGeminiAncestor(_ element: AXUIElement?) -> Bool {
        let rejectedRoles: Set<String> = [
            kAXTextAreaRole,
            kAXTextFieldRole,
            kAXOutlineRole,
            kAXToolbarRole,
            kAXScrollBarRole,
            kAXSplitterRole
        ]
        var current = element
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            if let role = string(node, kAXRoleAttribute), rejectedRoles.contains(role) {
                return true
            }
            if MacOSAccessibilitySelectionCapturer.hasEditableAncestorValue(node) {
                return true
            }
            current = axElement(axValue(node, kAXParentAttribute))
        }
        return false
    }

    private static func nearestRawWebArea(_ element: AXUIElement?) -> AXUIElement? {
        var current = element
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                return node
            }
            current = axElement(axValue(node, kAXParentAttribute))
        }
        return nil
    }

    private static func webAreaURL(of area: AXUIElement) -> URL? {
        let rawURL = axValue(area, kAXURLAttribute)
        return (rawURL as? URL) ?? (rawURL as? String).flatMap { URL(string: $0) }
    }

    private static func enclosingConversationWebArea(of area: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = area
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            if string(node, kAXRoleAttribute) == "AXWebArea",
               AntigravityWebAreaClassification.classify(url: webAreaURL(of: node)) == .conversation {
                return node
            }
            current = axElement(axValue(node, kAXParentAttribute))
        }
        return nil
    }

    private static func containsActiveConversationWebArea(in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 24 else { return false }
        let role = string(element, kAXRoleAttribute) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return false
        }
        if role == "AXWebArea",
           !MacOSAccessibilitySelectionCapturer.hasEditableAncestorValue(element),
           AntigravityWebAreaClassification.classify(url: webAreaURL(of: element)) == .conversation {
            return true
        }
        for child in children(element) {
            if containsActiveConversationWebArea(in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func isAllowedAntigravityWebArea(_ webArea: AXUIElement, in window: AXUIElement?) -> Bool {
        switch AntigravityWebAreaClassification.classify(url: webAreaURL(of: webArea)) {
        case .conversation:
            return true
        case .disallowed:
            return false
        case .childFrame:
            var parent = axElement(axValue(webArea, kAXParentAttribute))
            var depth = 0
            while let node = parent, depth < 48 {
                depth += 1
                if string(node, kAXRoleAttribute) == "AXWebArea" {
                    switch AntigravityWebAreaClassification.classify(url: webAreaURL(of: node)) {
                    case .conversation:
                        return true
                    case .disallowed:
                        return false
                    case .childFrame:
                        break
                    }
                }
                parent = axElement(axValue(node, kAXParentAttribute))
            }
            guard let window else { return false }
            return containsActiveConversationWebArea(in: window, depth: 0)
        }
    }

    private static func owningWebArea(_ element: AXUIElement?, in window: AXUIElement?) -> AXUIElement? {
        guard let rawArea = nearestRawWebArea(element),
              isAllowedAntigravityWebArea(rawArea, in: window) else {
            return nil
        }
        return rawArea
    }

    private static func uniqueSelectedWebArea(in window: AXUIElement) -> AXUIElement? {
        var matches: [AXUIElement] = []
        collectSelectedWebAreas(in: window, rootWindow: window, depth: 0, into: &matches)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func collectSelectedWebAreas(
        in element: AXUIElement,
        rootWindow: AXUIElement,
        depth: Int,
        into matches: inout [AXUIElement]
    ) {
        guard depth < 24, matches.count <= 1 else { return }
        let role = string(element, kAXRoleAttribute) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return
        }
        if role == "AXWebArea",
           !MacOSAccessibilitySelectionCapturer.hasEditableAncestorValue(element),
           isAllowedAntigravityWebArea(element, in: rootWindow),
           hasNonEmptySelectedText(element),
           !matches.contains(where: { CFEqual($0, element) }) {
            matches.append(element)
            if matches.count > 1 { return }
        }
        for child in children(element) {
            collectSelectedWebAreas(in: child, rootWindow: rootWindow, depth: depth + 1, into: &matches)
            if matches.count > 1 { return }
        }
    }

    private static func hasNonEmptySelectedText(_ element: AXUIElement?) -> Bool {
        guard let element,
              let text = string(element, kAXSelectedTextAttribute) else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasNonEmptySelectedTextOrRange(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        if hasNonEmptySelectedText(element) {
            return true
        }
        if let rawRange = axValue(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rawRange) == AXValueGetTypeID() {
            let axRange = unsafeDowncast(rawRange as AnyObject, to: AXValue.self)
            var cfRange = CFRange()
            if AXValueGetType(axRange) == .cfRange,
               AXValueGetValue(axRange, .cfRange, &cfRange),
               cfRange.location != kCFNotFound,
               cfRange.length > 0 {
                return true
            }
        }
        return false
    }

    private static func editMenuCommandStates(in appElement: AXUIElement) -> (cutEnabled: Bool, copyEnabled: Bool) {
        guard let menuBar = axElement(axValue(appElement, kAXMenuBarAttribute)) else {
            return (false, false)
        }
        let barItems = children(menuBar)
        let editItems = barItems.filter { item in
            let title = string(item, kAXTitleAttribute) ?? ""
            return title == "Edit" || title == "编辑"
        }
        let candidateBarItems = editItems.isEmpty ? barItems : editItems

        var cutEnabled = false
        var copyEnabled = false
        for barItem in candidateBarItems {
            for menu in children(barItem) {
                for menuItem in children(menu) {
                    guard let cmd = string(menuItem, kAXMenuItemCmdCharAttribute)?.uppercased() else { continue }
                    let mods = (axValue(menuItem, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
                    guard mods == 0 else { continue }
                    let enabled = (axValue(menuItem, kAXEnabledAttribute) as? Bool) ?? false
                    if cmd == "X" && enabled { cutEnabled = true }
                    if cmd == "C" && enabled { copyEnabled = true }
                }
            }
        }
        return (cutEnabled, copyEnabled)
    }

    private static func isGeminiMessageContentElement(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        let rejectedIdentifiers: Set<String> = [
            "copy-button",
            "thumb-up-unselected",
            "thumb-down-unselected"
        ]
        let rejectedLabels: Set<String> = ["更多操作", "重新生成"]

        var matchedMessageContent = false
        var insideConversationRow = false
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 40 {
            depth += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            let identifier = string(node, kAXIdentifierAttribute) ?? ""
            let title = string(node, kAXTitleAttribute) ?? ""
            let desc = string(node, kAXDescriptionAttribute) ?? ""

            if rejectedIdentifiers.contains(identifier)
                || rejectedLabels.contains(title)
                || rejectedLabels.contains(desc) {
                return false
            }
            if [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole].contains(role),
               !isGeminiCodeAttachment(node) {
                return false
            }
            if role == kAXStaticTextRole,
               let text = string(node, kAXValueAttribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchedMessageContent = true
            } else if role == "AXHeading",
                      !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchedMessageContent = true
            } else if isGeminiCodeAttachment(node) {
                matchedMessageContent = true
            }

            if role == kAXRowRole,
               let parent = axElement(axValue(node, kAXParentAttribute)),
               children(parent).contains(where: {
                   string($0, kAXRoleAttribute) == kAXColumnRole && string($0, kAXIdentifierAttribute) == "content"
               }) {
                insideConversationRow = true
                break
            }
            current = axElement(axValue(node, kAXParentAttribute))
        }
        return matchedMessageContent && insideConversationRow
    }

    private static func isGeminiCodeAttachment(_ node: AXUIElement) -> Bool {
        string(node, kAXRoleAttribute) == kAXButtonRole && NativeChatCodeBlock.geminiAttachment(
            identifier: string(node, kAXIdentifierAttribute),
            description: string(node, kAXDescriptionAttribute),
            renderedText: string(node, kAXValueAttribute)
        ) != nil
    }

    private static func markerSelectionBounds(
        on webArea: AXUIElement,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard let markerRange = axValue(webArea, "AXSelectedTextMarkerRange"),
              let boundsRef = parameterizedValue(webArea, "AXBoundsForTextMarkerRange", markerRange) else {
            return nil
        }
        return unpackAppKitRect(from: boundsRef, primaryScreenHeight: primaryScreenHeight)
    }

    private static func rangeSelectionBounds(
        on element: AXUIElement?,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard let element,
              let rangeValue = axValue(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let axRange = unsafeDowncast(rangeValue as AnyObject, to: AXValue.self)
        var cfRange = CFRange()
        guard AXValueGetType(axRange) == .cfRange,
              AXValueGetValue(axRange, .cfRange, &cfRange),
              cfRange.location != kCFNotFound,
              cfRange.length > 0,
              let boundsRef = parameterizedValue(element, kAXBoundsForRangeParameterizedAttribute, rangeValue) else {
            return nil
        }
        return unpackAppKitRect(from: boundsRef, primaryScreenHeight: primaryScreenHeight)
    }

    private static func unpackAppKitRect(from ref: CFTypeRef, primaryScreenHeight: CGFloat) -> CGRect? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeDowncast(ref as AnyObject, to: AXValue.self)
        var quartzRect = CGRect.zero
        guard AXValueGetType(axVal) == .cgRect,
              AXValueGetValue(axVal, .cgRect, &quartzRect),
              quartzRect.width > 0,
              quartzRect.height > 0,
              quartzRect.origin.x.isFinite,
              quartzRect.origin.y.isFinite else {
            return nil
        }
        return SelectionPopupLayout.appKitRect(fromQuartz: quartzRect, primaryScreenHeight: primaryScreenHeight)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        axValue(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        axValue(node, attribute) as? String
    }

    private static func axValue(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func parameterizedValue(
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

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
public final class SelectionPopupPanel: NSPanel {
    private let hostingView: FirstMouseHostingView<SelectionPopupView>

    init(onStash: @escaping @MainActor () -> Void) {
        let initialView = SelectionPopupView(phase: .hidden, onStash: onStash)
        let hosting = FirstMouseHostingView(rootView: initialView)
        self.hostingView = hosting

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 108, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        contentView = hosting
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    func render(
        phase: SelectionPopupPhase,
        selectionRect: CGRect?,
        releasePoint: CGPoint,
        onStash: @escaping @MainActor () -> Void
    ) {
        guard phase != .hidden else {
            orderOut(nil)
            return
        }
        hostingView.rootView = SelectionPopupView(phase: phase, onStash: onStash)
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = CGSize(width: max(76, ceil(fitting.width)), height: 34)
        let visible = SelectionPopupLayout.preferredVisibleFrame(
            selectionRect: selectionRect,
            releasePoint: releasePoint,
            screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) },
            mainVisibleFrame: NSScreen.main?.visibleFrame
        )
        let origin = SelectionPopupLayout.panelOrigin(
            panelSize: size,
            selectionRect: selectionRect,
            releasePoint: releasePoint,
            visibleFrame: visible
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }
}

@MainActor
struct SelectionPopupView: View {
    let phase: SelectionPopupPhase
    let onStash: @MainActor () -> Void

    private var isInteractive: Bool {
        if case .ready = phase { return true }
        return false
    }

    private var labelText: String {
        switch phase {
        case .hidden: ""
        case .ready: "暂存"
        case .saving: "暂存中…"
        case .saved(let offline): offline ? "待同步" : "已暂存"
        }
    }

    var body: some View {
        Button(action: onStash) {
            HStack(spacing: 6) {
                leadingAccessory
                Text(labelText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if case .ready(let hint) = phase, let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isInteractive)
        .environment(\.controlActiveState, .key)
        .accessibilityIdentifier("selectionPopup.stash")
        .accessibilityLabel(labelText)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .ready:
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        case .saving:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .frame(width: 13, height: 13)
        case .saved(let offline):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(offline ? Color.orange : Color.green)
        }
    }
}

@MainActor
public final class SelectionPopupController {
    private let appearance: AppAppearancePreferences
    private let shortcuts: AppShortcuts
    private let onTriggerCapture: @MainActor () async -> SelectionCaptureOutcome
    private let onPresentErrorHUD: @MainActor () -> Void

    private lazy var panel = SelectionPopupPanel { [weak self] in
        self?.handleCapsuleClick()
    }
    private var gestureEvaluator = SelectionGestureEvaluator()
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var probeTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var anchorSelectionRect: CGRect?
    private var anchorReleasePoint: CGPoint = .zero
    private var anchorPID: pid_t?
    private var isRunning = false
    private var observationGeneration: UInt64 = 0
    package private(set) var phase: SelectionPopupPhase = .hidden

    public var isVisible: Bool {
        phase != .hidden && panel.isVisible
    }

    public init(
        appearance: AppAppearancePreferences,
        shortcuts: AppShortcuts,
        onTriggerCapture: @escaping @MainActor () async -> SelectionCaptureOutcome,
        onPresentErrorHUD: @escaping @MainActor () -> Void
    ) {
        self.appearance = appearance
        self.shortcuts = shortcuts
        self.onTriggerCapture = onTriggerCapture
        self.onPresentErrorHUD = onPresentErrorHUD
    }

    public func start() {
        stop()
        isRunning = true
        observationGeneration &+= 1
        observeAppearancePreference()

        let pointerDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: pointerDownMask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseDown(event)
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelPendingProbe()
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalLeftMouseUp(event)
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .saving else { return }
                self.hideImmediately()
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalKeyDown(event)
            }
        }) {
            eventMonitors.append(monitor)
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.handleApplicationActivation(activatedPID: activatedPID)
            }
        }
    }

    public func stop() {
        isRunning = false
        observationGeneration &+= 1
        cancelPendingProbe()
        holdTask?.cancel()
        holdTask = nil
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        gestureEvaluator.reset()
        phase = .hidden
        anchorSelectionRect = nil
        anchorReleasePoint = .zero
        anchorPID = nil
        panel.orderOut(nil)
    }

    public func hideImmediately() {
        cancelPendingProbe()
        holdTask?.cancel()
        holdTask = nil
        phase = .hidden
        anchorSelectionRect = nil
        anchorReleasePoint = .zero
        anchorPID = nil
        panel.orderOut(nil)
    }

    public func beginSavingInPlace() {
        guard isVisible else { return }
        cancelPendingProbe()
        holdTask?.cancel()
        holdTask = nil
        setPhase(.saving)
    }

    public func applyInPlaceCaptureOutcome(_ outcome: SelectionCaptureOutcome) {
        if outcome == .ignoredBusy {
            return
        }
        let resolution = SelectionPopupPhase.resolveCaptureOutcome(outcome)
        switch resolution.nextPhase {
        case .saved(let offline):
            setPhase(.saved(offline: offline))
            scheduleHideAfterSavedHold()
        case .saving:
            return
        case .hidden, .ready:
            hideImmediately()
            if resolution.shouldPresentErrorHUD {
                onPresentErrorHUD()
            }
        }
    }

    package func handleApplicationActivation(activatedPID: pid_t?) {
        guard phase != .saving else { return }
        if case .saved = phase, let anchorPID, activatedPID == anchorPID {
            return
        }
        gestureEvaluator.reset()
        hideImmediately()
    }

    package func showForTesting(
        anchorPID: pid_t,
        selectionRect: CGRect? = CGRect(x: 200, y: 200, width: 120, height: 22),
        releasePoint: CGPoint = CGPoint(x: 260, y: 210),
        shortcutHint: String? = nil
    ) {
        self.anchorPID = anchorPID
        self.anchorSelectionRect = selectionRect
        self.anchorReleasePoint = releasePoint
        setPhase(.ready(shortcutHint: shortcutHint))
    }

    private func handleCapsuleClick() {
        guard case .ready = phase else { return }
        beginSavingInPlace()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.onTriggerCapture()
            self.applyInPlaceCaptureOutcome(outcome)
        }
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        if panel.isVisible && panel.frame.contains(location) {
            return
        }
        if phase != .saving {
            hideImmediately()
        } else {
            cancelPendingProbe()
        }
        guard event.type == .leftMouseDown else {
            gestureEvaluator.reset()
            return
        }
        guard appearance.showsSelectionPopup else {
            gestureEvaluator.reset()
            return
        }
        gestureEvaluator.recordMouseDown(
            at: location,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags
        )
    }

    private func handleGlobalLeftMouseUp(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let sample = gestureEvaluator.evaluateMouseUp(
            at: location,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags
        )
        guard appearance.showsSelectionPopup else {
            hideImmediately()
            return
        }
        if NSApplication.shared.windows.contains(where: { $0.isVisible && $0.frame.contains(location) }) {
            return
        }
        guard sample.qualifies else {
            if phase != .saving {
                hideImmediately()
            }
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              let host = SelectionPopupHost(bundleIdentifier: frontmost.bundleIdentifier) else {
            if phase != .saving {
                hideImmediately()
            }
            return
        }

        let targetPID = frontmost.processIdentifier
        cancelPendingProbe()
        probeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(45))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.appearance.showsSelectionPopup else { return }
            guard let active = NSWorkspace.shared.frontmostApplication,
                  active.processIdentifier == targetPID,
                  SelectionPopupHost(bundleIdentifier: active.bundleIdentifier) == host else {
                return
            }
            let primaryHeight = SelectionPopupLayout.primaryScreenHeight()
            guard let result = SelectionPopupAXProbe.probe(
                pid: targetPID,
                host: host,
                sample: sample,
                primaryScreenHeight: primaryHeight
            ) else {
                if self.phase != .saving {
                    self.hideImmediately()
                }
                return
            }
            self.anchorPID = targetPID
            self.anchorSelectionRect = result.selectionRect
            self.anchorReleasePoint = sample.mouseUpPoint
            let hint: String? = if self.shortcuts.state(for: .captureSelection) == .active {
                self.shortcuts.shortcut(for: .captureSelection).map(String.init(describing:))
            } else {
                nil
            }
            self.setPhase(.ready(shortcutHint: hint))
        }
    }

    private func handleGlobalKeyDown(_ event: NSEvent) {
        guard phase != .saving else { return }
        if shortcuts.state(for: .captureSelection) == .active,
           let captureShortcut = shortcuts.shortcut(for: .captureSelection),
           KeyboardShortcuts.Shortcut(event: event) == captureShortcut {
            return
        }
        hideImmediately()
    }

    private func setPhase(_ nextPhase: SelectionPopupPhase) {
        holdTask?.cancel()
        holdTask = nil
        phase = nextPhase
        panel.render(
            phase: nextPhase,
            selectionRect: anchorSelectionRect,
            releasePoint: anchorReleasePoint
        ) { [weak self] in
            self?.handleCapsuleClick()
        }
    }

    private func scheduleHideAfterSavedHold() {
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.hideImmediately()
        }
    }

    private func cancelPendingProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    private func observeAppearancePreference(generation: UInt64? = nil) {
        guard isRunning else { return }
        let trackedGeneration = generation ?? observationGeneration
        guard trackedGeneration == observationGeneration else { return }
        withObservationTracking {
            _ = appearance.showsSelectionPopup
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, trackedGeneration == self.observationGeneration else { return }
                if !self.appearance.showsSelectionPopup {
                    self.hideImmediately()
                }
                self.observeAppearancePreference(generation: trackedGeneration)
            }
        }
    }
}

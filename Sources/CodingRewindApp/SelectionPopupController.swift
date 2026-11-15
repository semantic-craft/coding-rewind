// SPDX-License-Identifier: MIT
// Two-phase non-intrusive selection probe and floating capsule adapted from GaimsDevSoftware/linuxpop (MIT) and p0deje/Maccy (MIT).

import AppKit
import ApplicationServices
import CodingRewindCore
import KeyboardShortcuts
import Observation
import SwiftUI

package enum SelectionPopupHost: Equatable, Sendable {
    case antigravity
    case chatGPTApp
    case geminiApp

    package init?(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case AppBundleID.antigravity: self = .antigravity
        case AppBundleID.codex: self = .chatGPTApp
        case AppBundleID.gemini: self = .geminiApp
        default: return nil
        }
    }

    package var preferredVerticalPlacement: SelectionPopupLayout.VerticalPlacement {
        switch self {
        case .antigravity, .geminiApp: .above
        case .chatGPTApp: .below
        }
    }
}

package enum ChatGPTWebAreaClassification: Equatable, Sendable {
    case shell
    case disallowed

    package static func classify(rawURLString: String?) -> Self {
        guard let rawURLString else { return .disallowed }
        if rawURLString == "app://-/index.html"
            || rawURLString.hasPrefix("app://-/index.html#")
            || rawURLString.hasPrefix("app://-/index.html?") {
            return .shell
        }
        return .disallowed
    }

    package static func classify(webArea: AXUIElement) -> Self {
        classify(rawURLString: AXSupport.urlString(webArea))
    }

    package static func findShellWebArea(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 24 else { return nil }
        let role = AXSupport.role(root) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return nil
        }
        if role == "AXWebArea", classify(webArea: root) == .shell {
            return root
        }
        for child in AXSupport.children(root) {
            if let found = findShellWebArea(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

package enum ChatGPTSurfaceClassification {
    package static func isSelectableContainer(
        role: String?,
        subrole: String?,
        title: String?,
        domClasses: [String]
    ) -> Bool {
        if subrole == "AXLandmarkRegion" && title == "Conversation" {
            return true
        }
        return domClasses.contains { $0.hasPrefix("MarkdownRoot-") || $0.hasPrefix("CodeSurface-") }
    }

    package static func isDisallowedNode(
        role: String?,
        subrole: String?,
        title: String?,
        domClasses: [String],
        hasEditableAncestor: Bool,
        isAllowedCodeEditor: Bool
    ) -> Bool {
        if isAllowedCodeEditor {
            return false
        }
        if let role, [kAXTextFieldRole, kAXComboBoxRole, kAXOutlineRole, kAXTextAreaRole].contains(role) {
            return true
        }
        if hasEditableAncestor {
            return true
        }
        if let subrole, ["AXLandmarkNavigation", "AXLandmarkComplementary", "AXLandmarkBanner"].contains(subrole) {
            return true
        }
        return false
    }
}

package enum SelectionPopupStyleMetrics {
    package static let pillHeight: CGFloat = 26
    package static let shadowOutset: CGFloat = 8
    package static let minPillWidth: CGFloat = 64
    package static let horizontalPadding: CGFloat = 10
    package static let itemSpacing: CGFloat = 5
}

package struct SelectionGestureEvaluator: Equatable, Sendable {
    package static let minimumDragDistance: CGFloat = 6.0
    private static let keyboardNavigationKeyCodes: Set<UInt16> = [115, 119, 123, 124, 125, 126]

    package static func isKeyboardSelectionNavigationKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        modifierFlags.contains(.shift)
            && !modifierFlags.contains(.control)
            && keyboardNavigationKeyCodes.contains(keyCode)
    }

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
    package enum VerticalPlacement: Equatable, Sendable {
        case above
        case below
    }

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
        visibleFrame: CGRect,
        verticalPlacement: VerticalPlacement = .above
    ) -> CGPoint {
        let anchorMidX = selectionRect?.midX ?? releasePoint.x
        let minX = visibleFrame.minX + 8
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - 8)
        let x = min(max(anchorMidX - panelSize.width / 2, minX), maxX)

        let minY = visibleFrame.minY + 8
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 8)
        let rawY: CGFloat
        switch verticalPlacement {
        case .above:
            let preferredY = selectionRect.map { $0.maxY + 8 } ?? (releasePoint.y + 12)
            if preferredY + panelSize.height > visibleFrame.maxY - 8 {
                rawY = (selectionRect?.minY ?? releasePoint.y) - panelSize.height - 10
            } else {
                rawY = preferredY
            }
        case .below:
            let preferredY = selectionRect.map { $0.minY - panelSize.height - 8 } ?? (releasePoint.y - panelSize.height - 12)
            if preferredY < visibleFrame.minY + 8 {
                rawY = (selectionRect?.maxY ?? releasePoint.y) + 10
            } else {
                rawY = preferredY
            }
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

package enum SelectionPopupPhase: Equatable, Sendable {
    case hidden
    case ready(shortcutHint: String?)
    case saving
    case saved(offline: Bool)

    package func labelText(in language: AppLanguage) -> String {
        AppStrings.selectionPopupLabel(self, in: language)
    }

    package var labelText: String {
        labelText(in: .zhHans)
    }

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

    enum Outcome: Equatable {
        case matched(Result)
        case warmingUp
        case none
    }

    static func warmUpAccessibilityIfNeeded(pid: pid_t, host: SelectionPopupHost) {
        guard host == .chatGPTApp, AXSupport.isTrusted(prompt: false) else {
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXSupport.value(appElement, "AXEnhancedUserInterface")
        _ = AXSupport.focusedWindow(appElement)
    }

    static func probe(
        pid: pid_t,
        host: SelectionPopupHost,
        sample: SelectionGestureEvaluator.Sample,
        primaryScreenHeight: CGFloat
    ) -> Outcome {
        guard AXSupport.isTrusted(prompt: false) else {
            return .none
        }
        let appElement = AXUIElementCreateApplication(pid)
        let isPointerSample = sample.mouseUpPoint != .zero || sample.mouseDownPoint != .zero
        let quartzUp = SelectionPopupLayout.quartzPoint(fromAppKit: sample.mouseUpPoint, primaryScreenHeight: primaryScreenHeight)
        let quartzDown = SelectionPopupLayout.quartzPoint(fromAppKit: sample.mouseDownPoint, primaryScreenHeight: primaryScreenHeight)

        let hitUp: AXUIElement?
        if isPointerSample {
            let hitUpOutcome = hitTestElement(at: quartzUp, expectedPID: pid, appElement: appElement)
            if case .foreignApplication = hitUpOutcome {
                return .none
            }
            hitUp = if case .element(let el) = hitUpOutcome { el } else { nil }
        } else {
            hitUp = nil
        }

        switch host {
        case .antigravity:
            if let result = probeAntigravity(
                appElement: appElement,
                hitUp: hitUp,
                primaryScreenHeight: primaryScreenHeight
            ) {
                return .matched(result)
            }
            return .none
        case .chatGPTApp:
            return probeChatGPTApp(
                pid: pid,
                appElement: appElement,
                hitUp: hitUp,
                quartzDown: quartzDown,
                isPointerSample: isPointerSample,
                primaryScreenHeight: primaryScreenHeight
            )
        case .geminiApp:
            if let result = probeGeminiApp(
                pid: pid,
                appElement: appElement,
                hitUp: hitUp,
                quartzDown: quartzDown,
                sample: sample,
                primaryScreenHeight: primaryScreenHeight
            ) {
                return .matched(result)
            }
            return .none
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
        let focused = AXSupport.focusedElement(appElement)
        guard !hasDisallowedAntigravityAncestor(focused),
              !hasDisallowedAntigravityAncestor(hitUp) else {
            return nil
        }

        let window = AXSupport.focusedWindow(appElement)
        let rawHitWebArea = AXSupport.nearestWebArea(hitUp)
        if let rawHitWebArea, !isAllowedAntigravityWebArea(rawHitWebArea, in: window) {
            return nil
        }
        let rawFocusedWebArea = AXSupport.nearestWebArea(focused)
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
        let focused = AXSupport.focusedElement(appElement)
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

    private static func probeChatGPTApp(
        pid: pid_t,
        appElement: AXUIElement,
        hitUp: AXUIElement?,
        quartzDown: CGPoint,
        isPointerSample: Bool,
        primaryScreenHeight: CGFloat
    ) -> Outcome {
        _ = AXSupport.value(appElement, "AXEnhancedUserInterface")
        let window = AXSupport.focusedWindow(appElement)
        let focused = AXSupport.focusedElement(appElement)

        if let hitWebArea = AXSupport.nearestWebArea(hitUp, maxDepth: 64),
           ChatGPTWebAreaClassification.classify(webArea: hitWebArea) == .disallowed {
            return .none
        }
        if let focusedWebArea = AXSupport.nearestWebArea(focused, maxDepth: 64),
           ChatGPTWebAreaClassification.classify(webArea: focusedWebArea) == .disallowed {
            return .none
        }

        let shellWebArea = owningChatGPTShellWebArea(hitUp)
            ?? owningChatGPTShellWebArea(focused)
            ?? window.flatMap { ChatGPTWebAreaClassification.findShellWebArea(in: $0) }
        guard let shellWebArea else {
            if let window, !containsAnyWebArea(in: window) {
                return .warmingUp
            }
            return .none
        }

        let focusedInspection = inspectChatGPTAncestry(focused, shellWebArea: shellWebArea)
        let hitUpInspection = inspectChatGPTAncestry(hitUp, shellWebArea: shellWebArea)
        guard !focusedInspection.hasDisallowedAncestor,
              !hitUpInspection.hasDisallowedAncestor else {
            return .none
        }

        var hitDownInspection = ChatGPTAncestryInspection(
            hasDisallowedAncestor: false,
            hasSelectableContainer: false,
            allowedCodeEditor: nil
        )
        if !hitUpInspection.hasSelectableContainer, isPointerSample {
            if case .element(let downEl) = hitTestElement(at: quartzDown, expectedPID: pid, appElement: appElement) {
                if let downWebArea = AXSupport.nearestWebArea(downEl, maxDepth: 64),
                   ChatGPTWebAreaClassification.classify(webArea: downWebArea) == .disallowed {
                    return .none
                }
                hitDownInspection = inspectChatGPTAncestry(downEl, shellWebArea: shellWebArea)
            }
        }

        let markerRect = markerSelectionBounds(on: shellWebArea, primaryScreenHeight: primaryScreenHeight)

        var keyboardHitInspection = ChatGPTAncestryInspection(
            hasDisallowedAncestor: false,
            hasSelectableContainer: false,
            allowedCodeEditor: nil
        )
        if !isPointerSample,
           !focusedInspection.hasSelectableContainer,
           let markerRect {
            let midQuartz = SelectionPopupLayout.quartzPoint(
                fromAppKit: CGPoint(x: markerRect.midX, y: markerRect.midY),
                primaryScreenHeight: primaryScreenHeight
            )
            if case .element(let midEl) = hitTestElement(at: midQuartz, expectedPID: pid, appElement: appElement) {
                if let midWebArea = AXSupport.nearestWebArea(midEl, maxDepth: 64),
                   ChatGPTWebAreaClassification.classify(webArea: midWebArea) == .disallowed {
                    return .none
                }
                keyboardHitInspection = inspectChatGPTAncestry(midEl, shellWebArea: shellWebArea)
                if keyboardHitInspection.hasDisallowedAncestor {
                    return .none
                }
            }
        }

        let selectableMatched = hitUpInspection.hasSelectableContainer
            || focusedInspection.hasSelectableContainer
            || (!hitDownInspection.hasDisallowedAncestor && hitDownInspection.hasSelectableContainer)
            || (!keyboardHitInspection.hasDisallowedAncestor && keyboardHitInspection.hasSelectableContainer)
        guard selectableMatched else {
            return .none
        }

        let codeEditor = hitUpInspection.allowedCodeEditor
            ?? focusedInspection.allowedCodeEditor
            ?? (hitDownInspection.hasDisallowedAncestor ? nil : hitDownInspection.allowedCodeEditor)
            ?? keyboardHitInspection.allowedCodeEditor

        let hasSelection = hasNonEmptySelectedText(hitUp)
            || hasNonEmptySelectedText(focused)
            || hasNonEmptySelectedText(shellWebArea)
            || hasNonEmptySelectedTextOrRange(codeEditor)
        guard hasSelection else {
            return .none
        }

        let rect = markerRect
            ?? rangeSelectionBounds(on: hitUp, primaryScreenHeight: primaryScreenHeight)
            ?? rangeSelectionBounds(on: focused, primaryScreenHeight: primaryScreenHeight)
            ?? rangeSelectionBounds(on: codeEditor, primaryScreenHeight: primaryScreenHeight)
        return .matched(Result(selectionRect: rect))
    }

    private struct ChatGPTAncestryInspection {
        let hasDisallowedAncestor: Bool
        let hasSelectableContainer: Bool
        let allowedCodeEditor: AXUIElement?
    }

    private static func owningChatGPTShellWebArea(_ element: AXUIElement?) -> AXUIElement? {
        guard let webArea = AXSupport.nearestWebArea(element, maxDepth: 64),
              ChatGPTWebAreaClassification.classify(webArea: webArea) == .shell else {
            return nil
        }
        return webArea
    }

    private static func containsAnyWebArea(in root: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 24 else { return false }
        let role = AXSupport.role(root) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return false
        }
        if role == "AXWebArea" {
            return true
        }
        for child in AXSupport.children(root) {
            if containsAnyWebArea(in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func inspectChatGPTAncestry(
        _ element: AXUIElement?,
        shellWebArea: AXUIElement
    ) -> ChatGPTAncestryInspection {
        guard let element, !CFEqual(element, shellWebArea) else {
            return ChatGPTAncestryInspection(
                hasDisallowedAncestor: false,
                hasSelectableContainer: false,
                allowedCodeEditor: nil
            )
        }

        struct NodeSnapshot {
            let element: AXUIElement
            let role: String?
            let subrole: String?
            let title: String?
            let domClasses: [String]
            let hasEditableAncestor: Bool
            let isSelectable: Bool
            let isCodeEditorCandidate: Bool
        }

        var chain: [NodeSnapshot] = []
        var reachedShell = false
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 64 {
            depth += 1
            if CFEqual(node, shellWebArea) {
                reachedShell = true
                break
            }
            let role = AXSupport.role(node)
            let subrole = AXSupport.subrole(node)
            let title = AXSupport.title(node)
            let domClasses = AXSupport.value(node, "AXDOMClassList") as? [String] ?? []
            let hasEditableAncestor = AXSupport.hasEditableAncestorValue(node)
            let isSelectable = ChatGPTSurfaceClassification.isSelectableContainer(
                role: role,
                subrole: subrole,
                title: title,
                domClasses: domClasses
            )
            let isCodeEditorCandidate = NativeChatCodeBlock.isEditor(
                role: role,
                title: title,
                classes: domClasses
            )
            chain.append(NodeSnapshot(
                element: node,
                role: role,
                subrole: subrole,
                title: title,
                domClasses: domClasses,
                hasEditableAncestor: hasEditableAncestor,
                isSelectable: isSelectable,
                isCodeEditorCandidate: isCodeEditorCandidate
            ))
            if role == "AXWebArea" {
                break
            }
            current = AXSupport.parent(node)
        }

        let editorIndex: Int? = if reachedShell,
                                   let idx = chain.firstIndex(where: \.isCodeEditorCandidate),
                                   chain[idx...].contains(where: \.isSelectable) {
            idx
        } else {
            nil
        }

        for (index, item) in chain.enumerated() {
            let insideAllowedEditor = if let editorIndex { index <= editorIndex } else { false }
            if ChatGPTSurfaceClassification.isDisallowedNode(
                role: item.role,
                subrole: item.subrole,
                title: item.title,
                domClasses: item.domClasses,
                hasEditableAncestor: item.hasEditableAncestor,
                isAllowedCodeEditor: insideAllowedEditor
            ) {
                return ChatGPTAncestryInspection(
                    hasDisallowedAncestor: true,
                    hasSelectableContainer: false,
                    allowedCodeEditor: nil
                )
            }
        }

        return ChatGPTAncestryInspection(
            hasDisallowedAncestor: false,
            hasSelectableContainer: reachedShell && chain.contains(where: \.isSelectable),
            allowedCodeEditor: editorIndex.map { chain[$0].element }
        )
    }

    private static func hasDisallowedAntigravityAncestor(_ element: AXUIElement?) -> Bool {
        var current = element
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            let role = AXSupport.role(node) ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
                return true
            }
            if AXSupport.hasEditableAncestorValue(node) {
                return true
            }
            if role == "AXWebArea" {
                return false
            }
            current = AXSupport.parent(node)
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
            if let role = AXSupport.role(node), rejectedRoles.contains(role) {
                return true
            }
            if AXSupport.hasEditableAncestorValue(node) {
                return true
            }
            current = AXSupport.parent(node)
        }
        return false
    }

    private static func enclosingConversationWebArea(of area: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = area
        var depth = 0
        while let node = current, depth < 48 {
            depth += 1
            if AXSupport.role(node) == "AXWebArea",
               AntigravityWebAreaClassification.classify(webArea: node) == .conversation {
                return node
            }
            current = AXSupport.parent(node)
        }
        return nil
    }

    private static func containsActiveConversationWebArea(in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 24 else { return false }
        let role = AXSupport.role(element) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return false
        }
        if role == "AXWebArea",
           !AXSupport.hasEditableAncestorValue(element),
           AntigravityWebAreaClassification.classify(webArea: element) == .conversation {
            return true
        }
        for child in AXSupport.children(element) {
            if containsActiveConversationWebArea(in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func isAllowedAntigravityWebArea(_ webArea: AXUIElement, in window: AXUIElement?) -> Bool {
        switch AntigravityWebAreaClassification.classify(webArea: webArea) {
        case .conversation:
            return true
        case .disallowed:
            return false
        case .childFrame:
            var parent = AXSupport.parent(webArea)
            var depth = 0
            while let node = parent, depth < 48 {
                depth += 1
                if AXSupport.role(node) == "AXWebArea" {
                    switch AntigravityWebAreaClassification.classify(webArea: node) {
                    case .conversation:
                        return true
                    case .disallowed:
                        return false
                    case .childFrame:
                        break
                    }
                }
                parent = AXSupport.parent(node)
            }
            guard let window else { return false }
            return containsActiveConversationWebArea(in: window, depth: 0)
        }
    }

    private static func owningWebArea(_ element: AXUIElement?, in window: AXUIElement?) -> AXUIElement? {
        guard let rawArea = AXSupport.nearestWebArea(element),
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
        let role = AXSupport.role(element) ?? ""
        if [kAXMenuBarRole, kAXStaticTextRole, kAXImageRole, kAXScrollBarRole, kAXToolbarRole].contains(role) {
            return
        }
        if role == "AXWebArea",
           !AXSupport.hasEditableAncestorValue(element),
           isAllowedAntigravityWebArea(element, in: rootWindow),
           hasNonEmptySelectedText(element),
           !matches.contains(where: { CFEqual($0, element) }) {
            matches.append(element)
            if matches.count > 1 { return }
        }
        for child in AXSupport.children(element) {
            collectSelectedWebAreas(in: child, rootWindow: rootWindow, depth: depth + 1, into: &matches)
            if matches.count > 1 { return }
        }
    }

    private static func hasNonEmptySelectedText(_ element: AXUIElement?) -> Bool {
        guard let element,
              let text = AXSupport.string(element, kAXSelectedTextAttribute) else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasNonEmptySelectedTextOrRange(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        if hasNonEmptySelectedText(element) {
            return true
        }
        if let cfRange = AXSupport.cfRange(AXSupport.value(element, kAXSelectedTextRangeAttribute)),
           cfRange.location != kCFNotFound,
           cfRange.length > 0 {
            return true
        }
        return false
    }

    private static func editMenuCommandStates(in appElement: AXUIElement) -> (cutEnabled: Bool, copyEnabled: Bool) {
        guard let menuBar = AXSupport.element(appElement, kAXMenuBarAttribute) else {
            return (false, false)
        }
        let barItems = AXSupport.children(menuBar)
        let editItems = barItems.filter { item in
            let title = AXSupport.title(item) ?? ""
            return title == "Edit" || title == "编辑"
        }
        let candidateBarItems = editItems.isEmpty ? barItems : editItems

        var cutEnabled = false
        var copyEnabled = false
        for barItem in candidateBarItems {
            for menu in AXSupport.children(barItem) {
                for menuItem in AXSupport.children(menu) {
                    guard let cmd = AXSupport.string(menuItem, kAXMenuItemCmdCharAttribute)?.uppercased() else { continue }
                    let mods = AXSupport.int(menuItem, kAXMenuItemCmdModifiersAttribute) ?? 0
                    guard mods == 0 else { continue }
                    let enabled = AXSupport.bool(menuItem, kAXEnabledAttribute) ?? false
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
        let rejectedLabels: Set<String> = [
            "更多操作",
            "重新生成",
            "More actions",
            "More options",
            "Regenerate",
            "Redo"
        ]

        var matchedMessageContent = false
        var insideConversationRow = false
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 40 {
            depth += 1
            let role = AXSupport.role(node) ?? ""
            let identifier = AXSupport.identifier(node) ?? ""
            let title = AXSupport.title(node) ?? ""
            let desc = AXSupport.descriptionText(node) ?? ""

            if rejectedIdentifiers.contains(identifier)
                || rejectedLabels.contains(title)
                || rejectedLabels.contains(desc) {
                return false
            }
            if [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole].contains(role),
               !AXSupport.isGeminiCodeAttachment(node) {
                return false
            }
            if role == kAXStaticTextRole,
               let text = AXSupport.string(node, kAXValueAttribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchedMessageContent = true
            } else if role == "AXHeading",
                      !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchedMessageContent = true
            } else if AXSupport.isGeminiCodeAttachment(node) {
                matchedMessageContent = true
            }

            if role == kAXRowRole,
               let parent = AXSupport.parent(node),
               AXSupport.children(parent).contains(where: {
                   AXSupport.role($0) == kAXColumnRole && AXSupport.identifier($0) == "content"
               }) {
                insideConversationRow = true
                break
            }
            current = AXSupport.parent(node)
        }
        return matchedMessageContent && insideConversationRow
    }

    private static func markerSelectionBounds(
        on webArea: AXUIElement,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard let markerRange = AXSupport.value(webArea, "AXSelectedTextMarkerRange"),
              let boundsRef = AXSupport.parameterizedValue(webArea, "AXBoundsForTextMarkerRange", markerRange) else {
            return nil
        }
        return unpackAppKitRect(from: boundsRef, primaryScreenHeight: primaryScreenHeight)
    }

    private static func rangeSelectionBounds(
        on element: AXUIElement?,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard let element,
              let rangeValue = AXSupport.value(element, kAXSelectedTextRangeAttribute),
              let cfRange = AXSupport.cfRange(rangeValue),
              cfRange.location != kCFNotFound,
              cfRange.length > 0,
              let boundsRef = AXSupport.parameterizedValue(element, kAXBoundsForRangeParameterizedAttribute, rangeValue) else {
            return nil
        }
        return unpackAppKitRect(from: boundsRef, primaryScreenHeight: primaryScreenHeight)
    }

    private static func unpackAppKitRect(from ref: CFTypeRef, primaryScreenHeight: CGFloat) -> CGRect? {
        guard let quartzRect = AXSupport.cgRect(ref),
              quartzRect.width > 0,
              quartzRect.height > 0,
              quartzRect.origin.x.isFinite,
              quartzRect.origin.y.isFinite else {
            return nil
        }
        return SelectionPopupLayout.appKitRect(fromQuartz: quartzRect, primaryScreenHeight: primaryScreenHeight)
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let interactiveBounds = bounds.insetBy(
            dx: SelectionPopupStyleMetrics.shadowOutset,
            dy: SelectionPopupStyleMetrics.shadowOutset
        )
        guard interactiveBounds.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
public final class SelectionPopupPanel: NSPanel {
    private let hostingView: FirstMouseHostingView<SelectionPopupView>
    private let onOutsideShadowClick: (@MainActor () -> Void)?

    package var interactiveFrame: CGRect {
        frame.insetBy(
            dx: SelectionPopupStyleMetrics.shadowOutset,
            dy: SelectionPopupStyleMetrics.shadowOutset
        )
    }

    package func updateMousePassthrough(mouseLocation: CGPoint = NSEvent.mouseLocation, isInteractivePhase: Bool) {
        ignoresMouseEvents = !isInteractivePhase || !interactiveFrame.contains(mouseLocation)
    }

    init(
        onStash: @escaping @MainActor () -> Void,
        onOutsideShadowClick: (@MainActor () -> Void)? = nil
    ) {
        let initialView = SelectionPopupView(phase: .hidden, language: .zhHans, onStash: onStash)
        let hosting = FirstMouseHostingView(rootView: initialView)
        self.hostingView = hosting
        self.onOutsideShadowClick = onOutsideShadowClick

        let outset = SelectionPopupStyleMetrics.shadowOutset
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SelectionPopupStyleMetrics.minPillWidth + outset * 2,
                height: SelectionPopupStyleMetrics.pillHeight + outset * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        contentView = hosting
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let interactiveRect = NSRect(origin: .zero, size: frame.size).insetBy(
                dx: SelectionPopupStyleMetrics.shadowOutset,
                dy: SelectionPopupStyleMetrics.shadowOutset
            )
            if !interactiveRect.contains(event.locationInWindow) {
                onOutsideShadowClick?()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    func render(
        phase: SelectionPopupPhase,
        language: AppLanguage = .zhHans,
        selectionRect: CGRect?,
        releasePoint: CGPoint,
        verticalPlacement: SelectionPopupLayout.VerticalPlacement = .above,
        onStash: @escaping @MainActor () -> Void
    ) {
        guard phase != .hidden else {
            ignoresMouseEvents = true
            orderOut(nil)
            return
        }
        hostingView.rootView = SelectionPopupView(phase: phase, language: language, onStash: onStash)
        hostingView.layoutSubtreeIfNeeded()
        let outset = SelectionPopupStyleMetrics.shadowOutset
        let fitting = hostingView.fittingSize
        let pillWidth = max(SelectionPopupStyleMetrics.minPillWidth, ceil(fitting.width - outset * 2))
        let pillSize = CGSize(width: pillWidth, height: SelectionPopupStyleMetrics.pillHeight)
        let visible = SelectionPopupLayout.preferredVisibleFrame(
            selectionRect: selectionRect,
            releasePoint: releasePoint,
            screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) },
            mainVisibleFrame: NSScreen.main?.visibleFrame
        )
        let pillOrigin = SelectionPopupLayout.panelOrigin(
            panelSize: pillSize,
            selectionRect: selectionRect,
            releasePoint: releasePoint,
            visibleFrame: visible,
            verticalPlacement: verticalPlacement
        )
        let panelFrame = NSRect(
            x: pillOrigin.x - outset,
            y: pillOrigin.y - outset,
            width: pillSize.width + outset * 2,
            height: pillSize.height + outset * 2
        )
        setFrame(panelFrame, display: true)
        let isInteractive = if case .ready = phase { true } else { false }
        updateMousePassthrough(isInteractivePhase: isInteractive)
        orderFrontRegardless()
    }
}

@MainActor
struct SelectionPopupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    let phase: SelectionPopupPhase
    let language: AppLanguage
    let onStash: @MainActor () -> Void

    private var isInteractive: Bool {
        if case .ready = phase { return true }
        return false
    }

    private var surfaceFillColor: Color {
        let hoveredReady = isInteractive && isHovered
        if colorScheme == .dark {
            return hoveredReady
                ? Color(red: 0.185, green: 0.185, blue: 0.205)
                : Color(red: 0.145, green: 0.145, blue: 0.16)
        }
        return hoveredReady ? Color(white: 0.965) : Color.white
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.075)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color(white: 0.95) : Color(red: 0.145, green: 0.145, blue: 0.16)
    }

    private var shortcutTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.46) : Color.black.opacity(0.42)
    }

    var body: some View {
        let label = phase.labelText(in: language)
        Button(action: onStash) {
            HStack(spacing: SelectionPopupStyleMetrics.itemSpacing) {
                leadingAccessory
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryTextColor)
                if case .ready(let hint) = phase, let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(shortcutTextColor)
                }
            }
            .padding(.horizontal, SelectionPopupStyleMetrics.horizontalPadding)
            .frame(minWidth: SelectionPopupStyleMetrics.minPillWidth, minHeight: SelectionPopupStyleMetrics.pillHeight)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule(style: .continuous)
                    .fill(surfaceFillColor)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.34 : 0.08),
                        radius: 5,
                        x: 0,
                        y: 2
                    )
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.18 : 0.04),
                        radius: 1,
                        x: 0,
                        y: 0.5
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .disabled(!isInteractive)
        .environment(\.controlActiveState, .key)
        .accessibilityIdentifier("selectionPopup.stash")
        .accessibilityLabel(label)
        .padding(SelectionPopupStyleMetrics.shadowOutset)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        switch phase {
        case .hidden, .ready:
            EmptyView()
        case .saving:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 11, height: 11)
        case .saved(let offline):
            Image(systemName: offline ? "clock.badge.checkmark" : "checkmark")
                .font(.system(size: 10.5, weight: .semibold))
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

    private lazy var panel = SelectionPopupPanel(
        onStash: { [weak self] in
            self?.handleCapsuleClick()
        },
        onOutsideShadowClick: { [weak self] in
            guard let self, self.phase != .saving else { return }
            self.hideImmediately()
        }
    )
    private var gestureEvaluator = SelectionGestureEvaluator()
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var probeTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var anchorSelectionRect: CGRect?
    private var anchorReleasePoint: CGPoint = .zero
    private var anchorVerticalPlacement: SelectionPopupLayout.VerticalPlacement = .above
    private var anchorPID: pid_t?
    private var isRunning = false
    private var observationGeneration: UInt64 = 0
    package private(set) var phase: SelectionPopupPhase = .hidden
    public var language: AppLanguage {
        didSet {
            guard oldValue != language, phase != .hidden else { return }
            panel.render(
                phase: phase,
                language: language,
                selectionRect: anchorSelectionRect,
                releasePoint: anchorReleasePoint,
                verticalPlacement: anchorVerticalPlacement
            ) { [weak self] in
                self?.handleCapsuleClick()
            }
        }
    }

    public var isVisible: Bool {
        phase != .hidden && panel.isVisible
    }

    public init(
        appearance: AppAppearancePreferences,
        shortcuts: AppShortcuts,
        language: AppLanguage = .zhHans,
        onTriggerCapture: @escaping @MainActor () async -> SelectionCaptureOutcome,
        onPresentErrorHUD: @escaping @MainActor () -> Void
    ) {
        self.appearance = appearance
        self.shortcuts = shortcuts
        self.language = language
        self.onTriggerCapture = onTriggerCapture
        self.onPresentErrorHUD = onPresentErrorHUD
    }

    public func start() {
        stop()
        isRunning = true
        observationGeneration &+= 1
        observeAppearancePreference()
        warmUpFrontmostApplicationIfNeeded()

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

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.syncPanelMousePassthrough()
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.panel.isVisible {
                    self.syncPanelMousePassthrough()
                }
            }
            return event
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

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isVisible {
                    self.handleGlobalKeyDown(event)
                }
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalKeyUp(event)
            }
        }) {
            eventMonitors.append(monitor)
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPID = app?.processIdentifier
            let bundleIdentifier = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleApplicationActivation(activatedPID: activatedPID, bundleIdentifier: bundleIdentifier)
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
        anchorVerticalPlacement = .above
        anchorPID = nil
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    public func hideImmediately() {
        cancelPendingProbe()
        holdTask?.cancel()
        holdTask = nil
        phase = .hidden
        anchorSelectionRect = nil
        anchorReleasePoint = .zero
        anchorVerticalPlacement = .above
        anchorPID = nil
        panel.ignoresMouseEvents = true
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
        let canShowSaved = isRunning && phase == .saving && appearance.showsSelectionPopup
        let resolution = SelectionPopupPhase.resolveCaptureOutcome(outcome)
        switch resolution.nextPhase {
        case .saved(let offline):
            guard canShowSaved else {
                hideImmediately()
                return
            }
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

    package func handleApplicationActivation(activatedPID: pid_t?, bundleIdentifier: String? = nil) {
        if appearance.showsSelectionPopup,
           let activatedPID,
           let host = SelectionPopupHost(bundleIdentifier: bundleIdentifier) {
            SelectionPopupAXProbe.warmUpAccessibilityIfNeeded(pid: activatedPID, host: host)
        }
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
        verticalPlacement: SelectionPopupLayout.VerticalPlacement = .above,
        shortcutHint: String? = nil
    ) {
        self.anchorPID = anchorPID
        self.anchorSelectionRect = selectionRect
        self.anchorReleasePoint = releasePoint
        self.anchorVerticalPlacement = verticalPlacement
        setPhase(.ready(shortcutHint: shortcutHint))
    }

    private func warmUpFrontmostApplicationIfNeeded() {
        guard appearance.showsSelectionPopup,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              let host = SelectionPopupHost(bundleIdentifier: frontmost.bundleIdentifier) else {
            return
        }
        SelectionPopupAXProbe.warmUpAccessibilityIfNeeded(pid: frontmost.processIdentifier, host: host)
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
        if panel.isVisible && panel.interactiveFrame.contains(location) {
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
        if NSApplication.shared.windows.contains(where: { window in
            window.isVisible && (window === panel ? panel.interactiveFrame.contains(location) : window.frame.contains(location))
        }) {
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

        scheduleProbe(sample: sample, targetPID: frontmost.processIdentifier, host: host)
    }

    private func scheduleProbe(
        sample: SelectionGestureEvaluator.Sample,
        targetPID: pid_t,
        host: SelectionPopupHost
    ) {
        cancelPendingProbe()
        probeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(45))
            } catch {
                return
            }
            var outcome: SelectionPopupAXProbe.Outcome = .none
            for attempt in 0..<3 {
                guard let self, !Task.isCancelled, self.appearance.showsSelectionPopup else { return }
                guard let active = NSWorkspace.shared.frontmostApplication,
                      active.processIdentifier == targetPID,
                      SelectionPopupHost(bundleIdentifier: active.bundleIdentifier) == host else {
                    return
                }
                let primaryHeight = SelectionPopupLayout.primaryScreenHeight()
                outcome = SelectionPopupAXProbe.probe(
                    pid: targetPID,
                    host: host,
                    sample: sample,
                    primaryScreenHeight: primaryHeight
                )
                guard case .warmingUp = outcome, attempt < 2 else {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled, self.appearance.showsSelectionPopup else { return }
            guard case .matched(let result) = outcome else {
                if self.phase != .saving {
                    self.hideImmediately()
                }
                return
            }
            if sample.mouseUpPoint == .zero, result.selectionRect == nil {
                if self.phase != .saving {
                    self.hideImmediately()
                }
                return
            }
            self.anchorPID = targetPID
            self.anchorSelectionRect = result.selectionRect
            self.anchorVerticalPlacement = host.preferredVerticalPlacement
            if sample.mouseUpPoint == .zero, let rect = result.selectionRect {
                self.anchorReleasePoint = CGPoint(x: rect.midX, y: rect.midY)
            } else {
                self.anchorReleasePoint = sample.mouseUpPoint
            }
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
        if SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            cancelPendingProbe()
            return
        }
        hideImmediately()
    }

    private func syncPanelMousePassthrough() {
        if case .ready = phase, panel.isVisible {
            panel.updateMousePassthrough(isInteractivePhase: true)
        } else {
            panel.ignoresMouseEvents = true
        }
    }

    private func handleGlobalKeyUp(_ event: NSEvent) {
        guard appearance.showsSelectionPopup else { return }
        guard SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              let host = SelectionPopupHost(bundleIdentifier: frontmost.bundleIdentifier) else {
            return
        }
        let sample = SelectionGestureEvaluator.Sample(
            mouseDownPoint: .zero,
            mouseUpPoint: .zero,
            clickCount: 1,
            modifierFlags: event.modifierFlags
        )
        scheduleProbe(sample: sample, targetPID: frontmost.processIdentifier, host: host)
    }

    private func setPhase(_ nextPhase: SelectionPopupPhase) {
        holdTask?.cancel()
        holdTask = nil
        phase = nextPhase
        panel.render(
            phase: nextPhase,
            language: language,
            selectionRect: anchorSelectionRect,
            releasePoint: anchorReleasePoint,
            verticalPlacement: anchorVerticalPlacement
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
                if self.appearance.showsSelectionPopup {
                    self.warmUpFrontmostApplicationIfNeeded()
                } else {
                    self.hideImmediately()
                }
                self.observeAppearancePreference(generation: trackedGeneration)
            }
        }
    }
}

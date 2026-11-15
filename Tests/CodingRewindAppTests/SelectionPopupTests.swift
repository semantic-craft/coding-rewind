// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CodingRewindCore
import Testing
@testable import CodingRewindApp

@Suite
struct SelectionPopupTests {
    @Test func allowlistMatchesAntigravityChatGPTAppAndGeminiApp() {
        #expect(SelectionPopupHost(bundleIdentifier: "com.google.antigravity") == .antigravity)
        #expect(SelectionPopupHost(bundleIdentifier: "com.openai.codex") == .chatGPTApp)
        #expect(SelectionPopupHost(bundleIdentifier: "com.google.GeminiMacOS") == .geminiApp)
        #expect(SelectionPopupHost.antigravity.preferredVerticalPlacement == .above)
        #expect(SelectionPopupHost.geminiApp.preferredVerticalPlacement == .above)
        #expect(SelectionPopupHost.chatGPTApp.preferredVerticalPlacement == .below)

        let rejected: [String?] = [
            nil,
            "",
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "org.mozilla.firefox",
            "dev.codingrewind.app",
            "com.apple.dt.Xcode",
            "com.openai.chat"
        ]
        for bundleID in rejected {
            #expect(SelectionPopupHost(bundleIdentifier: bundleID) == nil)
        }
    }

    @Test func chatGPTWebAreaClassificationAcceptsOnlyIndexShell() {
        #expect(ChatGPTWebAreaClassification.classify(rawURLString: "app://-/index.html") == .shell)
        #expect(ChatGPTWebAreaClassification.classify(rawURLString: "app://-/index.html#thread-42") == .shell)
        #expect(ChatGPTWebAreaClassification.classify(rawURLString: "app://-/index.html?view=codex") == .shell)

        let disallowed: [String?] = [
            nil,
            "",
            "https://chatgpt.com/c/1234",
            "https://openai.com/policies",
            "about:blank",
            "data:text/html,<p>preview</p>",
            "app://-/settings.html",
            "app://-/index.html/nested"
        ]
        for raw in disallowed {
            #expect(ChatGPTWebAreaClassification.classify(rawURLString: raw) == .disallowed)
        }
    }

    @Test func chatGPTSurfaceClassificationDistinguishesConversationMarkdownAndReadOnlyCodeFromComposersAndChrome() {
        #expect(
            ChatGPTSurfaceClassification.isSelectableContainer(
                role: kAXGroupRole,
                subrole: "AXLandmarkRegion",
                title: "Conversation",
                domClasses: []
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isSelectableContainer(
                role: kAXGroupRole,
                subrole: nil,
                title: nil,
                domClasses: ["MarkdownRoot-rZKhxa"]
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isSelectableContainer(
                role: kAXGroupRole,
                subrole: nil,
                title: nil,
                domClasses: ["CodeSurface-abc123", "rounded-lg"]
            )
        )
        #expect(
            !ChatGPTSurfaceClassification.isSelectableContainer(
                role: kAXGroupRole,
                subrole: "AXLandmarkRegion",
                title: "Sidebar",
                domClasses: ["ProseMirror"]
            )
        )

        #expect(NativeChatCodeBlock.isEditor(role: kAXTextAreaRole, title: "Edit code", classes: ["cm-content"]))
        #expect(
            !ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXTextAreaRole,
                subrole: nil,
                title: "Edit code",
                domClasses: ["cm-content"],
                hasEditableAncestor: true,
                isAllowedCodeEditor: true
            )
        )
        #expect(
            !ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXStaticTextRole,
                subrole: nil,
                title: nil,
                domClasses: [],
                hasEditableAncestor: true,
                isAllowedCodeEditor: true
            )
        )

        #expect(!NativeChatCodeBlock.isEditor(role: kAXTextAreaRole, title: "Ask ChatGPT", classes: ["ProseMirror"]))
        #expect(
            ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXTextAreaRole,
                subrole: nil,
                title: "Ask ChatGPT",
                domClasses: ["ProseMirror"],
                hasEditableAncestor: true,
                isAllowedCodeEditor: false
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXTextFieldRole,
                subrole: "AXSearchField",
                title: "Search",
                domClasses: [],
                hasEditableAncestor: false,
                isAllowedCodeEditor: false
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXStaticTextRole,
                subrole: nil,
                title: nil,
                domClasses: [],
                hasEditableAncestor: true,
                isAllowedCodeEditor: false
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXGroupRole,
                subrole: "AXLandmarkNavigation",
                title: "Sidebar",
                domClasses: [],
                hasEditableAncestor: false,
                isAllowedCodeEditor: false
            )
        )
        #expect(
            ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXGroupRole,
                subrole: "AXLandmarkBanner",
                title: nil,
                domClasses: [],
                hasEditableAncestor: false,
                isAllowedCodeEditor: false
            )
        )
        #expect(
            !ChatGPTSurfaceClassification.isDisallowedNode(
                role: kAXStaticTextRole,
                subrole: nil,
                title: nil,
                domClasses: [],
                hasEditableAncestor: false,
                isAllowedCodeEditor: false
            )
        )
    }

    @Test func keyboardSelectionNavigationAcceptsShiftArrowsAndHomeEndWhileRejectingPlainArrowsControlAndLetters() {
        let navKeys: [UInt16] = [115, 119, 123, 124, 125, 126]
        for keyCode in navKeys {
            #expect(SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.shift]))
            #expect(SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.shift, .option]))
            #expect(SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.shift, .command]))
            #expect(SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.shift, .numericPad, .function]))
            #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: []))
            #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.option]))
            #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: keyCode, modifierFlags: [.control, .shift]))
        }

        #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: 1, modifierFlags: [.control, .shift]))
        #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: 1, modifierFlags: [.control, .option, .shift, .command]))
        #expect(!SelectionGestureEvaluator.isKeyboardSelectionNavigationKey(keyCode: 0, modifierFlags: [.shift]))
    }

    @Test func gestureEvaluatorAcceptsDragMultiClickAndShiftButRejectsPlainSingleClick() {
        var evaluator = SelectionGestureEvaluator()

        evaluator.recordMouseDown(at: CGPoint(x: 100, y: 200), clickCount: 1)
        let plainClick = evaluator.evaluateMouseUp(at: CGPoint(x: 103, y: 204), clickCount: 1)
        #expect(!plainClick.qualifies)

        evaluator.recordMouseDown(at: CGPoint(x: 100, y: 200), clickCount: 1)
        let dragSelection = evaluator.evaluateMouseUp(at: CGPoint(x: 106, y: 200), clickCount: 1)
        #expect(dragSelection.qualifies)
        #expect(dragSelection.dragDistance == 6)

        evaluator.recordMouseDown(at: CGPoint(x: 100, y: 200), clickCount: 2)
        let doubleClick = evaluator.evaluateMouseUp(at: CGPoint(x: 100, y: 200), clickCount: 2)
        #expect(doubleClick.qualifies)

        evaluator.recordMouseDown(at: CGPoint(x: 100, y: 200), clickCount: 1, modifierFlags: [.shift])
        let shiftExtend = evaluator.evaluateMouseUp(at: CGPoint(x: 100, y: 200), clickCount: 1)
        #expect(shiftExtend.qualifies)
    }

    @Test func layoutConvertsQuartzCoordinatesCentersClampsAndFlipsNearScreenTop() {
        let converted = SelectionPopupLayout.appKitRect(
            fromQuartz: CGRect(x: 240, y: 100, width: 180, height: 24),
            primaryScreenHeight: 900
        )
        #expect(converted == CGRect(x: 240, y: 776, width: 180, height: 24))
        #expect(SelectionPopupLayout.quartzPoint(fromAppKit: CGPoint(x: 240, y: 776), primaryScreenHeight: 900) == CGPoint(x: 240, y: 124))

        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 835)
        let panelSize = CGSize(width: 110, height: 34)

        let centered = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 400, y: 500, width: 200, height: 22),
            releasePoint: CGPoint(x: 590, y: 505),
            visibleFrame: visibleFrame
        )
        #expect(centered == CGPoint(x: 445, y: 530))

        let clampedLeft = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 2, y: 500, width: 20, height: 22),
            releasePoint: CGPoint(x: 10, y: 505),
            visibleFrame: visibleFrame
        )
        #expect(clampedLeft.x == 8)

        let clampedRight = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 1410, y: 500, width: 24, height: 22),
            releasePoint: CGPoint(x: 1425, y: 505),
            visibleFrame: visibleFrame
        )
        #expect(clampedRight.x == 1322)

        let flippedNearTop = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 400, y: 840, width: 200, height: 24),
            releasePoint: CGPoint(x: 500, y: 850),
            visibleFrame: visibleFrame
        )
        #expect(flippedNearTop == CGPoint(x: 445, y: 796))

        let centeredBelow = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 400, y: 500, width: 200, height: 22),
            releasePoint: CGPoint(x: 590, y: 505),
            visibleFrame: visibleFrame,
            verticalPlacement: .below
        )
        #expect(centeredBelow == CGPoint(x: 445, y: 458))

        let flippedNearBottom = SelectionPopupLayout.panelOrigin(
            panelSize: panelSize,
            selectionRect: CGRect(x: 400, y: 60, width: 200, height: 24),
            releasePoint: CGPoint(x: 500, y: 65),
            visibleFrame: visibleFrame,
            verticalPlacement: .below
        )
        #expect(flippedNearBottom == CGPoint(x: 445, y: 94))
    }

    @Test func captureOutcomeResolutionSeparatesInPlaceFeedbackBusyHoldSilentDismissAndErrorHUD() {
        #expect(
            SelectionPopupPhase.resolveCaptureOutcome(.saved(cardID: "rw-1", sourceTitle: "Antigravity"))
                == .init(nextPhase: .saved(offline: false), shouldPresentErrorHUD: false)
        )
        #expect(
            SelectionPopupPhase.resolveCaptureOutcome(.queuedOffline(cardID: "rw-offline"))
                == .init(nextPhase: .saved(offline: true), shouldPresentErrorHUD: false)
        )
        #expect(
            SelectionPopupPhase.resolveCaptureOutcome(.failed(.emptySelection))
                == .init(nextPhase: .hidden, shouldPresentErrorHUD: false)
        )
        #expect(
            SelectionPopupPhase.resolveCaptureOutcome(.ignoredBusy)
                == .init(nextPhase: .saving, shouldPresentErrorHUD: false)
        )
        #expect(
            SelectionPopupPhase.resolveCaptureOutcome(.failed(.ioError("Accessibility permission required")))
                == .init(nextPhase: .hidden, shouldPresentErrorHUD: true)
        )
    }

    @Test func multiMonitorVisibleFramePrioritizesSelectionRectAndIgnoresZeroReleasePoint() {
        let primary = (
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835)
        )
        let external = (
            frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1440, y: 30, width: 2560, height: 1385)
        )
        let screens = [primary, external]

        let resolvedFromSelection = SelectionPopupLayout.preferredVisibleFrame(
            selectionRect: CGRect(x: 1600, y: 600, width: 240, height: 24),
            releasePoint: CGPoint(x: 1435, y: 600),
            screens: screens,
            mainVisibleFrame: primary.visibleFrame
        )
        #expect(resolvedFromSelection == external.visibleFrame)

        let resolvedIgnoringZeroRelease = SelectionPopupLayout.preferredVisibleFrame(
            selectionRect: nil,
            releasePoint: .zero,
            screens: screens,
            mainVisibleFrame: external.visibleFrame
        )
        #expect(resolvedIgnoringZeroRelease == external.visibleFrame)

        let resolvedFromNonZeroRelease = SelectionPopupLayout.preferredVisibleFrame(
            selectionRect: nil,
            releasePoint: CGPoint(x: 200, y: 300),
            screens: screens,
            mainVisibleFrame: external.visibleFrame
        )
        #expect(resolvedFromNonZeroRelease == primary.visibleFrame)
    }

    @Test func antigravityWebAreaClassificationAcceptsLoopbackConversationsAndChildFramesWhileRejectingExternalWebviews() {
        let uuid = "f7ecea74-ad04-4857-9e98-9468ba725e79"
        #expect(AntigravityWebAreaClassification.classify(rawURLString: "http://127.0.0.1:49807/c/\(uuid)") == .conversation)
        #expect(AntigravityWebAreaClassification.classify(rawURLString: "https://127.0.0.1:8443/c/\(uuid)/?project=test") == .conversation)
        #expect(AntigravityWebAreaClassification.classify(rawURLString: "about:blank") == .childFrame)
        #expect(AntigravityWebAreaClassification.classify(rawURLString: "about:srcdoc") == .childFrame)
        #expect(AntigravityWebAreaClassification.classify(rawURLString: "data:text/html,<p>frame</p>") == .childFrame)

        let disallowed: [String?] = [
            nil,
            "",
            "https://linear.app/team/issue/RW-14",
            "https://github.com/semantic-craft/coding-rewind/pull/14",
            "http://localhost:3000/c/\(uuid)",
            "http://127.0.0.1:49807/settings",
            "vscode-webview://1234/index.html",
            "file:///Users/dev/index.html"
        ]
        for raw in disallowed {
            #expect(AntigravityWebAreaClassification.classify(rawURLString: raw) == .disallowed)
        }
    }

    @Test @MainActor func savedPopupRendersUnifiedSyncTerminologyAndAlignedShadowOutsetGeometry() throws {
        #expect(SelectionPopupPhase.ready(shortcutHint: nil).labelText == "暂存")
        #expect(SelectionPopupPhase.saving.labelText == "暂存中…")
        #expect(SelectionPopupPhase.saved(offline: false).labelText == "已同步")
        #expect(SelectionPopupPhase.saved(offline: true).labelText == "待同步")

        let panel = SelectionPopupPanel(onStash: {})
        defer { panel.orderOut(nil) }
        #expect(!panel.hasShadow)

        let selectionRect = CGRect(x: 200, y: 200, width: 120, height: 22)
        let releasePoint = CGPoint(x: 260, y: 210)
        let phases: [SelectionPopupPhase] = [
            .ready(shortcutHint: nil),
            .ready(shortcutHint: "⌃⌥⇧⌘S"),
            .saving,
            .saved(offline: false),
            .saved(offline: true)
        ]

        let placements: [SelectionPopupLayout.VerticalPlacement] = [.above, .below]
        for placement in placements {
            for phase in phases {
                panel.render(
                    phase: phase,
                    selectionRect: selectionRect,
                    releasePoint: releasePoint,
                    verticalPlacement: placement,
                    onStash: {}
                )
                #expect(panel.isVisible)
                #expect(panel.interactiveFrame.height == 26)
                #expect(panel.frame.height == 42)
                #expect(panel.interactiveFrame.width >= SelectionPopupStyleMetrics.minPillWidth)
                let contentView = try #require(panel.contentView)
                #expect(contentView.fittingSize.width - SelectionPopupStyleMetrics.shadowOutset * 2 >= SelectionPopupStyleMetrics.minPillWidth)
                #expect(panel.frame.width == panel.interactiveFrame.width + SelectionPopupStyleMetrics.shadowOutset * 2)

                let isInteractivePhase = if case .ready = phase { true } else { false }
                let shadowPoint = CGPoint(x: panel.frame.minX + 4, y: panel.frame.midY)
                let centerPoint = CGPoint(x: panel.interactiveFrame.midX, y: panel.interactiveFrame.midY)

                panel.updateMousePassthrough(mouseLocation: shadowPoint, isInteractivePhase: isInteractivePhase)
                #expect(panel.ignoresMouseEvents)

                panel.updateMousePassthrough(mouseLocation: centerPoint, isInteractivePhase: isInteractivePhase)
                #expect(panel.ignoresMouseEvents == !isInteractivePhase)

                let expectedVisible = SelectionPopupLayout.preferredVisibleFrame(
                    selectionRect: selectionRect,
                    releasePoint: releasePoint,
                    screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) },
                    mainVisibleFrame: NSScreen.main?.visibleFrame
                )
                let expectedOrigin = SelectionPopupLayout.panelOrigin(
                    panelSize: panel.interactiveFrame.size,
                    selectionRect: selectionRect,
                    releasePoint: releasePoint,
                    visibleFrame: expectedVisible,
                    verticalPlacement: placement
                )
                #expect(panel.interactiveFrame.origin == expectedOrigin)
            }
        }
    }
}

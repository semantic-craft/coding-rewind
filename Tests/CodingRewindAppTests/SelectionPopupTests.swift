// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Testing
@testable import CodingRewindApp

@Suite
struct SelectionPopupTests {
    @Test func allowlistMatchesOnlyAntigravityAndGeminiApp() {
        #expect(SelectionPopupHost(bundleIdentifier: "com.google.antigravity") == .antigravity)
        #expect(SelectionPopupHost(bundleIdentifier: "com.google.GeminiMacOS") == .geminiApp)

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
}

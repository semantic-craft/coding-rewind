// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import Testing
@testable import CodingRewindApp

private final class HUDOffscreenMockURLProtocol: URLProtocol {
    private static let payloads = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    static func setPayload(_ data: Data, for suiteID: String) {
        payloads.withLock { $0[suiteID] = data }
    }

    static func clear(suiteID: String) {
        _ = payloads.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".hudoffscreen.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".hudoffscreen.mock.local", with: "")
        let data = Self.payloads.withLock { $0[suiteID] } ?? Data("{\"memos\":[]}".utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func drainHUDRunLoop(_ seconds: TimeInterval = 0.02) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func settleAutoreleaseAndRunLoop(iterations: Int = 3, slice: TimeInterval = 0.02) async throws {
    for _ in 0..<iterations {
        try await Task.sleep(for: .milliseconds(15))
        drainHUDRunLoop(slice)
    }
}

@MainActor
private func accessibilityChildrenOf(_ node: Any) -> [Any] {
    if let element = node as? any NSAccessibilityProtocol,
       let children = element.accessibilityChildren() {
        return children
    }
    let object = node as AnyObject
    return object.accessibilityChildren?() ?? []
}

@MainActor
private func accessibilityIdentifierOf(_ node: Any) -> String? {
    if let element = node as? any NSAccessibilityProtocol {
        return element.accessibilityIdentifier()
    }
    return (node as AnyObject).accessibilityIdentifier?()
}

@MainActor
private func accessibilityStringsOf(_ node: Any) -> [String] {
    var result: [String] = []
    if let element = node as? any NSAccessibilityProtocol {
        if let label = element.accessibilityLabel() { result.append(label) }
        if let title = element.accessibilityTitle() { result.append(title) }
        if let value = element.accessibilityValue() as? String { result.append(value) }
        return result
    }
    let object = node as AnyObject
    if let label = object.accessibilityLabel?() { result.append(label) }
    if let title = object.accessibilityTitle?() { result.append(title) }
    let valueSelector = NSSelectorFromString("accessibilityValue")
    if object.responds(to: valueSelector),
       let value = object.perform(valueSelector)?.takeUnretainedValue() as? String {
        result.append(value)
    }
    if let element = node as? any NSAccessibilityStaticText,
       let value = element.accessibilityValue() {
        result.append(value)
    }
    return result
}

@MainActor
private func walkAccessibilityChildren(
    from root: Any,
    visited: inout Set<ObjectIdentifier>,
    visit: (Any) -> Bool
) -> Bool {
    autoreleasepool {
        let object = root as AnyObject
        if !visited.insert(ObjectIdentifier(object)).inserted {
            return false
        }
        if visit(root) {
            return true
        }
        for child in accessibilityChildrenOf(root) {
            if walkAccessibilityChildren(from: child, visited: &visited, visit: visit) {
                return true
            }
        }
        return false
    }
}

@MainActor
private func hasAccessibilityIdentifier(_ identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return walkAccessibilityChildren(from: root, visited: &visited) { node in
        accessibilityIdentifierOf(node) == identifier
    }
}

@MainActor
private func hasAccessibilityText(_ substring: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return walkAccessibilityChildren(from: root, visited: &visited) { node in
        accessibilityStringsOf(node).contains { $0.contains(substring) }
    }
}

@MainActor
@discardableResult
private func pressAccessibilityElement(identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return walkAccessibilityChildren(from: root, visited: &visited) { node in
        guard accessibilityIdentifierOf(node) == identifier else { return false }
        if let button = node as? any NSAccessibilityButton {
            return button.accessibilityPerformPress()
        }
        if let element = node as? any NSAccessibilityProtocol {
            return element.accessibilityPerformPress()
        }
        return (node as AnyObject).accessibilityPerformPress?() == true
    }
}

@MainActor
private func firstEditableTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable {
        return field
    }
    for subview in view.subviews {
        if let match = firstEditableTextField(in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func focusHUDSearchField(in panel: QuickPeekHUDPanel) -> Bool {
    autoreleasepool {
        guard let contentView = panel.contentView,
              let field = firstEditableTextField(in: contentView) else {
            return
        }
        _ = panel.makeFirstResponder(field)
    }
    drainHUDRunLoop(0.03)
    return autoreleasepool {
        guard let contentView = panel.contentView,
              let responderView = panel.firstResponder as? NSView else {
            return false
        }
        return responderView.isDescendant(of: contentView)
    }
}

@MainActor
private func sendSpaceKeyPress(to panel: QuickPeekHUDPanel) throws {
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    ))
    let up = try #require(NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp + 0.01,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    ))
    autoreleasepool {
        panel.sendEvent(down)
        panel.sendEvent(up)
    }
    drainHUDRunLoop(0.04)
}

@MainActor
private func encodeMockMemosPayload(id: String, verbatimText: String) throws -> Data {
    let dto = MemoWireDTO(
        name: "memos/\(id)",
        content: "#rewind/ready #source/macos\n\n\(verbatimText)",
        createTime: ISO8601DateFormatter().string(from: Date())
    )
    return try JSONEncoder().encode(["memos": [dto]])
}

private struct HUDOffscreenHarness {
    let dir: URL
    let suiteID: String
    let wasEnhancedAXEnabled: Bool
    let coordinator: AppCoordinator
    let delegate: CodingRewindAppDelegate
    let shortcuts: AppShortcuts
    let panel: QuickPeekHUDPanel

    @MainActor
    static func make() throws -> HUDOffscreenHarness {
        let getEnhancedSelector = Selector(("accessibilityEnhancedUserInterfaceAttribute"))
        let setEnhancedSelector = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
        let wasEnhancedAXEnabled: Bool = {
            guard NSApplication.shared.responds(to: getEnhancedSelector),
                  let unmanaged = NSApplication.shared.perform(getEnhancedSelector) else {
                return false
            }
            return (unmanaged.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }()
        if NSApplication.shared.responds(to: setEnhancedSelector) {
            _ = NSApplication.shared.perform(setEnhancedSelector, with: NSNumber(value: true))
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent(".test-data/hud-offscreen-\(UUID().uuidString)")
        let suiteID = UUID().uuidString.lowercased()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HUDOffscreenMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: config))

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let environment: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hudoffscreen.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "qa-hud-offscreen-token"
        ]
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: environment,
            memosClient: memosClient,
            capturer: HUDOffscreenUnusedCapturer()
        )
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coordinator
        let shortcuts = AppShortcuts { delegate.perform($0) }
        let panel = QuickPeekHUDPanel(coordinator: coordinator, shortcuts: shortcuts) { delegate.perform($0) }
        delegate.hudPanel = panel

        return HUDOffscreenHarness(
            dir: dir,
            suiteID: suiteID,
            wasEnhancedAXEnabled: wasEnhancedAXEnabled,
            coordinator: coordinator,
            delegate: delegate,
            shortcuts: shortcuts,
            panel: panel
        )
    }

    @MainActor
    func tearDown() {
        if NSApplication.shared.isHidden {
            NSApplication.shared.unhideWithoutActivation()
        }
        panel.orderOut(nil)
        let setEnhancedSelector = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
        if NSApplication.shared.responds(to: setEnhancedSelector) {
            _ = NSApplication.shared.perform(setEnhancedSelector, with: NSNumber(value: wasEnhancedAXEnabled))
        }
        shortcuts.stop()
        HUDOffscreenMockURLProtocol.clear(suiteID: suiteID)
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func triggerHotStreamRefresh(id: String, verbatimText: String) async throws {
        let payload = try encodeMockMemosPayload(id: id, verbatimText: verbatimText)
        HUDOffscreenMockURLProtocol.setPayload(payload, for: suiteID)
        delegate.perform(.refreshHotStream)
        for _ in 0..<100 {
            if coordinator.cards.first?.verbatimText == verbatimText {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.cards.first?.verbatimText == verbatimText)
    }
}

private struct HUDOffscreenUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.ioError("Unused")
    }
}

extension AppShortcutsTests {
    @Test func quickPeekHUDDoesNotMountOrRefreshOffscreenBeforeFirstPresentation() async throws {
        let harness = try HUDOffscreenHarness.make()
        defer { harness.tearDown() }

        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        drainHUDRunLoop(0.03)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(!harness.panel.viewsNeedDisplay)

        try await harness.triggerHotStreamRefresh(
            id: "rw-hidden-initial",
            verbatimText: "Offscreen refresh before first presentation"
        )
        try await settleAutoreleaseAndRunLoop()
        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(!harness.panel.viewsNeedDisplay)
    }

    @Test func quickPeekHUDUnmountsAndDeallocatesHostingViewAcrossAllDismissPaths() async throws {
        let harness = try HUDOffscreenHarness.make()
        defer { harness.tearDown() }

        var expectedVisibleText = "Visible card across dismiss paths"
        try await harness.triggerHotStreamRefresh(id: "rw-dismiss-seed", verbatimText: expectedVisibleText)

        enum DismissPath: CaseIterable {
            case orderOut
            case toggleWhenVisible
            case cancelOperation
            case windowClose
            case performClose
            case accessibilityCloseWhileSearchFocused
            case applicationHide
        }

        for (index, path) in DismissPath.allCases.enumerated() {
            autoreleasepool {
                switch path {
                case .orderOut, .toggleWhenVisible, .cancelOperation:
                    harness.panel.presentNonActivating()
                case .windowClose, .performClose, .accessibilityCloseWhileSearchFocused, .applicationHide:
                    harness.panel.presentAndFocus()
                }
            }
            try await settleAutoreleaseAndRunLoop()

            #expect(harness.panel.isVisible)
            #expect(harness.panel.contentView?.subviews.count == 1)
            #expect(hasAccessibilityIdentifier("hud.search", in: harness.panel))
            #expect(hasAccessibilityIdentifier("hud.close", in: harness.panel))
            #expect(hasAccessibilityText(expectedVisibleText, in: harness.panel))

            weak var weakHostedView: NSView?
            let hadHostedView = autoreleasepool {
                weakHostedView = harness.panel.contentView?.subviews.first
                return weakHostedView != nil
            }
            #expect(hadHostedView)

            switch path {
            case .orderOut:
                autoreleasepool { harness.panel.orderOut(nil) }
            case .toggleWhenVisible:
                autoreleasepool { harness.panel.toggle() }
            case .cancelOperation:
                autoreleasepool { harness.panel.cancelOperation(nil) }
            case .windowClose:
                autoreleasepool { harness.panel.close() }
            case .performClose:
                autoreleasepool { harness.panel.performClose(nil) }
            case .accessibilityCloseWhileSearchFocused:
                #expect(focusHUDSearchField(in: harness.panel))
                #expect(pressAccessibilityElement(identifier: "hud.close", in: harness.panel))
            case .applicationHide:
                autoreleasepool { NSApplication.shared.hide(nil) }
            }

            try await settleAutoreleaseAndRunLoop(iterations: 4, slice: 0.02)
            let hostedViewDeallocated = (weakHostedView == nil)
            #expect(!harness.panel.isVisible)
            #expect(harness.panel.contentView?.subviews.isEmpty == true)
            #expect(hostedViewDeallocated)

            harness.panel.viewsNeedDisplay = false
            let nextText = "Hidden payload after \(path)"
            try await harness.triggerHotStreamRefresh(
                id: "rw-after-dismiss-\(index)",
                verbatimText: nextText
            )
            expectedVisibleText = nextText
            try await settleAutoreleaseAndRunLoop()
            #expect(harness.panel.contentView?.subviews.isEmpty == true)
            #expect(!harness.panel.viewsNeedDisplay)

            if path == .applicationHide {
                autoreleasepool { NSApplication.shared.unhideWithoutActivation() }
                try await settleAutoreleaseAndRunLoop()
                #expect(harness.panel.isVisible)
                #expect(harness.panel.contentView?.subviews.count == 1)
                #expect(hasAccessibilityText(expectedVisibleText, in: harness.panel))
                autoreleasepool { harness.panel.orderOut(nil) }
                try await settleAutoreleaseAndRunLoop()
                #expect(!harness.panel.isVisible)
                #expect(harness.panel.contentView?.subviews.isEmpty == true)
            }
        }
    }

    @Test func quickPeekHUDRendersHiddenUpdatesOnRepresentAndPreservesVisibleFrame() async throws {
        let harness = try HUDOffscreenHarness.make()
        defer { harness.tearDown() }

        autoreleasepool { harness.panel.presentNonActivating() }
        try await settleAutoreleaseAndRunLoop()
        #expect(harness.panel.isVisible)
        autoreleasepool { harness.panel.orderOut(nil) }
        try await settleAutoreleaseAndRunLoop()
        #expect(!harness.panel.isVisible)

        let updatedCardText = "Refreshed while hidden in English mode"
        try await harness.triggerHotStreamRefresh(id: "rw-hidden-en", verbatimText: updatedCardText)
        harness.coordinator.setLanguage(.en)
        try await settleAutoreleaseAndRunLoop()

        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(!harness.panel.viewsNeedDisplay)

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleAutoreleaseAndRunLoop()

        #expect(harness.panel.isVisible)
        #expect(harness.panel.frame.size == NSSize(width: 480, height: 560))
        #expect(hasAccessibilityText(updatedCardText, in: harness.panel))
        #expect(hasAccessibilityText(AppStrings.closeHUDLabel(in: .en), in: harness.panel))
        #expect(hasAccessibilityText(AppStrings.searchAccessibilityLabel(in: .en), in: harness.panel))

        let mountedBeforeResize = try #require(harness.panel.contentView?.subviews.first)
        harness.panel.setFrame(
            NSRect(origin: harness.panel.frame.origin, size: NSSize(width: 540, height: 640)),
            display: true
        )
        drainHUDRunLoop(0.02)
        #expect(harness.panel.frame.size == NSSize(width: 540, height: 640))

        harness.panel.presentNonActivating()
        drainHUDRunLoop(0.02)
        #expect(harness.panel.contentView?.subviews.first === mountedBeforeResize)
        #expect(harness.panel.frame.size == NSSize(width: 540, height: 640))

        harness.panel.presentAndFocus()
        drainHUDRunLoop(0.02)
        #expect(harness.panel.contentView?.subviews.first === mountedBeforeResize)
        #expect(harness.panel.frame.size == NSSize(width: 540, height: 640))
    }

    @Test func quickPeekHUDPreservesSpaceShortcutAndCoordinatorStateAcrossReopen() async throws {
        let harness = try HUDOffscreenHarness.make()
        defer { harness.tearDown() }

        try await harness.triggerHotStreamRefresh(id: "rw-space-card", verbatimText: "Space toggle card")
        harness.coordinator.bannerMessage = "Saved banner"
        harness.coordinator.markSynthesizedOnLaunch = false

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleAutoreleaseAndRunLoop()
        try sendSpaceKeyPress(to: harness.panel)
        #expect(harness.coordinator.checkedCardIDs.contains("rw-space-card"))

        autoreleasepool { harness.panel.performClose(nil) }
        try await settleAutoreleaseAndRunLoop()
        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleAutoreleaseAndRunLoop()
        #expect(harness.coordinator.bannerMessage == "Saved banner")
        #expect(hasAccessibilityText("Saved banner", in: harness.panel))
        #expect(!harness.coordinator.markSynthesizedOnLaunch)
        try sendSpaceKeyPress(to: harness.panel)
        #expect(!harness.coordinator.checkedCardIDs.contains("rw-space-card"))
    }

    @Test func quickPeekHUDShowsPlaceChipsSectionsMapAndPickerInsideTheNonActivatingPanel() async throws {
        let harness = try HUDOffscreenHarness.make()
        defer { harness.tearDown() }
        let paper = try #require(PlaceRef(tag: "project/paper-02"))
        let createTime = ISO8601DateFormatter().string(from: Date())
        let memos = [
            MemoWireDTO(name: "memos/pl-p-paper-02", content: MemosWireFormat.formatPlaceMemo(PlaceRecord(ref: paper, title: "身体预设")), createTime: createTime),
            MemoWireDTO(name: "memos/rw-placed", content: "#rewind/ready #source/macos #project/paper-02\n\nPlaced card body", createTime: createTime),
            MemoWireDTO(name: "memos/rw-unplaced", content: "#rewind/ready #source/macos\n\nUnplaced card body", createTime: createTime)
        ]
        HUDOffscreenMockURLProtocol.setPayload(try JSONEncoder().encode(["memos": memos]), for: harness.suiteID)
        harness.delegate.perform(.refreshHotStream)
        for _ in 0..<200 where harness.coordinator.places.isEmpty || harness.coordinator.unplacedCount == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.coordinator.cards.count == 2)
        #expect(harness.coordinator.unplacedCount == 1)

        autoreleasepool { harness.panel.presentNonActivating() }
        try await settleAutoreleaseAndRunLoop()
        #expect(hasAccessibilityIdentifier("hud.card.place.rw-placed.project/paper-02", in: harness.panel))
        #expect(hasAccessibilityText("身体预设", in: harness.panel))
        #expect(hasAccessibilityText("未落位 · 1", in: harness.panel))
        #expect(hasAccessibilityText("热流 72h", in: harness.panel))

        harness.coordinator.focusedCardID = "rw-unplaced"
        let panelCount = NSApplication.shared.windows.filter { $0 is NSPanel }.count
        let commandP = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.panel.windowNumber,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(harness.panel.performKeyEquivalent(with: commandP))
        #expect(harness.coordinator.placePicker?.targetID == "rw-unplaced")
        try await settleAutoreleaseAndRunLoop()
        #expect(hasAccessibilityIdentifier("hud.placePicker.option.project/paper-02", in: harness.panel))
        #expect(harness.panel.firstResponder is NSText)
        #expect(NSApplication.shared.windows.filter { $0 is NSPanel }.count == panelCount)
        #expect(harness.panel.styleMask.contains(.nonactivatingPanel))

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.panel.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        autoreleasepool { harness.panel.sendEvent(escape) }
        try await settleAutoreleaseAndRunLoop()
        #expect(harness.coordinator.placePicker == nil)
        #expect(harness.panel.isVisible)
        #expect(!hasAccessibilityIdentifier("hud.placePicker", in: harness.panel))

        #expect(pressAccessibilityElement(identifier: "hud.section.map", in: harness.panel))
        try await settleAutoreleaseAndRunLoop()
        #expect(harness.coordinator.hudSection == .map)
        #expect(hasAccessibilityIdentifier("hud.map.column.person", in: harness.panel))
        #expect(pressAccessibilityElement(identifier: "hud.map.place.project/paper-02", in: harness.panel))
        for _ in 0..<200 where harness.coordinator.browseRecords.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await settleAutoreleaseAndRunLoop()
        #expect(harness.coordinator.hudSection == .place(paper))
        #expect(hasAccessibilityText("Placed card body", in: harness.panel))
        #expect(!hasAccessibilityText("Unplaced card body", in: harness.panel))

        harness.coordinator.setLanguage(.en)
        try await settleAutoreleaseAndRunLoop()
        #expect(hasAccessibilityText("Hot 72h", in: harness.panel))
        #expect(hasAccessibilityText("Unplaced · 1", in: harness.panel))
        #expect(hasAccessibilityText(AppStrings.backToMapButton(in: .en), in: harness.panel))
    }
}

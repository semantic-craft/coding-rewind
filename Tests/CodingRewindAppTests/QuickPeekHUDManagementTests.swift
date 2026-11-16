// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import Testing
@testable import CodingRewindApp

private final class HUDManagementMockURLProtocol: URLProtocol {
    struct RecordedRequest: Equatable, Sendable {
        let method: String
        let path: String
        let query: String?
    }

    private struct SuiteState {
        var memos: [MemoWireDTO] = []
        var requests: [RecordedRequest] = []
    }

    private static let suites = OSAllocatedUnfairLock<[String: SuiteState]>(initialState: [:])

    static func setMemos(_ memos: [MemoWireDTO], for suiteID: String) {
        suites.withLock { state in
            var suite = state[suiteID] ?? SuiteState()
            suite.memos = memos
            state[suiteID] = suite
        }
    }

    static func recordedRequests(for suiteID: String) -> [RecordedRequest] {
        suites.withLock { $0[suiteID]?.requests ?? [] }
    }

    static func clearRecordedRequests(for suiteID: String) {
        suites.withLock { state in
            guard var suite = state[suiteID] else { return }
            suite.requests.removeAll()
            state[suiteID] = suite
        }
    }

    static func clear(suiteID: String) {
        _ = suites.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".hudmgmt.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".hudmgmt.mock.local", with: "")
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let query = url.query
        let bodyData = readRequestBody(from: request)

        let (statusCode, responseData) = Self.suites.withLock { state -> (Int, Data) in
            var suite = state[suiteID] ?? SuiteState()
            suite.requests.append(RecordedRequest(method: method, path: path, query: query))

            if method == "GET", path == "/api/memos" {
                let encoded = (try? JSONEncoder().encode(["memos": suite.memos])) ?? Data("{\"memos\":[]}".utf8)
                state[suiteID] = suite
                return (200, encoded)
            }

            if method == "PATCH", path.hasPrefix("/api/memos/") {
                let id = String(path.dropFirst("/api/memos/".count))
                let decodedBody = bodyData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                let updatedContent = decodedBody?["content"] ?? "#rewind/synthesized"
                if let index = suite.memos.firstIndex(where: { $0.name == "memos/\(id)" }) {
                    let existing = suite.memos[index]
                    let updated = MemoWireDTO(
                        name: existing.name,
                        content: updatedContent,
                        createTime: existing.createTime
                    )
                    if updatedContent.contains("#rewind/synthesized") {
                        suite.memos.remove(at: index)
                    } else {
                        suite.memos[index] = updated
                    }
                    let encoded = (try? JSONEncoder().encode(updated)) ?? Data("{}".utf8)
                    state[suiteID] = suite
                    return (200, encoded)
                }
                state[suiteID] = suite
                return (404, Data("{}".utf8))
            }

            if method == "DELETE", path.hasPrefix("/api/memos/") {
                let id = String(path.dropFirst("/api/memos/".count))
                suite.memos.removeAll { $0.name == "memos/\(id)" }
                state[suiteID] = suite
                return (200, Data("{}".utf8))
            }

            state[suiteID] = suite
            return (404, Data("{}".utf8))
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readRequestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
private func drainMgmtRunLoop(_ seconds: TimeInterval = 0.02) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func settleMgmtLoop(iterations: Int = 3, slice: TimeInterval = 0.02) async throws {
    for _ in 0..<iterations {
        try await Task.sleep(for: .milliseconds(15))
        drainMgmtRunLoop(slice)
    }
}

@MainActor
private func waitUntil(
    timeoutIterations: Int = 100,
    condition: @MainActor () -> Bool
) async throws -> Bool {
    for _ in 0..<timeoutIterations {
        if condition() {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
        drainMgmtRunLoop(0.01)
    }
    return condition()
}

@MainActor
private func mgmtAXChildren(_ node: Any) -> [Any] {
    if let element = node as? any NSAccessibilityProtocol,
       let children = element.accessibilityChildren() {
        return children
    }
    return (node as AnyObject).accessibilityChildren?() ?? []
}

@MainActor
private func mgmtAXIdentifier(_ node: Any) -> String? {
    if let element = node as? any NSAccessibilityProtocol {
        return element.accessibilityIdentifier()
    }
    return (node as AnyObject).accessibilityIdentifier?()
}

@MainActor
private func mgmtAXStrings(_ node: Any) -> [String] {
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
    if let value = (object.accessibilityValue as (() -> String?)?)?() { result.append(value) }
    if let element = node as? any NSAccessibilityStaticText,
       let value = element.accessibilityValue() {
        result.append(value)
    }
    return result
}

@MainActor
private func mgmtFindAXElement(
    identifier: String,
    in root: Any,
    visited: inout Set<ObjectIdentifier>
) -> Any? {
    autoreleasepool {
        let object = root as AnyObject
        if !visited.insert(ObjectIdentifier(object)).inserted {
            return nil
        }
        if mgmtAXIdentifier(root) == identifier {
            return root
        }
        for child in mgmtAXChildren(root) {
            if let match = mgmtFindAXElement(identifier: identifier, in: child, visited: &visited) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func findMgmtAXElement(identifier: String, in root: Any) -> Any? {
    var visited: Set<ObjectIdentifier> = []
    return mgmtFindAXElement(identifier: identifier, in: root, visited: &visited)
}

@MainActor
private func hasMgmtAXIdentifier(_ identifier: String, in root: Any) -> Bool {
    findMgmtAXElement(identifier: identifier, in: root) != nil
}

@MainActor
private func hasMgmtAXText(_ substring: String, in root: Any, visited: inout Set<ObjectIdentifier>) -> Bool {
    autoreleasepool {
        let object = root as AnyObject
        if !visited.insert(ObjectIdentifier(object)).inserted {
            return false
        }
        if mgmtAXStrings(root).contains(where: { $0.contains(substring) }) {
            return true
        }
        for child in mgmtAXChildren(root) {
            if hasMgmtAXText(substring, in: child, visited: &visited) {
                return true
            }
        }
        return false
    }
}

@MainActor
private func containsMgmtAXText(_ substring: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return hasMgmtAXText(substring, in: root, visited: &visited)
}

@MainActor
private func isMgmtAXEnabled(_ element: Any) -> Bool {
    if let ax = element as? any NSAccessibilityProtocol {
        return ax.isAccessibilityEnabled()
    }
    return (element as AnyObject).isAccessibilityEnabled?() ?? true
}

@MainActor
@discardableResult
private func pressMgmtAXElement(identifier: String, in root: Any) -> Bool {
    guard let element = findMgmtAXElement(identifier: identifier, in: root) else {
        return false
    }
    if let button = element as? any NSAccessibilityButton {
        return button.accessibilityPerformPress()
    }
    if let ax = element as? any NSAccessibilityProtocol {
        return ax.accessibilityPerformPress()
    }
    return (element as AnyObject).accessibilityPerformPress?() == true
}

@MainActor
private func firstMgmtEditableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable {
        return field
    }
    for subview in view.subviews {
        if let match = firstMgmtEditableField(in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func focusMgmtSearchField(in panel: QuickPeekHUDPanel) -> Bool {
    autoreleasepool {
        guard let contentView = panel.contentView,
              let field = firstMgmtEditableField(in: contentView) else {
            return
        }
        _ = panel.makeFirstResponder(field)
    }
    drainMgmtRunLoop(0.03)
    return autoreleasepool {
        guard let contentView = panel.contentView,
              let responderView = panel.firstResponder as? NSView else {
            return false
        }
        return responderView.isDescendant(of: contentView)
    }
}

@MainActor
private func makeKeyEvent(
    windowNumber: Int,
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

private struct HUDManagementHarness {
    let dir: URL
    let suiteID: String
    let paths: StoragePaths
    let wasEnhancedAXEnabled: Bool
    let coordinator: AppCoordinator
    let delegate: CodingRewindAppDelegate
    let shortcuts: AppShortcuts
    let panel: QuickPeekHUDPanel

    @MainActor
    static func make(lockedCardIDs: [String] = []) throws -> HUDManagementHarness {
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
        let dir = repoRoot.appendingPathComponent(".test-data/hud-mgmt-\(UUID().uuidString)")
        let suiteID = UUID().uuidString.lowercased()

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        if !lockedCardIDs.isEmpty {
            let store = try ConversationHandoffStore(dataDirectoryURL: paths.dataDirectoryURL, host: .antigravity)
            _ = try store.submit(prompt: "Locked conversation", cardIDs: lockedCardIDs, markSynthesized: false)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HUDManagementMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: config))

        let environment: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hudmgmt.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "qa-hud-mgmt-token"
        ]
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: environment,
            memosClient: memosClient,
            capturer: HUDManagementUnusedCapturer()
        )
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coordinator
        let shortcuts = AppShortcuts { delegate.perform($0) }
        let panel = QuickPeekHUDPanel(coordinator: coordinator, shortcuts: shortcuts) { delegate.perform($0) }
        delegate.hudPanel = panel

        return HUDManagementHarness(
            dir: dir,
            suiteID: suiteID,
            paths: paths,
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
        HUDManagementMockURLProtocol.clear(suiteID: suiteID)
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func seedMemos(_ specs: [(id: String, text: String)]) async throws {
        let formatter = ISO8601DateFormatter()
        let baseDate = Date()
        let dtos = specs.enumerated().map { index, spec in
            MemoWireDTO(
                name: "memos/\(spec.id)",
                content: "#rewind/ready #source/macos\n\n\(spec.text)",
                createTime: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(-index * 5)))
            )
        }
        HUDManagementMockURLProtocol.setMemos(dtos, for: suiteID)
        await coordinator.refresh()
        let loaded = try await waitUntil {
            coordinator.cards.map(\.id) == specs.map(\.id)
        }
        #expect(loaded)
        HUDManagementMockURLProtocol.clearRecordedRequests(for: suiteID)
    }
}

private struct HUDManagementUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.ioError("Unused")
    }
}

extension AppShortcutsTests {
    @Test func quickPeekHUDCardButtonsWorkInNonActivatingAndActiveModesWithoutHover() async throws {
        let harness = try HUDManagementHarness.make()
        defer { harness.tearDown() }

        try await harness.seedMemos([
            ("rw-card-1", "First non-activating clip"),
            ("rw-card-2", "Second active clip")
        ])

        autoreleasepool { harness.panel.presentNonActivating() }
        try await settleMgmtLoop()
        #expect(harness.panel.isVisible)
        #expect(hasMgmtAXIdentifier("hud.card.archive.rw-card-1", in: harness.panel))
        #expect(hasMgmtAXIdentifier("hud.card.delete.rw-card-1", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.card.delete.rw-card-1", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-card-1"] })
        try await settleMgmtLoop()
        #expect(hasMgmtAXIdentifier("hud.confirmDelete.bar", in: harness.panel))
        #expect(hasMgmtAXIdentifier("hud.confirmDelete.cancel", in: harness.panel))
        #expect(hasMgmtAXIdentifier("hud.confirmDelete.confirm", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.confirmDelete.cancel", in: harness.panel))
        try await settleMgmtLoop()
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(!hasMgmtAXIdentifier("hud.confirmDelete.bar", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.card.archive.rw-card-1", in: harness.panel))
        #expect(try await waitUntil { !harness.coordinator.cards.contains(where: { $0.id == "rw-card-1" }) })
        let patchRequests = HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .filter { $0.method == "PATCH" }
        #expect(patchRequests.count == 1)
        #expect(patchRequests.first?.path == "/api/memos/rw-card-1")
        #expect(!harness.coordinator.hotCache.loadCards().contains(where: { $0.id == "rw-card-1" }))

        autoreleasepool { harness.panel.orderOut(nil) }
        try await settleMgmtLoop()

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleMgmtLoop()
        #expect(hasMgmtAXIdentifier("hud.card.archive.rw-card-2", in: harness.panel))
        #expect(hasMgmtAXIdentifier("hud.card.delete.rw-card-2", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.card.delete.rw-card-2", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-card-2"] })
        try await settleMgmtLoop()
        #expect(pressMgmtAXElement(identifier: "hud.confirmDelete.confirm", in: harness.panel))
        #expect(try await waitUntil { !harness.coordinator.cards.contains(where: { $0.id == "rw-card-2" }) })
        let deleteRequests = HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .filter { $0.method == "DELETE" }
        #expect(deleteRequests.map(\.path) == ["/api/memos/rw-card-2"])
        #expect(!harness.coordinator.hotCache.loadCards().contains(where: { $0.id == "rw-card-2" }))
    }

    @Test func quickPeekHUDTwoStepEscapePreservesPanelAndThenUnmountsHostingView() async throws {
        let harness = try HUDManagementHarness.make()
        defer { harness.tearDown() }

        try await harness.seedMemos([("rw-esc-1", "Two step escape clip")])

        autoreleasepool { harness.panel.presentNonActivating() }
        try await settleMgmtLoop()

        weak var weakHostedView1: NSView?
        autoreleasepool {
            weakHostedView1 = harness.panel.contentView?.subviews.first
        }
        #expect(weakHostedView1 != nil)

        #expect(pressMgmtAXElement(identifier: "hud.card.delete.rw-esc-1", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-esc-1"] })
        try await settleMgmtLoop()
        #expect(hasMgmtAXIdentifier("hud.confirmDelete.bar", in: harness.panel))

        autoreleasepool { harness.panel.cancelOperation(nil) }
        try await settleMgmtLoop()
        #expect(harness.panel.isVisible)
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(!hasMgmtAXIdentifier("hud.confirmDelete.bar", in: harness.panel))
        #expect(harness.coordinator.cards.contains(where: { $0.id == "rw-esc-1" }))

        autoreleasepool { harness.panel.cancelOperation(nil) }
        try await settleMgmtLoop(iterations: 4, slice: 0.02)
        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(weakHostedView1 == nil)

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleMgmtLoop()

        weak var weakHostedView2: NSView?
        autoreleasepool {
            weakHostedView2 = harness.panel.contentView?.subviews.first
        }
        #expect(weakHostedView2 != nil)

        #expect(pressMgmtAXElement(identifier: "hud.card.delete.rw-esc-1", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-esc-1"] })
        try await settleMgmtLoop()

        let escEvent1 = try makeKeyEvent(windowNumber: harness.panel.windowNumber, keyCode: 53, characters: "\u{1b}")
        let handled1 = autoreleasepool { harness.panel.performKeyEquivalent(with: escEvent1) }
        #expect(handled1)
        try await settleMgmtLoop()
        #expect(harness.panel.isVisible)
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(!hasMgmtAXIdentifier("hud.confirmDelete.bar", in: harness.panel))

        let escEvent2 = try makeKeyEvent(windowNumber: harness.panel.windowNumber, keyCode: 53, characters: "\u{1b}")
        let handled2 = autoreleasepool { harness.panel.performKeyEquivalent(with: escEvent2) }
        #expect(handled2)
        try await settleMgmtLoop(iterations: 4, slice: 0.02)
        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(weakHostedView2 == nil)
    }

    @Test func quickPeekHUDBatchArchiveAndBatchDeleteCheckedCards() async throws {
        let harness = try HUDManagementHarness.make()
        defer { harness.tearDown() }

        try await harness.seedMemos([
            ("rw-batch-1", "Batch clip 1"),
            ("rw-batch-2", "Batch clip 2"),
            ("rw-batch-3", "Batch clip 3")
        ])

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleMgmtLoop()
        #expect(!hasMgmtAXIdentifier("hud.archiveSelected", in: harness.panel))
        #expect(!hasMgmtAXIdentifier("hud.deleteSelected", in: harness.panel))

        harness.coordinator.toggleCheck(for: "rw-batch-1")
        harness.coordinator.toggleCheck(for: "rw-batch-2")
        try await settleMgmtLoop()
        #expect(hasMgmtAXIdentifier("hud.archiveSelected", in: harness.panel))
        #expect(hasMgmtAXIdentifier("hud.deleteSelected", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.archiveSelected", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.cards.map(\.id) == ["rw-batch-3"] })
        let patches = HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .filter { $0.method == "PATCH" }
            .map(\.path)
        #expect(Set(patches) == ["/api/memos/rw-batch-1", "/api/memos/rw-batch-2"])
        #expect(harness.coordinator.hotCache.loadCards().map(\.id) == ["rw-batch-3"])

        try await settleMgmtLoop()
        #expect(!hasMgmtAXIdentifier("hud.archiveSelected", in: harness.panel))
        #expect(!hasMgmtAXIdentifier("hud.deleteSelected", in: harness.panel))

        try await harness.seedMemos([
            ("rw-batch-4", "Batch clip 4"),
            ("rw-batch-5", "Batch clip 5")
        ])
        harness.coordinator.toggleCheck(for: "rw-batch-4")
        harness.coordinator.toggleCheck(for: "rw-batch-5")
        try await settleMgmtLoop()

        #expect(pressMgmtAXElement(identifier: "hud.deleteSelected", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-batch-4", "rw-batch-5"] })
        try await settleMgmtLoop()
        #expect(containsMgmtAXText("2", in: harness.panel))

        #expect(pressMgmtAXElement(identifier: "hud.confirmDelete.confirm", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.cards.isEmpty })
        let deletes = HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .filter { $0.method == "DELETE" }
            .map(\.path)
        #expect(Set(deletes) == ["/api/memos/rw-batch-4", "/api/memos/rw-batch-5"])
        #expect(harness.coordinator.hotCache.loadCards().isEmpty)
    }

    @Test func quickPeekHUDKeyboardShortcutsAndSearchFocusGuard() async throws {
        let harness = try HUDManagementHarness.make()
        defer { harness.tearDown() }

        try await harness.seedMemos([
            ("rw-key-1", "Shortcut archive card"),
            ("rw-key-2", "Shortcut confirm delete card"),
            ("rw-key-3", "Shortcut immediate delete card"),
            ("rw-key-4", "Search guard card")
        ])

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleMgmtLoop()

        harness.coordinator.focusedCardID = "rw-key-1"
        let cmdE = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 14,
            characters: "e",
            modifiers: [.command]
        )
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: cmdE) })
        #expect(try await waitUntil { !harness.coordinator.cards.contains(where: { $0.id == "rw-key-1" }) })
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .contains(where: { $0.method == "PATCH" && $0.path == "/api/memos/rw-key-1" }))

        harness.coordinator.focusedCardID = "rw-key-2"
        let cmdDelete = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 51,
            characters: "\u{7f}",
            modifiers: [.command]
        )
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: cmdDelete) })
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-key-2"] })
        try await settleMgmtLoop()

        let unmodifiedReturn = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 36,
            characters: "\r",
            modifiers: []
        )
        autoreleasepool { harness.panel.sendEvent(unmodifiedReturn) }
        #expect(try await waitUntil { !harness.coordinator.cards.contains(where: { $0.id == "rw-key-2" }) })
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .contains(where: { $0.method == "DELETE" && $0.path == "/api/memos/rw-key-2" }))

        harness.coordinator.focusedCardID = "rw-key-3"
        let optCmdDelete = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 51,
            characters: "\u{7f}",
            modifiers: [.command, .option]
        )
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: optCmdDelete) })
        #expect(try await waitUntil { !harness.coordinator.cards.contains(where: { $0.id == "rw-key-3" }) })
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .contains(where: { $0.method == "DELETE" && $0.path == "/api/memos/rw-key-3" }))

        HUDManagementMockURLProtocol.clearRecordedRequests(for: harness.suiteID)
        harness.coordinator.focusedCardID = "rw-key-4"
        #expect(focusMgmtSearchField(in: harness.panel))

        let guardedDelete = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 51,
            characters: "\u{7f}",
            modifiers: [.command]
        )
        #expect(autoreleasepool { !harness.panel.performKeyEquivalent(with: guardedDelete) })
        let guardedArchive = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 14,
            characters: "e",
            modifiers: [.command]
        )
        #expect(autoreleasepool { !harness.panel.performKeyEquivalent(with: guardedArchive) })
        try await settleMgmtLoop()
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID).isEmpty)
        #expect(harness.coordinator.cards.map(\.id) == ["rw-key-4"])

        #expect(pressMgmtAXElement(identifier: "hud.card.delete.rw-key-4", in: harness.panel))
        #expect(try await waitUntil { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-key-4"] })
        try await settleMgmtLoop()

        let confirmAfterButtonClick = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 36,
            characters: "\r",
            modifiers: []
        )
        autoreleasepool { harness.panel.sendEvent(confirmAfterButtonClick) }
        #expect(try await waitUntil { harness.coordinator.cards.isEmpty })
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID)
            .contains(where: { $0.method == "DELETE" && $0.path == "/api/memos/rw-key-4" }))
    }

    @Test func quickPeekHUDLockedConversationCardsBlockButtonsAndShortcuts() async throws {
        let harness = try HUDManagementHarness.make(lockedCardIDs: ["rw-locked-1"])
        defer { harness.tearDown() }

        try await harness.seedMemos([
            ("rw-locked-1", "Active conversation card"),
            ("rw-unlocked-2", "Unlocked sibling card")
        ])

        autoreleasepool { harness.panel.presentAndFocus() }
        try await settleMgmtLoop()

        #expect(harness.coordinator.isCardLocked("rw-locked-1"))
        #expect(!harness.coordinator.isCardLocked("rw-unlocked-2"))

        let lockedArchiveBtn = try #require(findMgmtAXElement(identifier: "hud.card.archive.rw-locked-1", in: harness.panel))
        let lockedDeleteBtn = try #require(findMgmtAXElement(identifier: "hud.card.delete.rw-locked-1", in: harness.panel))
        let unlockedDeleteBtn = try #require(findMgmtAXElement(identifier: "hud.card.delete.rw-unlocked-2", in: harness.panel))
        #expect(!isMgmtAXEnabled(lockedArchiveBtn))
        #expect(!isMgmtAXEnabled(lockedDeleteBtn))
        #expect(isMgmtAXEnabled(unlockedDeleteBtn))

        _ = pressMgmtAXElement(identifier: "hud.card.archive.rw-locked-1", in: harness.panel)
        _ = pressMgmtAXElement(identifier: "hud.card.delete.rw-locked-1", in: harness.panel)
        try await settleMgmtLoop()
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID).isEmpty)

        #expect(harness.coordinator.checkedCardIDs.contains("rw-locked-1"))
        let batchArchiveBtn = try #require(findMgmtAXElement(identifier: "hud.archiveSelected", in: harness.panel))
        let batchDeleteBtn = try #require(findMgmtAXElement(identifier: "hud.deleteSelected", in: harness.panel))
        #expect(!isMgmtAXEnabled(batchArchiveBtn))
        #expect(!isMgmtAXEnabled(batchDeleteBtn))

        harness.coordinator.toggleCheck(for: "rw-unlocked-2")
        try await settleMgmtLoop()
        let mixedArchiveBtn = try #require(findMgmtAXElement(identifier: "hud.archiveSelected", in: harness.panel))
        let mixedDeleteBtn = try #require(findMgmtAXElement(identifier: "hud.deleteSelected", in: harness.panel))
        #expect(!isMgmtAXEnabled(mixedArchiveBtn))
        #expect(!isMgmtAXEnabled(mixedDeleteBtn))
        harness.coordinator.toggleCheck(for: "rw-unlocked-2")
        try await settleMgmtLoop()

        harness.coordinator.focusedCardID = "rw-locked-1"
        let cmdE = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 14,
            characters: "e",
            modifiers: [.command]
        )
        let cmdDelete = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 51,
            characters: "\u{7f}",
            modifiers: [.command]
        )
        let optCmdDelete = try makeKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 51,
            characters: "\u{7f}",
            modifiers: [.command, .option]
        )
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: cmdE) })
        try await settleMgmtLoop()
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: cmdDelete) })
        try await settleMgmtLoop()
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: optCmdDelete) })
        try await settleMgmtLoop()

        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(HUDManagementMockURLProtocol.recordedRequests(for: harness.suiteID).isEmpty)
        #expect(harness.coordinator.cards.map(\.id) == ["rw-locked-1", "rw-unlocked-2"])
    }
}

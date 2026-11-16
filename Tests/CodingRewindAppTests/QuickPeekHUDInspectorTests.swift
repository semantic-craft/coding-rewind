// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import Testing
@testable import CodingRewindApp

private final class HUDInspectorMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func setHandler(suiteID: String, handler: @escaping Handler) {
        handlers.withLock { $0[suiteID] = handler }
    }

    static func clear(suiteID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".hudinspector.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".hudinspector.mock.local", with: "")
        guard let handler = Self.handlers.withLock({ $0[suiteID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, data) = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private func drainInspectorRunLoop(_ seconds: TimeInterval = 0.02) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func settleInspectorLoop(iterations: Int = 3, slice: TimeInterval = 0.02) async throws {
    for _ in 0..<iterations {
        try await Task.sleep(for: .milliseconds(15))
        drainInspectorRunLoop(slice)
    }
}

@MainActor
private func waitForInspector(
    timeoutIterations: Int = 100,
    condition: @MainActor () -> Bool
) async throws -> Bool {
    for _ in 0..<timeoutIterations {
        if condition() {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
        drainInspectorRunLoop(0.01)
    }
    return condition()
}

@MainActor
private func inspectorAXChildren(_ node: Any) -> [Any] {
    if let element = node as? any NSAccessibilityProtocol,
       let children = element.accessibilityChildren() {
        return children
    }
    return (node as AnyObject).accessibilityChildren?() ?? []
}

@MainActor
private func inspectorAXIdentifier(_ node: Any) -> String? {
    if let element = node as? any NSAccessibilityProtocol {
        return element.accessibilityIdentifier()
    }
    return (node as AnyObject).accessibilityIdentifier?()
}

@MainActor
private func inspectorAXStrings(_ node: Any) -> [String] {
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
       let rawValue = object.perform(valueSelector)?.takeUnretainedValue() as? String {
        result.append(rawValue)
    }
    if let element = node as? any NSAccessibilityStaticText,
       let value = element.accessibilityValue() {
        result.append(value)
    }
    return result
}

@MainActor
private func findInspectorAXElement(
    identifier: String,
    in root: Any,
    visited: inout Set<ObjectIdentifier>
) -> Any? {
    autoreleasepool {
        let object = root as AnyObject
        if !visited.insert(ObjectIdentifier(object)).inserted {
            return nil
        }
        if inspectorAXIdentifier(root) == identifier {
            return root
        }
        for child in inspectorAXChildren(root) {
            if let match = findInspectorAXElement(identifier: identifier, in: child, visited: &visited) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func hasInspectorAXIdentifier(_ identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return findInspectorAXElement(identifier: identifier, in: root, visited: &visited) != nil
}

@MainActor
private func containsInspectorAXText(_ substring: String, in root: Any) -> Bool {
    func walk(_ node: Any, visited: inout Set<ObjectIdentifier>) -> Bool {
        autoreleasepool {
            let object = node as AnyObject
            if !visited.insert(ObjectIdentifier(object)).inserted {
                return false
            }
            if inspectorAXStrings(node).contains(where: { $0.contains(substring) }) {
                return true
            }
            for child in inspectorAXChildren(node) {
                if walk(child, visited: &visited) {
                    return true
                }
            }
            return false
        }
    }
    var visited: Set<ObjectIdentifier> = []
    return walk(root, visited: &visited)
}

@MainActor
@discardableResult
private func pressInspectorAXElement(identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    guard let element = findInspectorAXElement(identifier: identifier, in: root, visited: &visited) else {
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
private func firstInspectorEditableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable {
        return field
    }
    for subview in view.subviews {
        if let match = firstInspectorEditableField(in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func focusInspectorSearchField(in panel: QuickPeekHUDPanel) -> Bool {
    autoreleasepool {
        guard let contentView = panel.contentView,
              let field = firstInspectorEditableField(in: contentView) else {
            return
        }
        _ = panel.makeFirstResponder(field)
    }
    drainInspectorRunLoop(0.03)
    return autoreleasepool {
        guard let contentView = panel.contentView,
              let responder = panel.firstResponder as? NSView else {
            return false
        }
        return responder.isDescendant(of: contentView)
    }
}

@MainActor
private func makeInspectorKeyEvent(
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

private struct HUDInspectorUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.emptySelection
    }
}

private struct HUDInspectorHarness {
    let dir: URL
    let suiteID: String
    let paths: StoragePaths
    let wasEnhancedAXEnabled: Bool
    let coordinator: AppCoordinator
    let delegate: CodingRewindAppDelegate
    let shortcuts: AppShortcuts
    let panel: QuickPeekHUDPanel

    @MainActor
    static func make() throws -> HUDInspectorHarness {
        _ = AppShortcutsTests.defaults
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
        let dir = repoRoot.appendingPathComponent(".test-data/hud-inspector-\(UUID().uuidString)")
        let suiteID = UUID().uuidString.lowercased()
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HUDInspectorMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: config))

        let environment: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).hudinspector.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "qa-hud-inspector-token"
        ]
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: environment,
            memosClient: memosClient,
            capturer: HUDInspectorUnusedCapturer()
        )
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coordinator
        let shortcuts = AppShortcuts { delegate.perform($0) }
        let panel = QuickPeekHUDPanel(coordinator: coordinator, shortcuts: shortcuts) { delegate.perform($0) }
        delegate.hudPanel = panel

        return HUDInspectorHarness(
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
        HUDInspectorMockURLProtocol.clear(suiteID: suiteID)
        try? FileManager.default.removeItem(at: dir)
    }
}

extension AppShortcutsTests {
    @Test func quickPeekHUDInspectorRendersSourceActionsContextLeadDeduplicationAndRetry() async throws {
        let harness = try HUDInspectorHarness.make()
        defer { harness.tearDown() }

        let now = Date()
        let nowISO = MemosWireFormat.formatISO8601UTC(now)
        let w3cURL = "https://developer.apple.com/documentation/swift#:~:text=Sendable%20protocol"
        let agID = "6eb720d3-188b-4783-a0c6-9592c554f3fc"

        let agRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Line 1\nLine 2\nLine 3\nLine 4\nLine 5 full tail",
            sourcePlatform: "antigravity",
            sourceTitle: "Antigravity Session",
            sourceURL: "conversation://\(agID)",
            capturedAt: now,
            hasContext: true
        )
        let singleTurnRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Single turn excerpt",
            sourcePlatform: "chatgpt",
            sourceTitle: "ChatGPT Single",
            sourceURL: "https://chatgpt.com/c/chat-single-1",
            capturedAt: now.addingTimeInterval(-10),
            hasContext: true
        )
        let webRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Sendable protocol excerpt",
            sourcePlatform: "web",
            sourceTitle: "Apple Docs",
            sourceURL: w3cURL,
            capturedAt: now.addingTimeInterval(-20),
            hasContext: true
        )
        let macRaw = try MemosWireFormat.formatRawMemoContent(
            verbatimText: "Local Xcode note",
            sourcePlatform: "macos",
            sourceTitle: "Xcode",
            sourceURL: nil,
            capturedAt: now.addingTimeInterval(-30),
            hasContext: false
        )

        let agCtx = CaptureContext(
            sessionTitle: "Antigravity Session",
            sessionID: agID,
            lead: .sessionOpening("Architect a non-activating HUD inspector"),
            prompt: "How should 3-step Escape work?",
            recentTurns: [
                ConversationTurn(role: "User", text: "How should 3-step Escape work?"),
                ConversationTurn(role: "Assistant", text: "Confirm bar first, inspector second, panel third.")
            ]
        )
        let agNoteRaw = try MemosWireFormat.formatNoteComment(
            note: "Verified offscreen unmount invariant.",
            author: "claude",
            createdAt: now
        )
        let singleTurnCtx = CaptureContext(
            sessionTitle: "ChatGPT Single",
            sessionID: "chat-single-1",
            lead: .sessionOpening("Identical opening and prompt"),
            prompt: "Identical opening and prompt",
            recentTurns: [ConversationTurn(role: "User", text: "Identical opening and prompt")]
        )
        let webLeadCtx = CaptureContext(
            sessionTitle: "Apple Docs",
            lead: .pageLead("Types whose values can safely be shared across concurrency domains."),
            prompt: ""
        )

        let failWebComments = OSAllocatedUnfairLock(initialState: true)
        HUDInspectorMockURLProtocol.setHandler(suiteID: harness.suiteID) { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET" && path == "/api/memos" {
                let memos = [
                    MemoWireDTO(name: "memos/rw-ag", content: agRaw, createTime: nowISO),
                    MemoWireDTO(name: "memos/rw-single", content: singleTurnRaw, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-10))),
                    MemoWireDTO(name: "memos/rw-web", content: webRaw, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-20))),
                    MemoWireDTO(name: "memos/rw-mac", content: macRaw, createTime: MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-30)))
                ]
                return (200, try JSONEncoder().encode(["memos": memos]))
            }
            if req.httpMethod == "GET" && path == "/api/memos/rw-ag/comments" {
                let comments = [
                    MemoWireDTO(name: "memos/c-ag-ctx", content: agCtx.formattedCommentMarkdown(), createTime: nowISO),
                    MemoWireDTO(name: "memos/rw-note-ag", content: agNoteRaw, createTime: nowISO)
                ]
                return (200, try JSONEncoder().encode(["memos": comments]))
            }
            if req.httpMethod == "GET" && path == "/api/memos/rw-single/comments" {
                let comments = [
                    MemoWireDTO(name: "memos/c-single-ctx", content: singleTurnCtx.formattedCommentMarkdown(), createTime: nowISO)
                ]
                return (200, try JSONEncoder().encode(["memos": comments]))
            }
            if req.httpMethod == "GET" && path == "/api/memos/rw-web/comments" {
                if failWebComments.withLock({ $0 }) {
                    return (503, Data("Service Unavailable".utf8))
                }
                let comments = [
                    MemoWireDTO(name: "memos/c-web-ctx", content: webLeadCtx.formattedCommentMarkdown(), createTime: nowISO)
                ]
                return (200, try JSONEncoder().encode(["memos": comments]))
            }
            return (200, Data("{\"memos\":[]}".utf8))
        }

        var openedURLs: [URL] = []
        var copiedTexts: [String] = []
        var wokenHosts: [ConversationHost] = []
        harness.coordinator.onOpenURL = { url in
            openedURLs.append(url)
            return false
        }
        harness.coordinator.onCopyText = { copiedTexts.append($0) }
        harness.coordinator.onWakeHost = { wokenHosts.append($0) }

        await harness.coordinator.refresh()
        #expect(harness.coordinator.cards.map(\.id) == ["rw-ag", "rw-single", "rw-web", "rw-mac"])

        autoreleasepool { harness.panel.presentNonActivating() }
        try await settleInspectorLoop()

        #expect(hasInspectorAXIdentifier("hud.card.source.rw-ag", in: harness.panel))
        #expect(hasInspectorAXIdentifier("hud.card.source.rw-web", in: harness.panel))
        #expect(!hasInspectorAXIdentifier("hud.card.source.rw-mac", in: harness.panel))

        #expect(pressInspectorAXElement(identifier: "hud.card.source.rw-ag", in: harness.panel))
        try await settleInspectorLoop()
        #expect(openedURLs.isEmpty)
        #expect(copiedTexts == [agID])
        #expect(!harness.coordinator.isErrorBanner)

        #expect(pressInspectorAXElement(identifier: "hud.card.source.rw-web", in: harness.panel))
        try await settleInspectorLoop()
        #expect(openedURLs.map(\.absoluteString) == [w3cURL])
        #expect(harness.coordinator.isErrorBanner)
        #expect(containsInspectorAXText("未能打开链接", in: harness.panel))

        harness.coordinator.onOpenURL = { url in
            openedURLs.append(url)
            return true
        }
        #expect(pressInspectorAXElement(identifier: "hud.card.preview.rw-ag", in: harness.panel))
        #expect(try await waitForInspector {
            if case .loaded = harness.coordinator.cardDetailState(for: "rw-ag") { return true }
            return false
        })
        try await settleInspectorLoop()

        #expect(hasInspectorAXIdentifier("hud.inspector", in: harness.panel))
        #expect(containsInspectorAXText("Line 5 full tail", in: harness.panel))
        #expect(containsInspectorAXText("Architect a non-activating HUD inspector", in: harness.panel))
        #expect(containsInspectorAXText("How should 3-step Escape work?", in: harness.panel))
        #expect(containsInspectorAXText("Verified offscreen unmount invariant.", in: harness.panel))

        #expect(pressInspectorAXElement(identifier: "hud.inspector.copyText", in: harness.panel))
        #expect(copiedTexts.last == "Line 1\nLine 2\nLine 3\nLine 4\nLine 5 full tail")

        copiedTexts.removeAll()
        #expect(pressInspectorAXElement(identifier: "hud.inspector.copySessionID", in: harness.panel))
        #expect(copiedTexts == [agID])

        #expect(pressInspectorAXElement(identifier: "hud.inspector.wakeAntigravity", in: harness.panel))
        #expect(wokenHosts == [.antigravity])

        #expect(pressInspectorAXElement(identifier: "hud.card.preview.rw-single", in: harness.panel))
        #expect(try await waitForInspector {
            if case .loaded = harness.coordinator.cardDetailState(for: "rw-single") { return true }
            return false
        })
        try await settleInspectorLoop()
        #expect(containsInspectorAXText("前序提问", in: harness.panel))
        #expect(!containsInspectorAXText("会话开场", in: harness.panel))

        #expect(pressInspectorAXElement(identifier: "hud.card.preview.rw-web", in: harness.panel))
        #expect(try await waitForInspector {
            if case .failed = harness.coordinator.cardDetailState(for: "rw-web") { return true }
            return false
        })
        try await settleInspectorLoop()
        #expect(hasInspectorAXIdentifier("hud.inspector.retry", in: harness.panel))

        failWebComments.withLock { $0 = false }
        #expect(pressInspectorAXElement(identifier: "hud.inspector.retry", in: harness.panel))
        #expect(try await waitForInspector {
            if case .loaded = harness.coordinator.cardDetailState(for: "rw-web") { return true }
            return false
        })
        try await settleInspectorLoop()
        #expect(containsInspectorAXText("页面导语", in: harness.panel))
        #expect(containsInspectorAXText("Types whose values can safely be shared across concurrency domains.", in: harness.panel))
    }

    @Test func quickPeekHUDThreeStepEscapeCmdISpaceAndOffscreenTaskCancellation() async throws {
        let harness = try HUDInspectorHarness.make()
        defer { harness.tearDown() }

        let nowISO = MemosWireFormat.formatISO8601UTC(Date())
        let stallComments = OSAllocatedUnfairLock(initialState: false)
        HUDInspectorMockURLProtocol.setHandler(suiteID: harness.suiteID) { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET" && path == "/api/memos" {
                let memos = [
                    MemoWireDTO(name: "memos/rw-esc-a", content: "#rewind/ready #source/macos\n\nAlpha clip", createTime: nowISO),
                    MemoWireDTO(name: "memos/rw-esc-b", content: "#rewind/ready #source/macos\n\nBeta clip", createTime: nowISO)
                ]
                return (200, try JSONEncoder().encode(["memos": memos]))
            }
            if req.httpMethod == "GET" && path.hasSuffix("/comments") {
                if stallComments.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.35)
                }
                return (200, Data("{\"memos\":[]}".utf8))
            }
            return (200, Data("{}".utf8))
        }

        await harness.coordinator.refresh()

        weak var weakHostedView: NSView?
        autoreleasepool {
            harness.panel.presentAndFocus()
            weakHostedView = harness.panel.contentView?.subviews.first
        }
        try await settleInspectorLoop()
        #expect(weakHostedView != nil)
        #expect(!hasInspectorAXIdentifier("hud.inspector", in: harness.panel))

        harness.coordinator.focusedCardID = "rw-esc-a"
        let cmdI = try makeInspectorKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 34,
            characters: "i",
            modifiers: [.command]
        )
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: cmdI) })
        try await settleInspectorLoop()
        #expect(harness.coordinator.inspectedCardID == "rw-esc-a")
        #expect(hasInspectorAXIdentifier("hud.inspector", in: harness.panel))

        let spaceDown = try makeInspectorKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 49,
            characters: " "
        )
        autoreleasepool { harness.panel.sendEvent(spaceDown) }
        try await settleInspectorLoop()
        #expect(harness.coordinator.checkedCardIDs.contains("rw-esc-a"))
        #expect(harness.coordinator.inspectedCardID == "rw-esc-a")

        #expect(focusInspectorSearchField(in: harness.panel))
        let cmdIWhileEditing = try makeInspectorKeyEvent(
            windowNumber: harness.panel.windowNumber,
            keyCode: 34,
            characters: "i",
            modifiers: [.command]
        )
        _ = autoreleasepool { harness.panel.performKeyEquivalent(with: cmdIWhileEditing) }
        try await settleInspectorLoop()
        #expect(harness.coordinator.inspectedCardID == "rw-esc-a")

        #expect(pressInspectorAXElement(identifier: "hud.card.delete.rw-esc-a", in: harness.panel))
        #expect(try await waitForInspector { harness.coordinator.pendingDeleteConfirmation?.cardIDs == ["rw-esc-a"] })
        try await settleInspectorLoop()

        let esc1 = try makeInspectorKeyEvent(windowNumber: harness.panel.windowNumber, keyCode: 53, characters: "\u{1b}")
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: esc1) })
        try await settleInspectorLoop()
        #expect(harness.panel.isVisible)
        #expect(harness.coordinator.pendingDeleteConfirmation == nil)
        #expect(harness.coordinator.inspectedCardID == "rw-esc-a")
        #expect(hasInspectorAXIdentifier("hud.inspector", in: harness.panel))

        let esc2 = try makeInspectorKeyEvent(windowNumber: harness.panel.windowNumber, keyCode: 53, characters: "\u{1b}")
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: esc2) })
        try await settleInspectorLoop()
        #expect(harness.panel.isVisible)
        #expect(harness.coordinator.inspectedCardID == nil)
        #expect(!hasInspectorAXIdentifier("hud.inspector", in: harness.panel))

        let esc3 = try makeInspectorKeyEvent(windowNumber: harness.panel.windowNumber, keyCode: 53, characters: "\u{1b}")
        #expect(autoreleasepool { harness.panel.performKeyEquivalent(with: esc3) })
        try await settleInspectorLoop(iterations: 4, slice: 0.02)
        #expect(!harness.panel.isVisible)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(weakHostedView == nil)

        stallComments.withLock { $0 = true }
        weak var weakHostedView2: NSView?
        autoreleasepool {
            harness.panel.presentNonActivating()
            weakHostedView2 = harness.panel.contentView?.subviews.first
        }
        try await settleInspectorLoop()
        harness.coordinator.toggleCardPreview(id: "rw-esc-b")
        #expect(harness.coordinator.inspectedCardID == "rw-esc-b")

        autoreleasepool {
            harness.panel.orderOut(nil)
        }
        try await settleInspectorLoop(iterations: 4, slice: 0.02)
        #expect(!harness.panel.isVisible)
        #expect(harness.coordinator.inspectedCardID == nil)
        #expect(harness.panel.contentView?.subviews.isEmpty == true)
        #expect(weakHostedView2 == nil)
    }
}

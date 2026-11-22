// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import SwiftUI
import Testing
@testable import CodingRewindApp
@testable import KeyboardShortcuts

private final class LibraryWindowMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func register(suiteID: String, handler: @escaping Handler) {
        handlers.withLock { $0[suiteID] = handler }
    }

    static func unregister(suiteID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: suiteID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".librarywin.mock.local") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let suiteID = host.replacingOccurrences(of: ".librarywin.mock.local", with: "")
        guard let handler = Self.handlers.withLock({ $0[suiteID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let bodyData = Self.readBody(from: request)
        do {
            let (statusCode, data) = try handler(request, bodyData)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buf, maxLength: buf.count)
            if count <= 0 { break }
            out.append(buf, count: count)
        }
        return out
    }
}

private final class LibraryWindowMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var memos: [String: MemoWireDTO]
    private var comments: [String: [MemoWireDTO]]
    private let isoNow: String

    init(memos: [String: MemoWireDTO], comments: [String: [MemoWireDTO]] = [:], isoNow: String) {
        self.memos = memos
        self.comments = comments
        self.isoNow = isoNow
    }

    func handle(_ req: URLRequest, _ body: Data) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "GET"
        let comps = req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]

        if method == "GET" && path == "/api/memos" {
            return (200, (try? enc.encode(["memos": Array(memos.values)])) ?? Data())
        }
        if path.hasPrefix("/api/memos/") && path.hasSuffix("/comments") {
            let mid = path.replacingOccurrences(of: "/api/memos/", with: "").replacingOccurrences(of: "/comments", with: "")
            if method == "POST" {
                let cid = comps?.queryItems?.first(where: { $0.name == "commentId" })?.value ?? "rw-note-1"
                let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                let dto = MemoWireDTO(name: "memos/\(cid)", content: obj["content"] as? String ?? "", createTime: isoNow)
                comments[mid, default: []].append(dto)
                return (200, (try? enc.encode(dto)) ?? Data())
            }
            return (200, (try? enc.encode(["memos": comments[mid] ?? []])) ?? Data())
        }
        if path.hasPrefix("/api/memos/") {
            let mid = String(path.dropFirst("/api/memos/".count))
            if method == "GET", let dto = memos[mid] {
                return (200, (try? enc.encode(dto)) ?? Data())
            }
            if method == "PATCH", let existing = memos[mid],
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let content = obj["content"] as? String {
                let updated = MemoWireDTO(name: existing.name, content: content, createTime: existing.createTime)
                memos[mid] = updated
                return (200, (try? enc.encode(updated)) ?? Data())
            }
            if method == "DELETE" {
                let existed = memos.removeValue(forKey: mid) != nil
                return (existed ? 200 : 404, Data("{}".utf8))
            }
        }
        return (404, Data())
    }
}

private struct LibraryWindowUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.ioError("Unused")
    }
}

@MainActor
private func drainLibraryRunLoop(_ seconds: TimeInterval = 0.02) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func settleLibraryLoop(iterations: Int = 3, slice: TimeInterval = 0.02) async throws {
    for _ in 0..<iterations {
        try await Task.sleep(for: .milliseconds(15))
        drainLibraryRunLoop(slice)
    }
}

@MainActor
private func waitForLibraryCondition(
    timeoutIterations: Int = 100,
    condition: @MainActor () -> Bool
) async throws -> Bool {
    for _ in 0..<timeoutIterations {
        if condition() {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
        drainLibraryRunLoop(0.01)
    }
    return condition()
}

@MainActor
private func makeLibraryKeyEvent(
    windowNumber: Int,
    keyCode: UInt16,
    characters: String,
    charactersIgnoringModifiers: String? = nil,
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
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

@MainActor
private func libraryAXChildren(_ node: Any) -> [Any] {
    if let element = node as? any NSAccessibilityProtocol,
       let children = element.accessibilityChildren() {
        return children
    }
    return (node as AnyObject).accessibilityChildren?() ?? []
}

@MainActor
private func libraryAXStrings(_ node: Any) -> [String] {
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
private func hasLibraryAXText(_ substring: String, in root: Any) -> Bool {
    func walk(_ node: Any, visited: inout Set<ObjectIdentifier>) -> Bool {
        autoreleasepool {
            let object = node as AnyObject
            if !visited.insert(ObjectIdentifier(object)).inserted {
                return false
            }
            if libraryAXStrings(node).contains(where: { $0.contains(substring) }) {
                return true
            }
            for child in libraryAXChildren(node) {
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
private func firstEditableLibraryField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable {
        return field
    }
    for subview in view.subviews {
        if let match = firstEditableLibraryField(in: subview) {
            return match
        }
    }
    return nil
}

extension AppShortcutsTests {
    @Suite(.serialized)
    @MainActor
    struct LibraryWindowTests {
        nonisolated private static let suitePrefix = "dev.codingrewind.qa.library-window"

        init() {
            _ = AppShortcutsTests.defaults
        }

        private func makeTestRoot() throws -> URL {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let dir = repoRoot.appendingPathComponent(".build/test-library-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        nonisolated private static func cleanSuite(_ suiteName: String, defaults: UserDefaults? = nil) {
            defaults?.removePersistentDomain(forName: suiteName)
            _ = CFPreferencesAppSynchronize(suiteName as CFString)
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }

        private struct LibraryHarness {
            let dir: URL
            let suiteID: String
            let wasEnhancedAXEnabled: Bool
            let coordinator: AppCoordinator
            let delegate: CodingRewindAppDelegate
            let shortcuts: AppShortcuts
            let hudPanel: QuickPeekHUDPanel
            let controller: LibraryWindowController

            @MainActor
            func tearDown() {
                controller.unmountContentIfNeeded()
                controller.close()
                hudPanel.orderOut(nil)
                let setEnhancedSelector = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
                if NSApplication.shared.responds(to: setEnhancedSelector) {
                    _ = NSApplication.shared.perform(setEnhancedSelector, with: NSNumber(value: wasEnhancedAXEnabled))
                }
                shortcuts.stop()
                NSApplication.shared.mainMenu = nil
                LibraryWindowMockURLProtocol.unregister(suiteID: suiteID)
                try? FileManager.default.removeItem(at: dir)
            }
        }

        private func makeHarness(
            server: LibraryWindowMockServer,
            language: AppLanguage = .zhHans
        ) throws -> LibraryHarness {
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

            let dir = try makeTestRoot()
            let suiteID = UUID().uuidString.lowercased()

            LibraryWindowMockURLProtocol.register(suiteID: suiteID) { req, body in
                server.handle(req, body)
            }

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [LibraryWindowMockURLProtocol.self]
            let client = MemosClient(session: URLSession(configuration: config))

            let paths = try StoragePaths(
                dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
                antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
            )
            let env: [String: String] = [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
                StoragePaths.memosURLEnvironmentKey: "https://\(suiteID).librarywin.mock.local",
                StoragePaths.memosTokenEnvironmentKey: "qa-library-token"
            ]
            let coordinator = try AppCoordinator(
                paths: paths,
                environment: env,
                memosClient: client,
                capturer: LibraryWindowUnusedCapturer(),
                language: language
            )
            let delegate = CodingRewindAppDelegate()
            delegate.coordinator = coordinator
            let shortcuts = AppShortcuts(language: language) { delegate.perform($0) }
            let hudPanel = QuickPeekHUDPanel(coordinator: coordinator, shortcuts: shortcuts) { delegate.perform($0) }
            let controller = LibraryWindowController(
                coordinator: coordinator,
                language: language,
                onCommand: { delegate.perform($0) }
            )
            delegate.hudPanel = hudPanel
            delegate.libraryWindowController = controller

            return LibraryHarness(
                dir: dir,
                suiteID: suiteID,
                wasEnhancedAXEnabled: wasEnhancedAXEnabled,
                coordinator: coordinator,
                delegate: delegate,
                shortcuts: shortcuts,
                hudPanel: hudPanel,
                controller: controller
            )
        }

        private func makeSeededServer(now: Date = Date()) throws -> (
            server: LibraryWindowMockServer,
            projectRef: PlaceRef,
            topicRef: PlaceRef
        ) {
            let projectRef = try #require(PlaceRef(tag: "project/paper-02"))
            let topicRef = try #require(PlaceRef(tag: "topic/swift"))
            let projectPlace = PlaceRecord(ref: projectRef, title: "Paper 02", aliases: ["论文02", "embodiment"])
            let topicPlace = PlaceRecord(ref: topicRef, title: "Swift Concurrency", aliases: ["actor"])

            let nowISO = MemosWireFormat.formatISO8601UTC(now)
            let hotChatISO = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-1800))
            let hotGemISO = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-3600))
            let oldAGISO = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-5 * 86400))
            let oldGemISO = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-8 * 86400))
            let archivedISO = MemosWireFormat.formatISO8601UTC(now.addingTimeInterval(-12 * 86400))

            let memos: [String: MemoWireDTO] = [
                "pl-p-paper-02": MemoWireDTO(
                    name: "memos/pl-p-paper-02",
                    content: MemosWireFormat.formatPlaceMemo(projectPlace),
                    createTime: oldGemISO
                ),
                "pl-t-swift": MemoWireDTO(
                    name: "memos/pl-t-swift",
                    content: MemosWireFormat.formatPlaceMemo(topicPlace),
                    createTime: oldGemISO
                ),
                "clip-hot-chatgpt": MemoWireDTO(
                    name: "memos/clip-hot-chatgpt",
                    content: "#rewind/ready #source/chatgpt\n\n> **Title:** ChatGPT Hot Unplaced\n> **Source:** [ChatGPT](https://chatgpt.com/c/sess-shared) · \(hotChatISO)\n\nHot ChatGPT excerpt inheriting session place.",
                    createTime: hotChatISO
                ),
                "clip-hot-gemini": MemoWireDTO(
                    name: "memos/clip-hot-gemini",
                    content: "#rewind/ready #source/gemini\n\n> **Title:** Gemini Hot Unplaced\n> **Keywords:** actor\n> **Source:** [Gemini](https://gemini.google.com/app/gem-1) · \(hotGemISO)\n\nHot Gemini excerpt discussing actor isolation.",
                    createTime: hotGemISO
                ),
                "clip-old-ag": MemoWireDTO(
                    name: "memos/clip-old-ag",
                    content: "#rewind/ready #source/antigravity #project/paper-02\n\n> **Title:** Older AG Placed\n> **Source:** [Antigravity](conversation://ag-sess-99) · \(oldAGISO)\n\nOlder >72h Antigravity design note.",
                    createTime: oldAGISO
                ),
                "clip-old-gemini": MemoWireDTO(
                    name: "memos/clip-old-gemini",
                    content: "#rewind/ready #source/gemini #project/paper-02\n\n> **Title:** Older Gemini Placed\n> **Source:** [Gemini](https://gemini.google.com/app/sess-shared-gem) · \(oldGemISO)\n\nOlder >72h Gemini reference.",
                    createTime: oldGemISO
                ),
                "clip-old-chatgpt-placed": MemoWireDTO(
                    name: "memos/clip-old-chatgpt-placed",
                    content: "#rewind/ready #source/chatgpt #project/paper-02\n\n> **Title:** ChatGPT Session Anchor\n> **Source:** [ChatGPT](https://chatgpt.com/c/sess-shared) · \(oldAGISO)\n\nPlaced sibling in shared ChatGPT session.",
                    createTime: oldAGISO
                ),
                "clip-archived-ag": MemoWireDTO(
                    name: "memos/clip-archived-ag",
                    content: "#rewind/synthesized #source/antigravity #topic/swift\n\n> **Title:** Archived AG Summary\n> **Source:** [Antigravity](conversation://ag-arch-1) · \(archivedISO)\n\nArchived Antigravity snippet.",
                    createTime: archivedISO
                )
            ]

            let server = LibraryWindowMockServer(memos: memos, isoNow: nowISO)
            return (server, projectRef, topicRef)
        }

        @Test("Window lifecycle mounts lazily, sets minSize, clears non-text firstResponder, and unmounts on orderOut/close")
        func windowLifecycleAndOffscreenUnmount() async throws {
            let seeded = try makeSeededServer()
            let harness = try makeHarness(server: seeded.server, language: .zhHans)
            defer { harness.tearDown() }

            let window = try #require(harness.controller.window)
            #expect(harness.controller.isContentMounted == false)
            #expect(window.contentView?.subviews.isEmpty == true)
            #expect(window.minSize == NSSize(width: 980, height: 640))

            harness.controller.presentAndFocus()
            try await settleLibraryLoop()
            #expect(harness.controller.isContentMounted == true)
            #expect(window.isVisible)
            #expect(window.contentView is NSHostingView<LibrarySplitRootView>)
            #expect(!(window.firstResponder is NSTextView))
            #expect(window.firstResponder == nil || window.firstResponder === window)

            window.orderOut(nil)
            try await settleLibraryLoop()
            #expect(harness.controller.isContentMounted == false)
            #expect(!window.isVisible)
            #expect(window.contentView?.subviews.isEmpty == true)

            harness.controller.presentAndFocus()
            try await settleLibraryLoop()
            #expect(harness.controller.isContentMounted == true)
            #expect(window.isVisible)

            window.close()
            try await settleLibraryLoop()
            #expect(harness.controller.isContentMounted == false)
            #expect(!window.isVisible)

            harness.controller.presentAndFocus()
            try await settleLibraryLoop()
            #expect(harness.controller.isContentMounted == true)
            #expect(window.isVisible)
        }

        @Test("Three-pane scope switching updates visibleItems and preserves non-nil inspectedItem across all non-empty scopes")
        func threePaneScopeAndInspectorContinuity() async throws {
            let seeded = try makeSeededServer()
            let harness = try makeHarness(server: seeded.server, language: .en)
            defer { harness.tearDown() }

            await harness.coordinator.refreshLibraryWorkspace()
            harness.controller.presentAndFocus()
            try await settleLibraryLoop()

            let expectedCounts: [(LibraryScope, [String])] = [
                (.all, ["clip-hot-chatgpt", "clip-hot-gemini", "clip-old-ag", "clip-old-chatgpt-placed", "clip-old-gemini"]),
                (.unplacedInbox, ["clip-hot-chatgpt", "clip-hot-gemini"]),
                (.hot72Hours, ["clip-hot-chatgpt", "clip-hot-gemini"]),
                (.source(.geminiWeb), ["clip-hot-gemini", "clip-old-gemini"]),
                (.source(.antigravity), ["clip-old-ag"]),
                (.source(.chatGPTApp), ["clip-hot-chatgpt", "clip-old-chatgpt-placed"]),
                (.place(seeded.projectRef), ["clip-old-ag", "clip-old-chatgpt-placed", "clip-old-gemini"]),
                (.archived, ["clip-archived-ag"])
            ]

            for (scope, expectedIDs) in expectedCounts {
                await harness.coordinator.handleLibraryIntent(.selectScope(scope))
                try await settleLibraryLoop(iterations: 2, slice: 0.01)
                let projection = harness.coordinator.libraryProjection
                #expect(Set(projection.visibleItems.map(\.id)) == Set(expectedIDs))
                #expect(projection.visibleItems.count == expectedIDs.count)
                #expect(projection.inspectedItem != nil)
            }
        }

        @Test("Layout switching, keyboard shortcuts, closed-vocabulary inbox triage, and NSTextView guard")
        func layoutSwitchingAndKeyboardShortcuts() async throws {
            let seeded = try makeSeededServer()
            let harness = try makeHarness(server: seeded.server, language: .en)
            defer { harness.tearDown() }

            await harness.coordinator.refreshLibraryWorkspace()
            harness.controller.presentAndFocus()
            try await settleLibraryLoop()

            let window = try #require(harness.controller.window)
            #expect(harness.coordinator.libraryLayoutMode == .bentoCards)
            #expect(harness.coordinator.isLibraryInspectorPresented == true)

            let opt2 = try makeLibraryKeyEvent(
                windowNumber: window.windowNumber,
                keyCode: 19,
                characters: "2",
                charactersIgnoringModifiers: "2",
                modifiers: [.option]
            )
            #expect(autoreleasepool { window.performKeyEquivalent(with: opt2) })
            #expect(try await waitForLibraryCondition { harness.coordinator.libraryLayoutMode == .sessionTimeline })

            let opt1 = try makeLibraryKeyEvent(
                windowNumber: window.windowNumber,
                keyCode: 18,
                characters: "1",
                charactersIgnoringModifiers: "1",
                modifiers: [.option]
            )
            #expect(autoreleasepool { window.performKeyEquivalent(with: opt1) })
            #expect(try await waitForLibraryCondition { harness.coordinator.libraryLayoutMode == .bentoCards })

            let cmdI = try makeLibraryKeyEvent(
                windowNumber: window.windowNumber,
                keyCode: 34,
                characters: "i",
                charactersIgnoringModifiers: "i",
                modifiers: [.command]
            )
            #expect(autoreleasepool { window.performKeyEquivalent(with: cmdI) })
            #expect(harness.coordinator.isLibraryInspectorPresented == false)
            #expect(autoreleasepool { window.performKeyEquivalent(with: cmdI) })
            #expect(harness.coordinator.isLibraryInspectorPresented == true)

            let visibleAllIDs = harness.coordinator.libraryProjection.visibleItems.map(\.id)
            #expect(visibleAllIDs.count >= 2)
            #expect(harness.coordinator.libraryProjection.inspectedItem?.id == visibleAllIDs[0])

            let keyJ = try makeLibraryKeyEvent(windowNumber: window.windowNumber, keyCode: 38, characters: "j")
            let keyK = try makeLibraryKeyEvent(windowNumber: window.windowNumber, keyCode: 40, characters: "k")
            autoreleasepool { window.keyDown(with: keyJ) }
            #expect(try await waitForLibraryCondition { harness.coordinator.libraryFocusedClipID == visibleAllIDs[1] })
            autoreleasepool { window.keyDown(with: keyK) }
            #expect(try await waitForLibraryCondition { harness.coordinator.libraryFocusedClipID == visibleAllIDs[0] })

            await harness.coordinator.handleLibraryIntent(.selectScope(.unplacedInbox))
            try await settleLibraryLoop()
            let inboxBefore = harness.coordinator.libraryProjection
            #expect(inboxBefore.visibleItems.map(\.id) == ["clip-hot-chatgpt", "clip-hot-gemini"])
            #expect(inboxBefore.inspectedItem?.id == "clip-hot-chatgpt")
            #expect(inboxBefore.inspectedItem?.suggestedPlaces.first?.place.ref == seeded.projectRef)
            #expect(harness.coordinator.triagedInSessionCount == 0)

            let key1 = try makeLibraryKeyEvent(windowNumber: window.windowNumber, keyCode: 18, characters: "1")
            autoreleasepool { window.keyDown(with: key1) }
            #expect(try await waitForLibraryCondition {
                harness.coordinator.triagedInSessionCount == 1
                    && harness.coordinator.libraryProjection.visibleItems.map(\.id) == ["clip-hot-gemini"]
            })

            await harness.coordinator.handleLibraryIntent(.focusClip("clip-hot-gemini"))
            try await settleLibraryLoop(iterations: 2, slice: 0.01)
            #expect(harness.coordinator.libraryProjection.inspectedItem?.suggestedPlaces.first?.place.ref == seeded.topicRef)

            let returnKey = try makeLibraryKeyEvent(windowNumber: window.windowNumber, keyCode: 36, characters: "\r")
            autoreleasepool { window.keyDown(with: returnKey) }
            #expect(try await waitForLibraryCondition {
                harness.coordinator.triagedInSessionCount == 2
                    && harness.coordinator.libraryProjection.visibleItems.isEmpty
            })

            await harness.coordinator.handleLibraryIntent(.selectScope(.all))
            try await settleLibraryLoop()
            let allIDsBeforeTextFocus = harness.coordinator.libraryProjection.visibleItems.map(\.id)
            #expect(allIDsBeforeTextFocus.count >= 2)
            await harness.coordinator.handleLibraryIntent(.focusClip(allIDsBeforeTextFocus[0]))

            let contentView = try #require(window.contentView)
            if let field = firstEditableLibraryField(in: contentView) {
                _ = window.makeFirstResponder(field)
                drainLibraryRunLoop(0.03)
            }
            if !(window.firstResponder is NSTextView) {
                let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
                contentView.addSubview(textView)
                _ = window.makeFirstResponder(textView)
                drainLibraryRunLoop(0.02)
            }
            #expect(window.firstResponder is NSTextView)

            let focusedBefore = harness.coordinator.libraryFocusedClipID
            let triagedBefore = harness.coordinator.triagedInSessionCount
            autoreleasepool {
                window.keyDown(with: keyJ)
                window.keyDown(with: keyK)
                window.keyDown(with: key1)
            }
            try await settleLibraryLoop(iterations: 2, slice: 0.01)
            #expect(harness.coordinator.libraryFocusedClipID == focusedBefore)
            #expect(harness.coordinator.triagedInSessionCount == triagedBefore)
        }

        @Test("Live language switching relocalizes window title and labels while Dock reopen opens Library independently of HUD")
        func liveLanguageSwitchingAndDockReopen() async throws {
            let seeded = try makeSeededServer()
            let harness = try makeHarness(server: seeded.server, language: .zhHans)
            defer { harness.tearDown() }

            await harness.coordinator.refreshLibraryWorkspace()
            let appearanceSuite = "dev.codingrewind.qa.shortcuts.library-window"
            let defaults = try #require(UserDefaults(suiteName: appearanceSuite))
            Self.cleanSuite(appearanceSuite, defaults: defaults)
            defer { Self.cleanSuite(appearanceSuite, defaults: defaults) }
            let appearance = AppAppearancePreferences(
                defaults: defaults,
                applyPolicy: { _ in true },
                preferredLanguagesProvider: { ["zh-Hans-CN"] }
            )
            appearance.onEffectiveLanguageChange = { [weak coordinator = harness.coordinator, weak controller = harness.controller, weak shortcuts = harness.shortcuts] lang in
                coordinator?.setLanguage(lang)
                shortcuts?.language = lang
                controller?.updateLanguage(lang)
            }

            let window = try #require(harness.controller.window)
            #expect(window.title == "Coding Rewind 资料库")
            #expect(AppStrings.libraryLayoutTitle(.bentoCards, in: harness.coordinator.language) == "卡片墙")

            harness.controller.presentAndFocus()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(try await waitForLibraryCondition {
                hasLibraryAXText("全部片段", in: window)
            })

            appearance.setLanguagePreference(.en)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(harness.coordinator.language == .en)
            #expect(window.title == "Coding Rewind Library")
            #expect(AppStrings.libraryLayoutTitle(.bentoCards, in: harness.coordinator.language) == "Cards")
            #expect(AppStrings.libraryLayoutTitle(.sessionTimeline, in: harness.coordinator.language) == "Sessions")
            #expect(AppStrings.libraryScopeTitle(.all, placeTitle: { harness.coordinator.placeTitle(for: $0) }, in: .en) == "All Clips")
            #expect(try await waitForLibraryCondition {
                hasLibraryAXText("All Clips", in: window)
            })

            window.close()
            try await settleLibraryLoop()
            #expect(!window.isVisible)
            #expect(!harness.hudPanel.isVisible)

            let reopened = harness.delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
            #expect(reopened == true)
            #expect(try await waitForLibraryCondition {
                window.isVisible && harness.controller.isContentMounted
            })
            #expect(!harness.hudPanel.isVisible)

            #expect(ShortcutAction.toggleHUD.command == .toggleHUD)
            harness.delegate.perform(.toggleHUD)
            try await settleLibraryLoop()
            #expect(harness.hudPanel.isVisible)
            #expect(window.isVisible)

            harness.delegate.perform(.toggleHUD)
            try await settleLibraryLoop()
            #expect(!harness.hudPanel.isVisible)
            #expect(window.isVisible)
        }

        @Test("Related clips merge handoff stages hot and >72h clips into in-place draft without popping HUD")
        func relatedClipsMergeHandoff() async throws {
            let seeded = try makeSeededServer()
            let harness = try makeHarness(server: seeded.server, language: .en)
            defer { harness.tearDown() }

            await harness.coordinator.refreshLibraryWorkspace()
            harness.controller.presentAndFocus()
            try await settleLibraryLoop()

            let window = try #require(harness.controller.window)
            #expect(window.isVisible)
            #expect(!harness.hudPanel.isVisible)

            let clipIDs = ["clip-hot-chatgpt", "clip-old-ag"]
            await harness.coordinator.handleLibraryIntent(.stageAndOpenHandoff(clipIDs: clipIDs))
            try await settleLibraryLoop()

            #expect(harness.coordinator.checkedCardIDs == Set(clipIDs))
            let draft = try #require(harness.coordinator.conversationDraft)
            #expect(Set(draft.cardIDs) == Set(clipIDs))
            #expect(draft.text.contains("clip-hot-chatgpt"))
            #expect(draft.text.contains("clip-old-ag"))
            #expect(draft.text.contains("Hot ChatGPT excerpt inheriting session place."))
            #expect(draft.text.contains("Older >72h Antigravity design note."))
            #expect(!harness.hudPanel.isVisible)
            #expect(window.isVisible)

            harness.delegate.perform(.launchConversation)
            try await settleLibraryLoop()
            #expect(!harness.hudPanel.isVisible)
            #expect(window.isVisible)
        }
    }
}

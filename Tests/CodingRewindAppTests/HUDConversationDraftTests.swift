// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import Testing
@testable import CodingRewindApp

@MainActor
private func drainDraftRunLoop(_ seconds: TimeInterval = 0.02) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func settleDraftLoop(iterations: Int = 3, slice: TimeInterval = 0.02) async throws {
    for _ in 0..<iterations {
        try await Task.sleep(for: .milliseconds(15))
        drainDraftRunLoop(slice)
    }
}

@MainActor
private func draftAXChildren(_ node: Any) -> [Any] {
    if let element = node as? any NSAccessibilityProtocol,
       let children = element.accessibilityChildren() {
        return children
    }
    return (node as AnyObject).accessibilityChildren?() ?? []
}

@MainActor
private func draftAXIdentifier(_ node: Any) -> String? {
    if let element = node as? any NSAccessibilityProtocol {
        return element.accessibilityIdentifier()
    }
    return (node as AnyObject).accessibilityIdentifier?()
}

@MainActor
private func findDraftAXElement(
    identifier: String,
    in root: Any,
    visited: inout Set<ObjectIdentifier>
) -> Any? {
    autoreleasepool {
        let object = root as AnyObject
        if !visited.insert(ObjectIdentifier(object)).inserted {
            return nil
        }
        if draftAXIdentifier(root) == identifier {
            return root
        }
        for child in draftAXChildren(root) {
            if let match = findDraftAXElement(identifier: identifier, in: child, visited: &visited) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func draftAXLabel(_ identifier: String, in root: Any) -> String? {
    var visited: Set<ObjectIdentifier> = []
    guard let element = findDraftAXElement(identifier: identifier, in: root, visited: &visited) else {
        return nil
    }
    if let ax = element as? any NSAccessibilityProtocol {
        if let label = ax.accessibilityLabel(), !label.isEmpty { return label }
        if let title = ax.accessibilityTitle(), !title.isEmpty { return title }
        return nil
    }
    let obj = element as AnyObject
    if let label = obj.accessibilityLabel?(), !label.isEmpty { return label }
    if let title = obj.accessibilityTitle?(), !title.isEmpty { return title }
    return nil
}

@MainActor
private func hasDraftAXIdentifier(_ identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return findDraftAXElement(identifier: identifier, in: root, visited: &visited) != nil
}

@MainActor
private func isDraftAXEnabled(_ identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    guard let element = findDraftAXElement(identifier: identifier, in: root, visited: &visited) else {
        return false
    }
    if let ax = element as? any NSAccessibilityProtocol {
        return ax.isAccessibilityEnabled()
    }
    return (element as AnyObject).isAccessibilityEnabled?() ?? true
}

@MainActor
@discardableResult
private func pressDraftAXButton(_ identifier: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    guard let element = findDraftAXElement(identifier: identifier, in: root, visited: &visited) else {
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
private func findDraftTextView(in view: NSView) -> DraftPromptTextView? {
    if let tv = view as? DraftPromptTextView {
        return tv
    }
    for sub in view.subviews {
        if let found = findDraftTextView(in: sub) {
            return found
        }
    }
    return nil
}

@MainActor
private func makeDraftKeyEvent(
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

private struct DraftUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.emptySelection
    }
}

extension AppShortcutsTests {
    @Test("Continue-conversation opens editable HUD draft box first, supports Esc back to list, Copy & Wake primary action, and Direct Send secondary action")
    func hudConversationDraftComposerFlowEscCopyWakeAndDirectSend() async throws {
        let getEnhanced = Selector(("accessibilityEnhancedUserInterfaceAttribute"))
        let setEnhanced = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
        let wasEnhanced = (NSApplication.shared.responds(to: getEnhanced)
            ? (NSApplication.shared.perform(getEnhanced)?.takeUnretainedValue() as? NSNumber)?.boolValue
            : nil) ?? false
        if NSApplication.shared.responds(to: setEnhanced) {
            _ = NSApplication.shared.perform(setEnhanced, with: NSNumber(value: true))
        }

        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/hud-draft-\(UUID().uuidString.lowercased())", isDirectory: true)
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        let env: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]

        let card1 = try #require(MemosWireFormat.parseMemo(
            id: "rw-draft-1",
            rawContent: "#rewind/ready #source/antigravity\n\n> **Title:** First Clip\n> **Source:** [Antigravity](conversation://11111111-2222-3333-4444-555555555555) · 2026-11-17T08:00:00Z\n\nFirst verbatim snippet",
            createdAt: Date()
        ))
        let card2 = try #require(MemosWireFormat.parseMemo(
            id: "rw-draft-2",
            rawContent: "#rewind/ready #source/web\n\n> **Title:** Second Clip\n> **Source:** [Docs](https://example.com/docs) · 2026-11-17T08:01:00Z\n\nSecond verbatim snippet",
            createdAt: Date().addingTimeInterval(-30)
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card1, card2])

        let deliveredDSHPrompts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let deliveredThreadID = UUID().uuidString.lowercased()
        let coord = try AppCoordinator(
            paths: paths,
            environment: env,
            capturer: DraftUnusedCapturer(),
            language: .zhHans,
            dshReadinessCheck: { true }
        )

        @MainActor final class HostGate { var shouldSucceed = true }
        let hostGate = HostGate()
        var copiedTexts: [String] = []
        var activatedHosts: [ConversationHost] = []
        coord.onCopyText = { copiedTexts.append($0) }
        coord.onActivateHostApp = { host in
            activatedHosts.append(host)
            return hostGate.shouldSucceed
        }
        coord.onWakeHost = { host in
            guard host == .dsh else { return }
            let dshStore = coord.handoffStore(for: .dsh)
            Task.detached {
                if let worker = try? ConversationSidecarWorker.acquireIfUnlocked(store: dshStore) {
                    try? worker.processPending { request in
                        deliveredDSHPrompts.withLock { $0.append(request.prompt) }
                        return (.succeeded, deliveredThreadID)
                    }
                }
            }
        }
        coord.onOpenConversation = { _ in true }

        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord
        let shortcuts = AppShortcuts(language: .zhHans) { delegate.perform($0) }
        let panel = QuickPeekHUDPanel(coordinator: coord, shortcuts: shortcuts) { delegate.perform($0) }
        delegate.hudPanel = panel
        defer {
            panel.orderOut(nil)
            shortcuts.stop()
            if NSApplication.shared.responds(to: setEnhanced) {
                _ = NSApplication.shared.perform(setEnhanced, with: NSNumber(value: wasEnhanced))
            }
            try? FileManager.default.removeItem(at: dir)
        }

        // 1. Present HUD, check two cards, press ⌘Return -> opens editable draft box, does NOT send to host
        panel.presentAndFocus()
        try await settleDraftLoop()
        coord.checkedCardIDs = [card1.id, card2.id]
        try await settleDraftLoop()

        let cmdReturn = try makeDraftKeyEvent(
            windowNumber: panel.windowNumber,
            keyCode: 36,
            characters: "\r",
            modifiers: [.command]
        )
        #expect(panel.performKeyEquivalent(with: cmdReturn))
        try await settleDraftLoop()

        #expect(coord.conversationDraft != nil)
        #expect(coord.conversationDraft?.isEdited == false)
        #expect(coord.conversationDraft?.text.contains("rw-draft-1") == true)
        #expect(coord.conversationDraft?.text.contains("First verbatim snippet") == true)
        #expect(coord.conversationDraft?.text.contains("Second verbatim snippet") == true)
        #expect(try coord.handoffStore(for: .antigravity).current() == nil)
        #expect(try coord.handoffStore(for: .dsh).current() == nil)
        #expect(activatedHosts.isEmpty)
        #expect(copiedTexts.isEmpty)
        #expect(hasDraftAXIdentifier("hud.draft.container", in: panel))
        #expect(hasDraftAXIdentifier("hud.draft.copyAndWake", in: panel))
        #expect(hasDraftAXIdentifier("hud.draft.sendDirect", in: panel))
        #expect(draftAXLabel("hud.draft.copyAndWake", in: panel) == "复制并唤醒 Antigravity")
        #expect(draftAXLabel("hud.draft.sendDirect", in: panel) == "直接新建对话")
        #expect(draftAXLabel("hud.draft.archiveOnLaunch", in: panel) == "发送后归档")
        #expect(!hasDraftAXIdentifier("hud.launch", in: panel))

        let contentView = try #require(panel.contentView)
        let textView = try #require(findDraftTextView(in: contentView))
        #expect(!textView.isRichText)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(panel.firstResponder === textView)

        // 2. Unedited draft refreshes dynamically on language switch, but preserves edits once modified
        coord.setLanguage(.en)
        #expect(coord.conversationDraft?.text.contains("### Clip 1:") == true)
        coord.setLanguage(.zhHans)
        #expect(coord.conversationDraft?.text.contains("### 卡片 1：") == true)

        // 3. Esc inside draft editor returns to card list WITHOUT closing HUD or clearing checked cards
        let escEvent = try makeDraftKeyEvent(windowNumber: panel.windowNumber, keyCode: 53, characters: "\u{1B}")
        panel.sendEvent(escEvent)
        try await settleDraftLoop()

        #expect(coord.conversationDraft == nil)
        #expect(panel.isVisible)
        #expect(coord.checkedCardIDs == [card1.id, card2.id])
        #expect(hasDraftAXIdentifier("hud.launch", in: panel))

        // 4. Reopen via hud.launch button, edit text, verify Reset restores default, then edit again & press ⌘Return to Copy & Wake Antigravity
        #expect(pressDraftAXButton("hud.launch", in: panel))
        try await settleDraftLoop()
        #expect(coord.conversationDraft != nil)

        let customDraft = "自定义开场指令：只比较两段摘录的并发差异。\n\n" + (coord.conversationDraft?.text ?? "")
        coord.updateConversationDraftText(customDraft)
        try await settleDraftLoop()
        #expect(coord.conversationDraft?.isEdited == true)
        #expect(hasDraftAXIdentifier("hud.draft.reset", in: panel))

        // Switching language while edited must NOT clobber user's custom draft
        coord.setLanguage(.en)
        #expect(coord.conversationDraft?.text == customDraft)
        coord.setLanguage(.zhHans)

        // Reset restores unedited prompt
        #expect(pressDraftAXButton("hud.draft.reset", in: panel))
        try await settleDraftLoop()
        #expect(coord.conversationDraft?.isEdited == false)
        #expect(coord.conversationDraft?.text.contains("自定义开场指令") == false)

        // Apply user edit and trigger Primary Action via ⌘Return -> copies edited text, wakes Antigravity, orders out HUD, sends zero handoff
        coord.updateConversationDraftText(customDraft)
        try await settleDraftLoop()
        #expect(panel.performKeyEquivalent(with: cmdReturn))
        try await settleDraftLoop()

        #expect(copiedTexts == [customDraft])
        #expect(activatedHosts == [.antigravity])
        #expect(!panel.isVisible)
        #expect(coord.conversationDraft == nil)
        #expect(coord.checkedCardIDs == [card1.id, card2.id])
        #expect(try coord.handoffStore(for: .antigravity).current() == nil)
        #expect(coord.isErrorBanner == false)
        #expect(coord.bannerMessage?.contains("Antigravity") == true)

        // 5. Empty/whitespace draft disables both actions and rejects copy/send; unavailable host still copies draft and keeps HUD open with warning
        panel.presentAndFocus()
        #expect(coord.openConversationDraft())
        try await settleDraftLoop()
        coord.updateConversationDraftText("   \n\t  ")
        try await settleDraftLoop()
        #expect(!isDraftAXEnabled("hud.draft.copyAndWake", in: panel))
        #expect(!isDraftAXEnabled("hud.draft.sendDirect", in: panel))
        #expect(coord.copyConversationDraftAndWakeHost() == false)
        #expect(coord.isErrorBanner)
        #expect(await coord.sendConversationDraft(waitSeconds: 0) == nil)

        hostGate.shouldSucceed = false
        let fallbackDraft = "Fallback manual paste prompt"
        coord.updateConversationDraftText(fallbackDraft)
        delegate.perform(.copyDraftAndWakeHost)
        try await settleDraftLoop()
        #expect(copiedTexts.last == fallbackDraft)
        #expect(panel.isVisible)
        #expect(coord.isErrorBanner)

        hostGate.shouldSucceed = true
        #expect(coord.openConversationDraft(in: .antigravity))
        let directEditedPrompt = "Direct handoff edited prompt — verify exact bytes"
        coord.updateConversationDraftText(directEditedPrompt)
        try await settleDraftLoop()

        #expect(pressDraftAXButton("hud.draft.sendDirect", in: panel))
        try await settleDraftLoop(iterations: 6)
        #expect(coord.isErrorBanner)
        #expect(coord.conversationDraft?.text == directEditedPrompt)
        #expect(coord.conversationDraft?.isEdited == true)

        coord.selectConversationDraftHost(.dsh)
        try await settleDraftLoop()
        #expect(draftAXLabel("hud.draft.sendDirect", in: panel) == "填入 DSH 新会话")
        #expect(draftAXLabel("hud.draft.copyAndWake", in: panel) == "复制并唤醒 DSH")
        #expect(draftAXLabel("hud.draft.archiveOnLaunch", in: panel) == "填入后归档")

        coord.setLanguage(.en)
        try await settleDraftLoop()
        #expect(draftAXLabel("hud.draft.sendDirect", in: panel) == "Fill New DSH Chat")
        #expect(draftAXLabel("hud.draft.copyAndWake", in: panel) == "Copy & Wake DSH")
        #expect(draftAXLabel("hud.draft.archiveOnLaunch", in: panel) == "Archive after filling")
        coord.setLanguage(.zhHans)
        try await settleDraftLoop()

        let copiedBeforeDSHPrimary = copiedTexts.count
        #expect(panel.performKeyEquivalent(with: cmdReturn))
        for _ in 0..<60 where coord.confirmedConversation == nil {
            try await Task.sleep(for: .milliseconds(15))
            drainDraftRunLoop(0.01)
        }
        #expect(copiedTexts.count == copiedBeforeDSHPrimary)
        #expect(deliveredDSHPrompts.withLock { $0 } == [directEditedPrompt])
        #expect(coord.confirmedConversation == ConversationReference(host: .dsh, id: deliveredThreadID))
        #expect(coord.conversationDraft == nil)
        #expect(coord.checkedCardIDs.isEmpty)
        #expect(!coord.isErrorBanner)

        coord.conversationHost = .antigravity

        // 7. Uncommitted IME marked text in DraftPromptTextView: pressing Esc ONLY discards marked text (does NOT close HUD or dismiss draft), and button click commits marked text
        panel.presentAndFocus()
        coord.checkedCardIDs = [card1.id]
        #expect(coord.openConversationDraft())
        try await settleDraftLoop()
        let baseUneditedPrompt = try #require(coord.conversationDraft?.text)
        let imeRoot = try #require(panel.contentView)
        let imeTextView = try #require(findDraftTextView(in: imeRoot))
        imeTextView.setSelectedRange(NSRange(location: 0, length: 0))
        imeTextView.setMarkedText("【未提交拼音】", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(imeTextView.hasMarkedText())

        let imeEsc = try makeDraftKeyEvent(windowNumber: panel.windowNumber, keyCode: 53, characters: "\u{1B}")
        #expect(panel.performKeyEquivalent(with: imeEsc) == false)
        panel.sendEvent(imeEsc)
        try await settleDraftLoop()
        #expect(panel.isVisible)
        #expect(coord.conversationDraft != nil)
        #expect(!imeTextView.hasMarkedText())
        #expect(imeTextView.string == baseUneditedPrompt)
        #expect(coord.conversationDraft?.text == baseUneditedPrompt)

        imeTextView.setSelectedRange(NSRange(location: 0, length: 0))
        imeTextView.setMarkedText("【未提交拼音】", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(imeTextView.hasMarkedText())
        #expect(pressDraftAXButton("hud.draft.copyAndWake", in: panel))
        try await settleDraftLoop()
        #expect(copiedTexts.last?.hasPrefix("【未提交拼音】") == true)

        // 8. Edited draft survives Esc / HUD hide for same selection, resets cleanly on new selection, supports ⌘A/⌘Z/⇧⌘Z without mainMenu, and never crashes on Reset -> ⌘Z
        let previousMainMenu = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = nil
        defer { NSApplication.shared.mainMenu = previousMainMenu }

        panel.presentAndFocus()
        coord.checkedCardIDs = [card1.id]
        #expect(coord.openConversationDraft())
        try await settleDraftLoop()
        let editorForUndo = try #require(panel.contentView.flatMap(findDraftTextView))
        #expect(panel.makeFirstResponder(editorForUndo))
        let originalSinglePrompt = editorForUndo.string
        let endLocation = (originalSinglePrompt as NSString).length
        editorForUndo.setSelectedRange(NSRange(location: endLocation, length: 0))
        editorForUndo.insertText("\n\n补充尾部要求：检查并发边界。", replacementRange: NSRange(location: endLocation, length: 0))
        try await settleDraftLoop()
        let typedDraft = editorForUndo.string
        #expect(coord.conversationDraft?.isEdited == true)
        #expect(coord.conversationDraft?.text == typedDraft)

        let cmdA = try makeDraftKeyEvent(windowNumber: panel.windowNumber, keyCode: 0, characters: "a", modifiers: [.command])
        #expect(panel.performKeyEquivalent(with: cmdA))
        #expect(editorForUndo.selectedRange().length == (typedDraft as NSString).length)

        let cmdZ = try makeDraftKeyEvent(windowNumber: panel.windowNumber, keyCode: 6, characters: "z", modifiers: [.command])
        #expect(panel.performKeyEquivalent(with: cmdZ))
        try await settleDraftLoop()
        #expect(coord.conversationDraft?.text == originalSinglePrompt)

        let shiftCmdZ = try makeDraftKeyEvent(windowNumber: panel.windowNumber, keyCode: 6, characters: "z", modifiers: [.command, .shift])
        #expect(panel.performKeyEquivalent(with: shiftCmdZ))
        try await settleDraftLoop()
        #expect(coord.conversationDraft?.text == typedDraft)

        // Esc back to list AND panel.orderOut preserve unsent user edits for the same card selection
        panel.sendEvent(escEvent)
        try await settleDraftLoop()
        #expect(coord.conversationDraft == nil)
        #expect(coord.openConversationDraft())
        #expect(coord.conversationDraft?.isEdited == true)
        #expect(coord.conversationDraft?.text == typedDraft)

        panel.orderOut(nil)
        try await settleDraftLoop()
        #expect(coord.conversationDraft == nil)
        panel.presentAndFocus()
        #expect(coord.openConversationDraft())
        try await settleDraftLoop()
        #expect(coord.conversationDraft?.isEdited == true)
        #expect(coord.conversationDraft?.text == typedDraft)

        // Menu .launchConversation while draft is open brings HUD forward & keeps draft open instead of prematurely copying/closing
        panel.orderOut(nil)
        #expect(coord.openConversationDraft())
        let copiedCountBeforeMenu = copiedTexts.count
        delegate.perform(.launchConversation)
        try await settleDraftLoop()
        #expect(panel.isVisible)
        #expect(coord.conversationDraft?.text == typedDraft)
        #expect(copiedTexts.count == copiedCountBeforeMenu)

        // Reset shrinking textStorage followed by ⌘Z must NOT throw NSRangeException
        let resetEditor = try #require(panel.contentView.flatMap(findDraftTextView))
        let resetEnd = (resetEditor.string as NSString).length
        resetEditor.setSelectedRange(NSRange(location: resetEnd, length: 0))
        resetEditor.insertText(String(repeating: "X", count: 120), replacementRange: NSRange(location: resetEnd, length: 0))
        try await settleDraftLoop()
        coord.resetConversationDraft()
        try await settleDraftLoop()
        #expect(panel.makeFirstResponder(resetEditor))
        #expect(panel.performKeyEquivalent(with: cmdZ))
        #expect(coord.conversationDraft?.isEdited == false)

        // Changing checked selection discards stale stashed draft from previous selection
        coord.updateConversationDraftText("Only for card 1")
        coord.dismissConversationDraft()
        coord.checkedCardIDs = [card1.id, card2.id]
        #expect(coord.openConversationDraft())
        #expect(coord.conversationDraft?.isEdited == false)
        #expect(coord.conversationDraft?.text.contains("Second verbatim snippet") == true)
        coord.dismissConversationDraft()

        // 9. AIAccessMode live update refreshes unedited draft, and active handoff takes priority over opening a new draft
        coord.checkedCardIDs = [card1.id]
        #expect(coord.openConversationDraft())
        #expect(coord.conversationDraft?.text.contains("append_snippet_note") == true)
        coord.setAIAccessMode(.readOnly)
        #expect(coord.conversationDraft?.text.contains("append_snippet_note") == false)
        coord.dismissConversationDraft()

        let agStore = coord.handoffStore(for: .antigravity)
        let pendingHandoff = try agStore.submit(prompt: "in-flight handoff", cardIDs: [card1.id], markSynthesized: false)
        try agStore.saveReceipt(ConversationReceipt(requestId: pendingHandoff.requestId, state: .unknown))
        try agStore.removeRequest(pendingHandoff.requestId)
        #expect(coord.hasActiveHandoffConversation)
        #expect(coord.openConversationDraft() == false)
        #expect(coord.conversationDraft == nil)
        delegate.perform(.launchConversation)
        for _ in 0..<40 where !coord.canEndUnconfirmedConversation {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coord.canEndUnconfirmedConversation)
        #expect(coord.conversationDraft == nil)
    }

    @Test("Open conversation draft reconciles captureSelection ID remaps, background enrichment refreshes, and external card removals without false archive failures")
    func hudConversationDraftReconcilesInFlightCaptureRefreshEnrichmentAndExternalRemoval() async throws {
        final class DraftMockURLProtocol: URLProtocol {
            struct State {
                var memos: [MemoWireDTO] = []
                var createServerID: String = "server-canonical-id"
                var createStarted: CheckedContinuation<Void, Never>?
                var patchedIDs: [String] = []
            }
            static let state = OSAllocatedUnfairLock(initialState: State())
            static let createRelease = DispatchSemaphore(value: 0)

            override class func canInit(with request: URLRequest) -> Bool {
                request.url?.host == "draft-reconcile.mock.local"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let url = request.url else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                    return
                }
                let method = request.httpMethod ?? "GET"
                let path = url.path

                if method == "POST", path == "/api/memos" {
                    let body = requestBodyData()
                    Self.state.withLock { s in
                        s.createStarted?.resume()
                        s.createStarted = nil
                    }
                    _ = Self.createRelease.wait(timeout: .now() + 5)
                    let serverID = Self.state.withLock { $0.createServerID }
                    let nowISO = ISO8601DateFormatter().string(from: Date())
                    let decoded = body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                    let content = decoded?["content"] ?? "#rewind/pending #source/macos\n\ncaptured body"
                    let dto = MemoWireDTO(name: "memos/\(serverID)", content: content, createTime: nowISO)
                    Self.state.withLock { $0.memos = [dto] }
                    let data = (try? JSONEncoder().encode(dto)) ?? Data("{}".utf8)
                    respond(statusCode: 200, data: data)
                    return
                }

                if method == "GET", path == "/api/memos" {
                    let memos = Self.state.withLock { $0.memos }
                    let data = (try? JSONEncoder().encode(["memos": memos])) ?? Data("{\"memos\":[]}".utf8)
                    respond(statusCode: 200, data: data)
                    return
                }

                if method == "PATCH", path.hasPrefix("/api/memos/") {
                    let id = String(path.dropFirst("/api/memos/".count))
                    let body = requestBodyData()
                    let decoded = body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                    let content = decoded?["content"] ?? "#rewind/synthesized"
                    let dto = MemoWireDTO(name: "memos/\(id)", content: content, createTime: ISO8601DateFormatter().string(from: Date()))
                    Self.state.withLock { s in
                        s.patchedIDs.append(id)
                        s.memos.removeAll { $0.name == "memos/\(id)" }
                    }
                    let data = (try? JSONEncoder().encode(dto)) ?? Data("{}".utf8)
                    respond(statusCode: 200, data: data)
                    return
                }

                respond(statusCode: 200, data: Data("{}".utf8))
            }

            override func stopLoading() {}

            private func requestBodyData() -> Data? {
                if let body = request.httpBody { return body }
                guard let stream = request.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n > 0 { data.append(buffer, count: n) } else { break }
                }
                return data
            }

            private func respond(statusCode: Int, data: Data) {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://draft-reconcile.mock.local")!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        struct FixedCapturer: SelectionCapturing {
            let capturedAt: Date
            func captureFrontmostSelection() async throws -> CapturedSelection {
                CapturedSelection(
                    text: "In-flight provisional capture snippet",
                    bundleIdentifier: "com.apple.Terminal",
                    appName: "Terminal",
                    windowTitle: "zsh",
                    capturedAt: capturedAt
                )
            }
        }

        DraftMockURLProtocol.state.withLock { $0 = .init() }
        defer { DraftMockURLProtocol.state.withLock { $0 = .init() } }

        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/hud-draft-reconcile-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DraftMockURLProtocol.self]
        let memosClient = MemosClient(session: URLSession(configuration: sessionConfig))

        let env: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            StoragePaths.memosURLEnvironmentKey: "https://draft-reconcile.mock.local",
            StoragePaths.memosTokenEnvironmentKey: "qa-draft-token"
        ]
        let deliveredPrompts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let coord = try AppCoordinator(
            paths: paths,
            environment: env,
            memosClient: memosClient,
            capturer: FixedCapturer(capturedAt: Date()),
            language: .zhHans,
            dshReadinessCheck: { true }
        )
        coord.onWakeHost = { host in
            guard host == .dsh else { return }
            let dshStore = coord.handoffStore(for: .dsh)
            Task.detached {
                if let worker = try? ConversationSidecarWorker.acquireIfUnlocked(store: dshStore) {
                    try? worker.processPending { req in
                        deliveredPrompts.withLock { $0.append(req.prompt) }
                        return (.succeeded, UUID().uuidString.lowercased())
                    }
                }
            }
        }
        coord.onOpenConversation = { _ in true }

        // A. Start captureSelection, wait until provisional card is staged before POST /api/memos finishes
        var captureTask: Task<SelectionCaptureOutcome, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            DraftMockURLProtocol.state.withLock { $0.createStarted = started }
            captureTask = Task { @MainActor in
                await coord.captureSelection()
            }
        }
        let provisionalID = try #require(coord.cards.first?.id)
        #expect(provisionalID != "server-canonical-id")
        #expect(coord.openConversationDraft(in: .dsh))
        #expect(coord.conversationDraft?.cardIDs == [provisionalID])
        #expect(coord.conversationDraft?.text.contains(provisionalID) == true)

        // Complete POST /api/memos returning server-canonical-id -> open unedited draft remaps ID & prompt live
        DraftMockURLProtocol.createRelease.signal()
        let captureOutcome = await captureTask?.value
        #expect(captureOutcome == .saved(cardID: "server-canonical-id", sourceTitle: "zsh"))
        #expect(coord.conversationDraft?.cardIDs == ["server-canonical-id"])
        #expect(coord.conversationDraft?.text.contains("server-canonical-id") == true)
        #expect(coord.conversationDraft?.text.contains(provisionalID) == false)

        // B. Background refresh brings back enriched Title/Context -> unedited draft updates live
        let enrichedContent = """
        #rewind/ready #source/macos

        > **Title:** 服务端异步整理标题
        > **Session:** 并发捕获联调
        > **Context:** 验证草稿打开期间后台增强刷新同步更新默认提示词。
        > **Keywords:** Draft, Refresh

        In-flight provisional capture snippet
        """
        DraftMockURLProtocol.state.withLock { s in
            s.memos = [MemoWireDTO(
                name: "memos/server-canonical-id",
                content: enrichedContent,
                createTime: ISO8601DateFormatter().string(from: Date())
            )]
        }
        await coord.refresh()
        #expect(coord.conversationDraft?.text.contains("服务端异步整理标题") == true)
        #expect(coord.conversationDraft?.text.contains("验证草稿打开期间后台增强刷新") == true)

        // Send with markSynthesizedOnLaunch = true -> archives canonical server-canonical-id cleanly
        coord.markSynthesizedOnLaunch = true
        let sendResult1 = await coord.sendConversationDraft(in: .dsh, waitSeconds: 2)
        if case .succeeded = sendResult1 {} else { Issue.record("Expected DSH send to succeed") }
        #expect(DraftMockURLProtocol.state.withLock { $0.patchedIDs } == ["server-canonical-id"])
        #expect(!coord.isErrorBanner)
        #expect(!coord.canEndUnarchivedConversation)

        // C. Re-seed a card, open unedited draft, remove card remotely -> refresh closes empty unedited draft
        let nowISO = ISO8601DateFormatter().string(from: Date())
        DraftMockURLProtocol.state.withLock { s in
            s.memos = [MemoWireDTO(
                name: "memos/ephemeral-card",
                content: "#rewind/ready #source/web\n\n> **Title:** Ephemeral\n\nBody",
                createTime: nowISO
            )]
        }
        await coord.refresh()
        coord.checkedCardIDs = ["ephemeral-card"]
        #expect(coord.openConversationDraft(in: .dsh))
        DraftMockURLProtocol.state.withLock { $0.memos = [] }
        await coord.refresh()
        #expect(coord.cards.isEmpty)
        #expect(coord.conversationDraft == nil)

        // D. Re-seed card, open & EDIT draft, then remove card remotely -> edited text preserved, reset dismisses with warning, or direct send succeeds without false archive lockup
        DraftMockURLProtocol.state.withLock { s in
            s.memos = [MemoWireDTO(
                name: "memos/edited-ephemeral",
                content: "#rewind/ready #source/web\n\n> **Title:** Edited Ephemeral\n\nBody",
                createTime: nowISO
            )]
        }
        await coord.refresh()
        coord.checkedCardIDs = ["edited-ephemeral"]
        #expect(coord.openConversationDraft(in: .dsh))
        coord.updateConversationDraftText("User manually edited prompt surviving external card archive")
        DraftMockURLProtocol.state.withLock { $0.memos = [] }
        await coord.refresh()
        #expect(coord.cards.isEmpty)
        #expect(coord.conversationDraft?.text == "User manually edited prompt surviving external card archive")
        #expect(coord.conversationDraft?.cardIDs.isEmpty == true)

        // Direct send with markSynthesizedOnLaunch = true still delivers custom prompt without false .sentPartialArchiveFailure
        coord.markSynthesizedOnLaunch = true
        let sendResult2 = await coord.sendConversationDraft(in: .dsh, waitSeconds: 2)
        if case .succeeded = sendResult2 {} else { Issue.record("Expected edited orphan draft send to succeed") }
        #expect(deliveredPrompts.withLock { $0.last } == "User manually edited prompt surviving external card archive")
        #expect(!coord.isErrorBanner)
        #expect(!coord.canEndUnarchivedConversation)

        // Also verify resetConversationDraft when cards become empty dismisses cleanly with error banner instead of silent no-op
        DraftMockURLProtocol.state.withLock { s in
            s.memos = [MemoWireDTO(
                name: "memos/reset-ephemeral",
                content: "#rewind/ready #source/web\n\nBody",
                createTime: nowISO
            )]
        }
        await coord.refresh()
        coord.checkedCardIDs = ["reset-ephemeral"]
        #expect(coord.openConversationDraft(in: .dsh))
        coord.updateConversationDraftText("Edited before empty reset")
        DraftMockURLProtocol.state.withLock { $0.memos = [] }
        await coord.refresh()
        coord.resetConversationDraft()
        #expect(coord.conversationDraft == nil)
        #expect(coord.isErrorBanner)
    }
}

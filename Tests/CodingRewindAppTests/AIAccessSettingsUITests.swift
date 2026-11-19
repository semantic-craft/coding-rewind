// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import os
import SwiftUI
import Testing
@testable import CodingRewindApp

private struct AIAccessUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.emptySelection
    }
}

@MainActor
private func drainAIAccessRunLoop(_ seconds: TimeInterval = 0.03) {
    autoreleasepool {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private func aiAXChildren(_ node: Any) -> [Any] {
    if let ax = node as? any NSAccessibilityProtocol, let children = ax.accessibilityChildren() {
        return children
    }
    return (node as AnyObject).accessibilityChildren?() ?? []
}

@MainActor
private func aiAXIdentifier(_ node: Any) -> String? {
    if let ax = node as? any NSAccessibilityProtocol { return ax.accessibilityIdentifier() }
    return (node as AnyObject).accessibilityIdentifier?()
}

@MainActor
private func aiAXStrings(_ node: Any) -> [String] {
    var out: [String] = []
    if let ax = node as? any NSAccessibilityProtocol {
        if let label = ax.accessibilityLabel() { out.append(label) }
        if let title = ax.accessibilityTitle() { out.append(title) }
        if let value = ax.accessibilityValue() as? String { out.append(value) }
        return out
    }
    let obj = node as AnyObject
    if let label = obj.accessibilityLabel?() { out.append(label) }
    if let title = obj.accessibilityTitle?() { out.append(title) }
    if let value = (obj.accessibilityValue as (() -> String?)?)?() { out.append(value) }
    return out
}

@MainActor
private func walkAIAX(_ root: Any, visited: inout Set<ObjectIdentifier>, visit: (Any) -> Bool) -> Bool {
    autoreleasepool {
        let obj = root as AnyObject
        guard visited.insert(ObjectIdentifier(obj)).inserted else { return false }
        if visit(root) { return true }
        for child in aiAXChildren(root) where walkAIAX(child, visited: &visited, visit: visit) {
            return true
        }
        return false
    }
}

@MainActor
private func findSegmentedControl(in view: NSView) -> NSSegmentedControl? {
    if let seg = view as? NSSegmentedControl, seg.segmentCount == 2 {
        return seg
    }
    for sub in view.subviews {
        if let found = findSegmentedControl(in: sub) {
            return found
        }
    }
    return nil
}

@MainActor
private func hasAIAXText(_ substring: String, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return walkAIAX(root, visited: &visited) { node in
        aiAXStrings(node).contains { $0.contains(substring) }
    }
}

@MainActor
private func pressAIAXButton(matching predicate: (Any) -> Bool, in root: Any) -> Bool {
    var visited: Set<ObjectIdentifier> = []
    return walkAIAX(root, visited: &visited) { node in
        guard predicate(node) else { return false }
        if let btn = node as? any NSAccessibilityButton { return btn.accessibilityPerformPress() }
        if let ax = node as? any NSAccessibilityProtocol { return ax.accessibilityPerformPress() }
        return (node as AnyObject).accessibilityPerformPress?() == true
    }
}

extension AppShortcutsTests {
    @Test("AppCoordinator AI access mode persists with memos_url, honors env override, emits token-free MCP JSON, and gates handoff prompt")
    func coordinatorAIAccessModeEnvLockMCPJSONAndHandoffLoop() async throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/ai-access-coord-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        try paths.saveMemosURLString("https://memos.example.com")
        let env: [String: String] = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.memosTokenEnvironmentKey: "qa-secret-token-never-in-json"
        ]

        let card = try #require(MemosWireFormat.parseMemo(
            id: "rw-handoff-1",
            rawContent: "#rewind/ready #source/antigravity\n\nHighlight body",
            createdAt: Date()
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card])

        let recordedPrompts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let coord = try AppCoordinator(
            paths: paths,
            environment: env,
            capturer: AIAccessUnusedCapturer(),
            dshReadinessCheck: { true }
        )
        coord.conversationHost = .dsh
        coord.onWakeHost = { host in
            guard host == .dsh else { return }
            let dshStore = coord.handoffStore(for: .dsh)
            if let worker = try? ConversationSidecarWorker.acquireIfUnlocked(store: dshStore) {
                try? worker.processPending { request in
                    recordedPrompts.withLock { $0.append(request.prompt) }
                    return (.succeeded, UUID().uuidString.lowercased())
                }
            }
        }

        #expect(coord.aiAccessMode == .readWrite)
        #expect(!coord.isAIAccessManagedByEnvironment)
        #expect(!coord.isMCPBinaryInstalled)
        #expect(coord.mcpServiceStatusText.contains("Application Support/CodingRewind/bin/"))

        let fakeBin = dir.appendingPathComponent("fake-cli")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: fakeBin, permissions: 0o755)
        coord.installOrRepairPlugin(sourceCLIBinaryURL: fakeBin, sourceSidecarURL: fakeBin)
        #expect(coord.isMCPBinaryInstalled)
        #expect(coord.mcpServiceStatusText.contains("7"))

        let mcpJSON = coord.mcpClientConfigurationJSON()
        #expect(!mcpJSON.contains("qa-secret-token-never-in-json"))
        #expect(!mcpJSON.lowercased().contains("token"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(mcpJSON.utf8)) as? [String: Any])
        let servers = try #require(parsed["mcpServers"] as? [String: Any])
        let entry = try #require(servers["coding-rewind"] as? [String: Any])
        #expect(entry["command"] as? String == AntigravityIntegration.stableCLIBinaryURL(in: paths.dataDirectoryURL).path)
        #expect(entry["args"] as? [String] == ["mcp"])

        coord.checkedCardIDs = [card.id]

        _ = await coord.launchChecked(in: .dsh, waitSeconds: 2)
        #expect(recordedPrompts.withLock { $0.last }?.contains("rw-handoff-1") == true)
        #expect(recordedPrompts.withLock { $0.last }?.contains("append_snippet_note") == true)

        coord.setAIAccessMode(.readOnly)
        #expect(coord.aiAccessMode == .readOnly)
        #expect(coord.mcpServiceStatusText.contains("3"))
        #expect(paths.resolveAIAccessMode(environment: [:]) == .readOnly)
        #expect(paths.readConfiguredMemosURLString(environment: [:]) == "https://memos.example.com")

        coord.checkedCardIDs = [card.id]
        _ = await coord.launchChecked(in: .dsh, waitSeconds: 2)
        #expect(recordedPrompts.withLock { $0.last }?.contains("rw-handoff-1") == true)
        #expect(recordedPrompts.withLock { $0.last }?.contains("append_snippet_note") == false)

        try paths.saveAIAccessMode(.readWrite)
        var lockedEnv = env
        lockedEnv[StoragePaths.aiAccessEnvironmentKey] = "read_only"
        let envLockedCoord = try AppCoordinator(paths: paths, environment: lockedEnv, capturer: AIAccessUnusedCapturer())
        #expect(envLockedCoord.isAIAccessManagedByEnvironment)
        #expect(envLockedCoord.aiAccessMode == .readOnly)
        envLockedCoord.setAIAccessMode(.readWrite)
        #expect(envLockedCoord.aiAccessMode == .readOnly)
        #expect(paths.resolveAIAccessMode(environment: [:]) == .readWrite)
        #expect(envLockedCoord.bannerMessage?.contains("CODING_REWIND_AI_ACCESS") == true)
    }

    @Test("Integrations settings renders AI access section, copies MCP JSON, switches zh-Hans/en, and HUD toggle refreshes AI clips")
    func integrationsSettingsUIAndHUDReopenRefresh() async throws {
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
            .appendingPathComponent(".test-data/ai-access-ui-\(UUID().uuidString.lowercased())", isDirectory: true)
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        let env = [StoragePaths.qaEnvironmentKey: "1", KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"]
        let coord = try AppCoordinator(paths: paths, environment: env, capturer: AIAccessUnusedCapturer(), language: .zhHans)
        let appearance = AppAppearancePreferences(defaults: Self.defaults, applyPolicy: { _ in true }, preferredLanguagesProvider: { ["zh-Hans-CN"] })
        appearance.setLanguagePreference(.zhHans)
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord
        let shortcuts = AppShortcuts(language: .zhHans) { delegate.perform($0) }
        let panel = QuickPeekHUDPanel(coordinator: coord, shortcuts: shortcuts) { delegate.perform($0) }
        delegate.hudPanel = panel
        let nav = SettingsNavigationModel(selectedPage: .integrations)
        var copiedPayloads: [String] = []
        var dispatchedCommands: [AppCommand] = []

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 540)), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRootView(
            coordinator: coord,
            appearance: appearance,
            shortcuts: shortcuts,
            permissionState: AccessibilityPermissionState { true },
            navigationModel: nav,
            onCopyText: { copiedPayloads.append($0) },
            onCommand: { command in
                dispatchedCommands.append(command)
                if command != .installOrRepairDSHPlugin {
                    delegate.perform(command)
                }
            },
            onClose: { window.orderOut(nil) }
        ))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            panel.orderOut(nil)
            shortcuts.stop()
            if NSApplication.shared.responds(to: setEnhanced) {
                _ = NSApplication.shared.perform(setEnhanced, with: NSNumber(value: wasEnhanced))
            }
            try? FileManager.default.removeItem(at: dir)
        }
        drainAIAccessRunLoop(0.05)

        #expect(hasAIAXText("Antigravity 插件", in: window))
        #expect(hasAIAXText("DSH 插件", in: window))
        #expect(hasAIAXText("DeepSeek Harness", in: window))
        #expect(pressAIAXButton(matching: { aiAXIdentifier($0) == "settings.dshInstallOrRepair" }, in: window))
        drainAIAccessRunLoop(0.05)
        #expect(dispatchedCommands.contains(.installOrRepairDSHPlugin))

        #expect(hasAIAXText("AI 接入与权限", in: window))
        #expect(hasAIAXText("Claude Desktop", in: window))
        #expect(hasAIAXText("DSH", in: window))
        #expect(!hasAIAXText("Codex", in: window))
        #expect(pressAIAXButton(matching: { aiAXIdentifier($0) == "settings.copyMCPConfig" }, in: window))
        drainAIAccessRunLoop(0.05)
        #expect(copiedPayloads.count == 1)
        #expect(copiedPayloads.first == coord.mcpClientConfigurationJSON())
        #expect(hasAIAXText("已复制", in: window))

        let rootView = try #require(window.contentView)
        let segmented = try #require(findSegmentedControl(in: rootView))
        #expect(segmented.isEnabled)
        #expect(segmented.label(forSegment: 0) == "只读（仅检索）")
        #expect(segmented.label(forSegment: 1) == "允许读写（批注与新建）")
        segmented.selectedSegment = 0
        #expect(NSApplication.shared.sendAction(try #require(segmented.action), to: segmented.target, from: segmented))
        drainAIAccessRunLoop(0.05)
        #expect(coord.aiAccessMode == .readOnly)
        #expect(paths.resolveAIAccessMode(environment: [:]) == .readOnly)

        appearance.setLanguagePreference(.en)
        coord.setLanguage(.en)
        drainAIAccessRunLoop(0.05)
        #expect(hasAIAXText("Antigravity Plugin", in: window))
        #expect(hasAIAXText("DSH Plugin", in: window))
        #expect(hasAIAXText("AI Access & Permissions", in: window))
        #expect(hasAIAXText("Read-Only", in: window))
        #expect(hasAIAXText("Copied", in: window))
        let enSegmented = try #require(findSegmentedControl(in: rootView))
        #expect(enSegmented.label(forSegment: 0) == "Read-Only")
        #expect(enSegmented.label(forSegment: 1) == "Read & Write")
        for str in [
            AppStrings.aiAccessSectionTitle(in: .zhHans), AppStrings.aiAccessSectionTitle(in: .en),
            AppStrings.mcpConfigCompatibilityCaption(in: .zhHans), AppStrings.mcpConfigCompatibilityCaption(in: .en),
            coord.mcpServiceStatusText
        ] {
            #expect(!str.contains("—"))
        }

        coord.environment[StoragePaths.aiAccessEnvironmentKey] = "read_only"
        drainAIAccessRunLoop(0.05)
        let lockedSegmented = try #require(findSegmentedControl(in: rootView))
        #expect(!lockedSegmented.isEnabled)
        #expect(hasAIAXText("CODING_REWIND_AI_ACCESS", in: window))

        let repo = SnippetRepository(paths: paths, environment: env)
        let created = try await repo.createSnippet(SnippetCreateInput(text: "AI synthesized outline via CLI"))
        #expect(!coord.cards.contains { $0.id == created.id })
        delegate.perform(.toggleHUD)
        for _ in 0..<50 where !coord.cards.contains(where: { $0.id == created.id }) {
            try await Task.sleep(for: .milliseconds(10))
            drainAIAccessRunLoop(0.01)
        }
        #expect(panel.isVisible)
        #expect(coord.cards.contains { $0.id == created.id })
    }
}

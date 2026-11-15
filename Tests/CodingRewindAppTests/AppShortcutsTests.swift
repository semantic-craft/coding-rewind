// SPDX-License-Identifier: MIT

import AppKit
import Carbon.HIToolbox
import CodingRewindCore
import Testing
@testable import CodingRewindApp
@testable import KeyboardShortcuts

@Suite(.serialized)
@MainActor
struct AppShortcutsTests {
    nonisolated private static let suite = "dev.codingrewind.qa.tests"
    private static let defaults: UserDefaults = {
        let value = UserDefaults(suiteName: suite)!
        KeyboardShortcuts.configure(userDefaults: value)
        atexit {
            cleanUserDefaultsSuite(suite)
        }
        return value
    }()
    private let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    nonisolated private static func cleanUserDefaultsSuite(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }

    init() {
        _ = Self.defaults
        KeyboardShortcuts.removeAllHandlers()
        KeyboardShortcuts.isPaused = false
        KeyboardShortcuts.isEnabled = true
        Self.cleanUserDefaultsSuite(Self.suite)
    }

    @Test("The Operations menu uses the coordinator archive preference", arguments: [false, true])
    func menuLaunchUsesSharedArchiveIntent(archive: Bool) async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/menu-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir.appendingPathComponent("Data"), antigravityConfigDirectoryURL: dir.appendingPathComponent("Config"))
        let binary = dir.appendingPathComponent("fixture-executable")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: binary, permissions: 0o755)
        try AntigravityIntegration.installOrRepair(dataDirectoryURL: paths.dataDirectoryURL, configDirectoryURL: paths.antigravityConfigDirectoryURL, sourceSidecarBinaryURL: binary)
        let card = try #require(MemosWireFormat.parseMemo(id: "selected", rawContent: "#rewind/ready #source/macos\n\nSelected", createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card])
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: UnusedSelectionCapturer())
        coordinator.checkedCardIDs = [card.id]
        coordinator.markSynthesizedOnLaunch = archive
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coordinator
        let shortcuts = AppShortcuts { delegate.perform($0) }
        defer { shortcuts.stop() }
        let menu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts) { delegate.perform($0) }
        let operations = try #require(menu.items.first { $0.title == "操作" }?.submenu)
        let launch = try #require(operations.items.first { $0.keyEquivalent == "\r" })
        let action = try #require(launch.action)
        let persistedIntent: Bool = await withCheckedContinuation { continuation in
            coordinator.onWakeHost = { host in
                #expect(host == .antigravity)
                do {
                    let store = coordinator.handoffStore(for: host)
                    guard let current = try store.current() else {
                        Issue.record("Menu launch did not persist a handoff")
                        continuation.resume(returning: !archive)
                        return
                    }
                    try store.saveReceipt(ConversationReceipt(requestId: current.requestId, state: .unknown))
                    continuation.resume(returning: current.markSynthesized)
                } catch {
                    Issue.record(error)
                    continuation.resume(returning: !archive)
                }
            }
            #expect(NSApplication.shared.sendAction(action, to: launch.target, from: launch))
        }
        #expect(persistedIntent == archive)
        #expect(try coordinator.handoffStore(for: .antigravity).current()?.markSynthesized == archive)
        #expect(coordinator.cards == [card])
    }

    @Test func qaPreferencesAreStableAndGated() {
        let data = URL(fileURLWithPath: "/qa/shortcuts")
        #expect(AppPreferences.preferencesSuite(environment: [:], dataDirectory: data) == nil)
        #expect(AppPreferences.preferencesSuite(environment: ["CODING_REWIND_SHORTCUTS_SUITE": "dev.codingrewind.qa.override"], dataDirectory: data) == nil)
        let env = ["CODING_REWIND_QA": "1"]
        let suite = AppPreferences.preferencesSuite(environment: env, dataDirectory: data)
        #expect(suite == AppPreferences.preferencesSuite(environment: env, dataDirectory: data))
        #expect(suite != AppPreferences.preferencesSuite(environment: env, dataDirectory: data.appendingPathComponent("other")))
        #expect(AppPreferences.preferencesSuite(environment: ["CODING_REWIND_QA": "1", "CODING_REWIND_SHORTCUTS_SUITE": "dev.codingrewind.app"], dataDirectory: data) == suite)
    }

    @Test func hyperValidationRejectsTypingAndDuplicateActions() {
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }
        NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts) { _ in }
        defer { NSApplication.shared.mainMenu = nil }
        let value = KeyboardShortcuts.Shortcut(.k, modifiers: hyper)
        #expect(shortcuts.set(value, for: .captureSelection))
        #expect(shortcuts.shortcut(for: .captureSelection) == value)
        #expect(!shortcuts.set(value, for: .toggleHUD))
        let acceptsBare = shortcuts.set(.init(.j, modifiers: []), for: .captureSelection)
        let acceptsShift = shortcuts.set(.init(.j, modifiers: [.shift]), for: .captureSelection)
        let acceptsPaste = shortcuts.set(.init(.v, modifiers: [.command]), for: .captureSelection)
        #expect(!acceptsBare)
        #expect(!acceptsShift)
        #expect(!acceptsPaste)
        #expect(shortcuts.validate(.init(.f20, modifiers: []), for: .captureSelection) == .allow)
        #expect(shortcuts.validate(.init(.f20, modifiers: [.shift]), for: .captureSelection) == .allow)
        #expect(shortcuts.shortcut(for: .captureSelection) == value)
        #expect(shortcuts.set(ShortcutAction.captureSelection.defaultShortcut, for: .toggleHUD))
        shortcuts.restoreDefault(for: .captureSelection)
        #expect(shortcuts.shortcut(for: .captureSelection) == value)
        #expect(shortcuts.validationMessages[.captureSelection] != nil)
    }

    @Test func currentSystemAndNewMenuBindingsAreBlocked() throws {
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop(); NSApplication.shared.mainMenu = nil }
        let menu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts) { _ in }
        let dynamicShortcut = KeyboardShortcuts.Shortcut(.u, modifiers: [.command])
        let extra = NSMenuItem(title: "New command", action: nil, keyEquivalent: "u")
        extra.keyEquivalentModifierMask = [.command]
        menu.items[1].submenu?.addItem(extra)
        NSApplication.shared.mainMenu = menu
        let accepted = shortcuts.set(dynamicShortcut, for: .captureSelection)
        #expect(!accepted)
        let system = try #require(KeyboardShortcuts.Shortcut.system.first { !$0.modifiers.intersection([.command, .control, .option]).isEmpty && $0.isTakenBySystem })
        #expect(shortcuts.validate(system, for: .captureSelection) == .disallow(reason: "此组合键已由系统使用，请选择其他快捷键。"))
    }

    @Test func clearingSurvivesNameRecreationAndMenuRefresh() {
        let shortcuts = AppShortcuts { _ in }
        let item = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        shortcuts.bindMenuItem(item, to: .captureSelection)
        #expect(shortcuts.set(.init(.f18, modifiers: hyper), for: .captureSelection))
        #expect(shortcuts.state(for: .captureSelection) == .active)
        #expect(!item.keyEquivalent.isEmpty)
        #expect(shortcuts.set(nil, for: .captureSelection))
        #expect(shortcuts.state(for: .captureSelection) == .unassigned)
        #expect(item.keyEquivalent.isEmpty)
        shortcuts.stop()
        let recreated = AppShortcuts { _ in }
        defer { recreated.stop() }
        #expect(recreated.shortcut(for: .captureSelection) == nil)
        #expect(Self.defaults.object(forKey: "KeyboardShortcuts_captureSelection") as? Bool == false)
        recreated.restoreDefault(for: .captureSelection)
        #expect(recreated.shortcut(for: .captureSelection) == ShortcutAction.captureSelection.defaultShortcut)
    }

    @Test func actualCarbonConflictIsVisibleAfterPauseAndRetry() throws {
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }
        let shortcut = KeyboardShortcuts.Shortcut(.f19, modifiers: hyper)
        #expect(shortcuts.set(shortcut, for: .captureSelection))
        #expect(shortcuts.state(for: .captureSelection) == .active)
        let item = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        shortcuts.bindMenuItem(item, to: .captureSelection)
        KeyboardShortcuts.isPaused = true
        #expect(shortcuts.state(for: .captureSelection) == .paused)
        #expect(item.keyEquivalent.isEmpty)
        var competing: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers), EventHotKeyID(signature: 0x43525453, id: 1), GetEventDispatcherTarget(), 0, &competing)
        #expect(status == noErr)
        let registered = try #require(competing)
        defer { if let competing { UnregisterEventHotKey(competing) } }
        KeyboardShortcuts.isPaused = false
        #expect(shortcuts.state(for: .captureSelection) == .failed(Int32(eventHotKeyExistsErr)))
        #expect(shortcuts.shortcut(for: .captureSelection) == shortcut)
        #expect(item.keyEquivalent.isEmpty)
        UnregisterEventHotKey(registered)
        competing = nil
        shortcuts.retry(.captureSelection)
        #expect(shortcuts.state(for: .captureSelection) == .active)
        #expect(!item.keyEquivalent.isEmpty)
    }

    @Test func initialConflictKeepsConfigurationAndClearsStaleValidationOnRecording() throws {
        let shortcut = KeyboardShortcuts.Shortcut(.f17, modifiers: hyper)
        var competing: EventHotKeyRef?
        #expect(RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers), EventHotKeyID(signature: 0x43525453, id: 2), GetEventDispatcherTarget(), 0, &competing) == noErr)
        let registered = try #require(competing)
        defer { UnregisterEventHotKey(registered) }
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }
        #expect(shortcuts.set(shortcut, for: .captureSelection))
        #expect(shortcuts.state(for: .captureSelection) == .failed(Int32(eventHotKeyExistsErr)))
        #expect(shortcuts.shortcut(for: .captureSelection) == shortcut)
        let rejected = shortcuts.set(.init(.j, modifiers: []), for: .captureSelection)
        #expect(!rejected)
        #expect(shortcuts.validationMessages[.captureSelection] != nil)
        KeyboardShortcuts.setShortcut(.init(.f18, modifiers: hyper), for: ShortcutAction.captureSelection.name)
        #expect(shortcuts.validationMessages[.captureSelection] == nil)
    }

    @Test(arguments: [UInt32(0), UInt32(kEventHotKeyExclusive)])
    func crossProcessRegistrationDistinguishesSharedAndExclusive(options: UInt32) throws {
        let candidates = Bundle.allBundles.map {
            $0.bundleURL.deletingLastPathComponent().appendingPathComponent("ShortcutConflictFixture")
        } + [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/ShortcutConflictFixture")]
        let executable = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let shortcut = KeyboardShortcuts.Shortcut(.f16, modifiers: hyper)
        let child = Process()
        child.executableURL = executable
        child.arguments = [String(shortcut.carbonKeyCode), String(shortcut.carbonModifiers), String(options)]
        child.environment = [:]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let ready = output.fileHandleForReading.availableData
        #expect(String(data: ready, encoding: .utf8) == "0\n")
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }
        #expect(shortcuts.set(shortcut, for: .captureSelection))
        #expect(shortcuts.state(for: .captureSelection) == (options == 0 ? .active : .failed(Int32(eventHotKeyExistsErr))))
        #expect(shortcuts.shortcut(for: .captureSelection) == shortcut)
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        shortcuts.retry(.captureSelection)
        #expect(shortcuts.state(for: .captureSelection) == .active)
    }

    @Test func defaultShortcutsUseHyperSAndControlOptionR() {
        #expect(ShortcutAction.captureSelection.defaultShortcut == .init(.s, modifiers: hyper))
        #expect(ShortcutAction.toggleHUD.defaultShortcut == .init(.r, modifiers: [.control, .option]))
    }

    @Test func legacyControlOptionSMigratesOnceToHyperS() throws {
        let legacy = KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option])
        let encodedLegacy = try String(decoding: JSONEncoder().encode(legacy), as: UTF8.self)
        Self.defaults.set(encodedLegacy, forKey: "KeyboardShortcuts_captureSelection")
        Self.defaults.removeObject(forKey: "CodingRewind.captureSelectionShortcutSchemaVersion")

        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }
        #expect(shortcuts.shortcut(for: .captureSelection) == ShortcutAction.captureSelection.defaultShortcut)
        #expect(Self.defaults.integer(forKey: "CodingRewind.captureSelectionShortcutSchemaVersion") == 2)
    }

    @Test func customAndClearedShortcutsSurviveSchemaMigrationAndExplicitV2ChoicePersists() throws {
        let custom = KeyboardShortcuts.Shortcut(.k, modifiers: hyper)
        let encodedCustom = try String(decoding: JSONEncoder().encode(custom), as: UTF8.self)
        Self.defaults.set(encodedCustom, forKey: "KeyboardShortcuts_captureSelection")
        Self.defaults.removeObject(forKey: "CodingRewind.captureSelectionShortcutSchemaVersion")
        do {
            let shortcuts = AppShortcuts { _ in }
            defer { shortcuts.stop() }
            #expect(shortcuts.shortcut(for: .captureSelection) == custom)
            #expect(Self.defaults.integer(forKey: "CodingRewind.captureSelectionShortcutSchemaVersion") == 2)
        }

        Self.defaults.removePersistentDomain(forName: Self.suite)
        Self.defaults.set(false, forKey: "KeyboardShortcuts_captureSelection")
        do {
            let shortcuts = AppShortcuts { _ in }
            defer { shortcuts.stop() }
            #expect(shortcuts.shortcut(for: .captureSelection) == nil)
            #expect(shortcuts.state(for: .captureSelection) == .unassigned)
            #expect(Self.defaults.integer(forKey: "CodingRewind.captureSelectionShortcutSchemaVersion") == 2)
        }

        let explicitLegacy = KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option])
        do {
            let shortcuts = AppShortcuts { _ in }
            #expect(shortcuts.set(explicitLegacy, for: .captureSelection))
            shortcuts.stop()
        }
        do {
            let reopened = AppShortcuts { _ in }
            defer { reopened.stop() }
            #expect(reopened.shortcut(for: .captureSelection) == explicitLegacy)
        }
    }

    @Test func modifierReleaseWaitYieldsAndTimesOut() async {
        var held = true
        let release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            held = false
        }
        #expect(await MacOSAccessibilitySelectionCapturer.waitForReleasedModifiers(timeout: .milliseconds(200), flags: { held ? [.maskCommand, .maskShift, .maskAlternate, .maskControl] : [] }))
        await release.value
        #expect(!(await MacOSAccessibilitySelectionCapturer.waitForReleasedModifiers(timeout: .milliseconds(20), flags: { [.maskCommand] })))
    }

    @Test func idempotentShortcutPreferencesConfigurationDoesNotTrapAfterRead() {
        _ = KeyboardShortcuts.configuredUserDefaults
        KeyboardShortcuts.configure(userDefaults: Self.defaults)
        #expect(KeyboardShortcuts.configuredUserDefaults === Self.defaults)
    }

    @Test func selectionPopupControllerPreservesSavingAndAnchorActivationFeedbackAndStopsCleanly() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/selection-popup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let appearance = AppAppearancePreferences(defaults: Self.defaults, applyPolicy: { _ in true })
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }

        var errorHUDCount = 0
        let popup = SelectionPopupController(
            appearance: appearance,
            shortcuts: shortcuts,
            onTriggerCapture: { .saved(cardID: "rw-1", sourceTitle: "Gemini") },
            onPresentErrorHUD: { errorHUDCount += 1 }
        )
        popup.start()
        popup.start()
        defer { popup.stop() }

        popup.showForTesting(anchorPID: 4242, shortcutHint: "⌃⌥⇧⌘S")
        #expect(popup.isVisible)

        let capturer = BlockingAppSelectionCapturer()
        let coord = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: capturer)
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord
        delegate.selectionPopupController = popup

        delegate.perform(.captureSelectionHotkey)
        #expect(popup.phase == .saving)
        await capturer.waitUntilStarted()

        delegate.perform(.captureSelectionHotkey)
        #expect(popup.phase == .saving)

        popup.applyInPlaceCaptureOutcome(.ignoredBusy)
        #expect(popup.phase == .saving)
        #expect(errorHUDCount == 0)

        popup.handleApplicationActivation(activatedPID: 9999)
        #expect(popup.phase == .saving)

        await capturer.finish()
        for _ in 0..<20 where popup.phase == .saving {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.phase == .saved(offline: true))
        #expect(await capturer.calls == 1)

        popup.handleApplicationActivation(activatedPID: 4242)
        #expect(popup.phase == .saved(offline: true))

        popup.handleApplicationActivation(activatedPID: 9999)
        #expect(popup.phase == .hidden)

        popup.showForTesting(anchorPID: 4242)
        #expect(popup.isVisible)
        appearance.setShowsSelectionPopup(false)
        for _ in 0..<20 where popup.phase != .hidden {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.phase == .hidden)

        appearance.setShowsSelectionPopup(true)
        popup.stop()
        popup.showForTesting(anchorPID: 4242)
        appearance.setShowsSelectionPopup(false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(popup.phase == .ready(shortcutHint: nil))
        popup.hideImmediately()
    }

    @Test func hudAndMenuCaptureRouteThroughUnifiedDelegateAndHideVisiblePopup() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/unified-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let appearance = AppAppearancePreferences(defaults: Self.defaults, applyPolicy: { _ in true })
        let capturer = ImmediateAppSelectionCapturer()
        let coord = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: capturer)
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord

        let shortcuts = AppShortcuts { delegate.perform($0) }
        defer { shortcuts.stop() }

        let popup = SelectionPopupController(
            appearance: appearance,
            shortcuts: shortcuts,
            onTriggerCapture: { .ignoredBusy },
            onPresentErrorHUD: {}
        )
        defer { popup.stop() }
        delegate.selectionPopupController = popup

        let panel = QuickPeekHUDPanel(coordinator: coord, shortcuts: shortcuts) { delegate.perform($0) }
        defer { panel.orderOut(nil) }
        delegate.hudPanel = panel

        let menu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts) { delegate.perform($0) }
        let windowMenu = try #require(menu.items.first { $0.title == "窗口" }?.submenu)
        let presentHUDItem = try #require(windowMenu.items.first { $0.title == "前置片段浮窗" })
        #expect(!windowMenu.items.contains { $0.title == "前置 Rewind 浮窗" })
        #expect(NSApplication.shared.sendAction(try #require(presentHUDItem.action), to: presentHUDItem.target, from: presentHUDItem))
        #expect(panel.isVisible)
        panel.orderOut(nil)

        popup.showForTesting(anchorPID: 4242)
        #expect(popup.isVisible)
        let operationsMenu = try #require(menu.items.first { $0.title == "操作" }?.submenu)
        let menuCaptureItem = try #require(operationsMenu.items.first { $0.title == "保存所选文本" })
        #expect(NSApplication.shared.sendAction(try #require(menuCaptureItem.action), to: menuCaptureItem.target, from: menuCaptureItem))
        #expect(popup.phase == .hidden)
        #expect(!popup.isVisible)
        for _ in 0..<30 where coord.cards.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coord.cards.count == 1)
        #expect(panel.isVisible)

        popup.showForTesting(anchorPID: 4242)
        #expect(popup.isVisible)
        let hudView = QuickPeekHUDRootView(
            coordinator: coord,
            shortcuts: shortcuts,
            onClose: { panel.orderOut(nil) },
            onCommand: { delegate.perform($0) }
        )
        hudView.onCommand(.captureSelection)
        #expect(popup.phase == .hidden)
        #expect(!popup.isVisible)
        for _ in 0..<30 where coord.cards.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coord.cards.count == 2)
    }

    @Test func selectionPopupRefusesSavedResurrectionAndProtectsInFlightSavingFromMenuCapture() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/popup-resurrection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let appearance = AppAppearancePreferences(defaults: Self.defaults, applyPolicy: { _ in true })
        appearance.setShowsSelectionPopup(true)
        let shortcuts = AppShortcuts { _ in }
        defer { shortcuts.stop() }

        var errorHUDCount = 0
        let popup = SelectionPopupController(
            appearance: appearance,
            shortcuts: shortcuts,
            onTriggerCapture: { .ignoredBusy },
            onPresentErrorHUD: { errorHUDCount += 1 }
        )
        popup.start()
        defer { popup.stop() }

        popup.applyInPlaceCaptureOutcome(.saved(cardID: "rw-ghost", sourceTitle: "Gemini"))
        #expect(popup.phase == .hidden)
        #expect(!popup.isVisible)

        popup.showForTesting(anchorPID: 4242)
        popup.beginSavingInPlace()
        popup.hideImmediately()
        popup.applyInPlaceCaptureOutcome(.saved(cardID: "rw-hidden", sourceTitle: "Gemini"))
        #expect(popup.phase == .hidden)
        #expect(!popup.isVisible)

        popup.showForTesting(anchorPID: 4242)
        popup.beginSavingInPlace()
        appearance.setShowsSelectionPopup(false)
        popup.applyInPlaceCaptureOutcome(.queuedOffline(cardID: "rw-disabled"))
        #expect(popup.phase == .hidden)
        #expect(!popup.isVisible)

        popup.applyInPlaceCaptureOutcome(.failed(.ioError("Accessibility failure")))
        #expect(popup.phase == .hidden)
        #expect(errorHUDCount == 1)

        appearance.setShowsSelectionPopup(true)
        let capturer = BlockingAppSelectionCapturer()
        let coord = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: capturer)
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord
        delegate.selectionPopupController = popup

        popup.showForTesting(anchorPID: 4242)
        delegate.perform(.captureSelectionHotkey)
        #expect(popup.phase == .saving)
        await capturer.waitUntilStarted()

        delegate.perform(.captureSelection)
        #expect(popup.phase == .saving)
        #expect(popup.isVisible)

        await capturer.finish()
        for _ in 0..<30 where popup.phase == .saving {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popup.phase == .saved(offline: true))
    }

    @Test func settingsWindowSyncsNormalizedURLResetsClosedDraftAndSuppressesPluginHUDPop() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/settings-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let appearance = AppAppearancePreferences(defaults: Self.defaults, applyPolicy: { _ in true })
        let card = try #require(MemosWireFormat.parseMemo(
            id: "menu-err-card",
            rawContent: "#rewind/ready #source/macos\n\nBody",
            createdAt: Date()
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card])
        let coord = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: UnusedSelectionCapturer(),
            codexDelivery: { _ in (.unknown, nil) }
        )
        let delegate = CodingRewindAppDelegate()
        delegate.coordinator = coord
        let shortcuts = AppShortcuts { delegate.perform($0) }
        defer { shortcuts.stop() }
        let hud = QuickPeekHUDPanel(coordinator: coord, shortcuts: shortcuts) { delegate.perform($0) }
        defer { hud.orderOut(nil) }
        delegate.hudPanel = hud

        @MainActor final class FlagBox { var value = false }
        let trustedFlag = FlagBox()
        let permissionState = AccessibilityPermissionState { trustedFlag.value }
        let settings = SettingsWindowController(
            coordinator: coord,
            appearance: appearance,
            shortcuts: shortcuts,
            permissionState: permissionState,
            onCommand: { delegate.perform($0) }
        )
        defer { settings.window?.close() }
        delegate.settingsWindowController = settings

        settings.show()
        #expect(settings.window?.isVisible == true)

        settings.connectionDraft.urlDraft = "https://memos.example.com/api/memos/"
        settings.connectionDraft.save(using: coord)
        #expect(settings.connectionDraft.urlDraft == "https://memos.example.com")
        #expect(settings.connectionDraft.saveFailed == false)

        settings.connectionDraft.urlDraft = "https://unsaved-draft.example.com"
        trustedFlag.value = true
        settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: settings.window))
        #expect(permissionState.isTrusted)
        #expect(settings.connectionDraft.urlDraft == "https://unsaved-draft.example.com")

        delegate.perform(.installOrRepairPlugin)
        #expect(!hud.isVisible)

        settings.window?.close()
        #expect(settings.window?.isVisible != true)
        settings.show()
        #expect(settings.connectionDraft.urlDraft == "https://memos.example.com")
        #expect(settings.connectionDraft.saveMessage == nil)
        settings.window?.close()

        coord.checkedCardIDs = [card.id]
        delegate.perform(.launchIn(.codex))
        for _ in 0..<40 where !hud.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hud.isVisible)
        #expect(coord.isErrorBanner)
    }

    @Test("StatusItemController refreshIcon idempotence preserves image reference under identical key and updates across outbox transition")
    func statusItemIconIdempotence() {
        final class CountBox { var value = 0 }
        let box = CountBox()
        let shortcuts = AppShortcuts(onCommand: { _ in })
        let controller = StatusItemController(
            shortcuts: shortcuts,
            snapshotProvider: {
                MenuStatusSnapshot(
                    isHUDVisible: false,
                    hotCardCount: 0,
                    checkedCardCount: 0,
                    pendingOutboxCount: box.value,
                    connection: .unconfigured,
                    isPluginReady: false,
                    pluginSummary: "",
                    isAccessibilityTrusted: false,
                    recentCards: []
                )
            },
            onCommand: { _ in }
        )
        defer { shortcuts.stop(); NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let initialImage = controller.statusItem.button?.image
        #expect(initialImage != nil)

        controller.refreshIcon()
        let secondImage = controller.statusItem.button?.image
        #expect(initialImage === secondImage)

        box.value = 1
        controller.refreshIcon()
        let badgedImage = controller.statusItem.button?.image
        #expect(badgedImage !== initialImage)

        controller.refreshIcon()
        let badgedImageSecond = controller.statusItem.button?.image
        #expect(badgedImage === badgedImageSecond)

        box.value = 0
        controller.refreshIcon()
        let unbadgedImage = controller.statusItem.button?.image
        #expect(unbadgedImage !== badgedImage)
    }

    @Test("SettingsWindowController polls permissions while window is visible and stops polling when closed")
    func settingsWindowPermissionPolling() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent(".test-data/settings-polling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data"),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config")
        )
        let coord = try AppCoordinator(paths: paths, environment: [:], capturer: UnusedSelectionCapturer(), codexDelivery: nil)
        let appearance = AppAppearancePreferences(defaults: UserDefaults(suiteName: "dev.codingrewind.qa.appearance")!)
        let shortcuts = AppShortcuts(onCommand: { _ in })

        final class FlagBox { var isTrusted = false }
        let flagBox = FlagBox()
        let permissionState = AccessibilityPermissionState(checkTrusted: { flagBox.isTrusted })
        #expect(!permissionState.isTrusted)

        let settings = SettingsWindowController(
            coordinator: coord,
            appearance: appearance,
            shortcuts: shortcuts,
            permissionState: permissionState,
            permissionPollInterval: .milliseconds(20),
            onCommand: { _ in }
        )
        defer { settings.window?.close(); shortcuts.stop(); Self.cleanUserDefaultsSuite("dev.codingrewind.qa.appearance") }

        settings.show()
        #expect(settings.window?.isVisible == true)
        #expect(!permissionState.isTrusted)

        flagBox.isTrusted = true

        let deadline = ContinuousClock.now + .milliseconds(200)
        while !permissionState.isTrusted && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(permissionState.isTrusted)

        settings.window?.close()
        #expect(settings.window?.isVisible != true)

        flagBox.isTrusted = false
        try await Task.sleep(for: .milliseconds(60))
        #expect(permissionState.isTrusted)
    }

    @Test("CodingRewindAppDelegate.resetAccessibilityApproval only runs tccutil for approved bundle IDs")
    func resetAccessibilityApprovalValidation() {
        var executed: [(executable: String, arguments: [String])] = []
        let runner: (String, [String]) -> Int32 = { exe, args in
            executed.append((exe, args))
            return 0
        }

        let nilResult = CodingRewindAppDelegate.resetAccessibilityApproval(bundleIdentifier: nil, runner: runner)
        #expect(!nilResult)
        #expect(executed.isEmpty)

        let foreignResult = CodingRewindAppDelegate.resetAccessibilityApproval(bundleIdentifier: "com.apple.Safari", runner: runner)
        #expect(!foreignResult)
        #expect(executed.isEmpty)

        let appResult = CodingRewindAppDelegate.resetAccessibilityApproval(bundleIdentifier: AppBundleID.selfApp, runner: runner)
        #expect(appResult)
        #expect(executed.count == 1)
        #expect(executed[0].executable == "/usr/bin/tccutil")
        #expect(executed[0].arguments == ["reset", "Accessibility", "dev.codingrewind.app"])

        executed.removeAll()
        let qaResult = CodingRewindAppDelegate.resetAccessibilityApproval(bundleIdentifier: AppBundleID.selfQAApp, runner: runner)
        #expect(qaResult)
        #expect(executed.count == 1)
        #expect(executed[0].executable == "/usr/bin/tccutil")
        #expect(executed[0].arguments == ["reset", "Accessibility", "dev.codingrewind.app.qa"])
    }
}

private actor ImmediateAppSelectionCapturer: SelectionCapturing {
    private var counter = 0

    func captureFrontmostSelection() async throws -> CapturedSelection {
        counter += 1
        return CapturedSelection(
            text: "Captured snippet \(counter)",
            bundleIdentifier: "com.google.GeminiMacOS",
            appName: "Gemini"
        )
    }
}

private actor BlockingAppSelectionCapturer: SelectionCapturing {
    private(set) var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func captureFrontmostSelection() async throws -> CapturedSelection {
        calls += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { release = $0 }
        return CapturedSelection(text: "Gemini snippet", bundleIdentifier: "com.google.GeminiMacOS", appName: "Gemini")
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

private struct UnusedSelectionCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection { throw RewindError.ioError("Capture is not used by menu launch") }
}

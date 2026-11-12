// SPDX-License-Identifier: MIT

import AppKit
import Carbon.HIToolbox
import Testing
@testable import CodingRewindApp
@testable import KeyboardShortcuts

@Suite(.serialized)
@MainActor
struct AppShortcutsTests {
    nonisolated private static let suite = "dev.codingrewind.qa.tests.\(UUID().uuidString)"
    private static let defaults: UserDefaults = {
        let value = UserDefaults(suiteName: suite)!
        KeyboardShortcuts.configure(userDefaults: value)
        atexit {
            UserDefaults(suiteName: AppShortcutsTests.suite)?.removePersistentDomain(forName: AppShortcutsTests.suite)
        }
        return value
    }()
    private let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init() {
        _ = Self.defaults
        KeyboardShortcuts.removeAllHandlers()
        KeyboardShortcuts.isPaused = false
        KeyboardShortcuts.isEnabled = true
        Self.defaults.removePersistentDomain(forName: Self.suite)
    }

    @Test func qaPreferencesAreStableAndGated() {
        let data = URL(fileURLWithPath: "/qa/shortcuts")
        #expect(AppShortcuts.preferencesSuite(environment: [:], dataDirectory: data) == nil)
        #expect(AppShortcuts.preferencesSuite(environment: ["CODING_REWIND_SHORTCUTS_SUITE": "dev.codingrewind.qa.override"], dataDirectory: data) == nil)
        let env = ["CODING_REWIND_QA": "1"]
        let suite = AppShortcuts.preferencesSuite(environment: env, dataDirectory: data)
        #expect(suite == AppShortcuts.preferencesSuite(environment: env, dataDirectory: data))
        #expect(suite != AppShortcuts.preferencesSuite(environment: env, dataDirectory: data.appendingPathComponent("other")))
        #expect(AppShortcuts.preferencesSuite(environment: ["CODING_REWIND_QA": "1", "CODING_REWIND_SHORTCUTS_SUITE": "dev.codingrewind.app"], dataDirectory: data) == suite)
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
}

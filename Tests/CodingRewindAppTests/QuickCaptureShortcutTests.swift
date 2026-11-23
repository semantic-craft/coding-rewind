// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import Testing
@testable import CodingRewindApp

extension AppShortcutsTests {
    @Test func quickCaptureShortcutPreservesLocalMenuAndDisplaysGlobalBinding() throws {
        KeyboardShortcuts.configure(userDefaults: Self.defaults)
        var commands: [AppCommand] = []
        let shortcuts = AppShortcuts(language: .en) { commands.append($0) }
        let previousMenu = NSApplication.shared.mainMenu
        let mainMenu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts, language: .en) { commands.append($0) }
        NSApplication.shared.mainMenu = mainMenu
        let status = StatusItemController(
            shortcuts: shortcuts,
            snapshotProvider: {
                MenuStatusSnapshot(
                    isHUDVisible: false,
                    hotCardCount: 0,
                    checkedCardCount: 0,
                    pendingOutboxCount: 0,
                    connection: .unconfigured,
                    isPluginReady: false,
                    pluginSummary: "",
                    isAccessibilityTrusted: false,
                    recentCards: [],
                    language: .en
                )
            },
            onCommand: { commands.append($0) }
        )
        defer {
            NSStatusBar.system.removeStatusItem(status.statusItem)
            NSApplication.shared.mainMenu = previousMenu
            shortcuts.stop()
        }

        let appItem = try #require(mainMenu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == "Quick Capture…" })
        #expect(appItem.keyEquivalent == "n")
        #expect(appItem.keyEquivalentModifierMask == .command)
        #expect(shortcuts.state(for: .quickCapture) == .unassigned)
        let hudShortcut = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
        try #require(shortcuts.set(hudShortcut, for: .toggleHUD))
        let acceptedDuplicate = shortcuts.set(hudShortcut, for: .quickCapture)
        #expect(!acceptedDuplicate)

        let shortcut = KeyboardShortcuts.Shortcut(.f15, modifiers: [.control, .option, .shift, .command])
        #expect(shortcuts.set(shortcut, for: .quickCapture))
        #expect(shortcuts.state(for: .quickCapture) == .active)
        status.menuNeedsUpdate(status.menu)
        let statusItem = try #require(status.menu.items.first { $0.title == "Quick Capture…" })
        #expect(!statusItem.keyEquivalent.isEmpty)
        #expect(statusItem.keyEquivalentModifierMask == shortcut.modifiers)
        let action = try #require(statusItem.action)
        #expect(NSApplication.shared.sendAction(action, to: statusItem.target, from: statusItem))
        #expect(commands == [.quickCapture])

        shortcuts.restoreDefault(for: .quickCapture)
        #expect(shortcuts.state(for: .quickCapture) == .unassigned)
        status.menuNeedsUpdate(status.menu)
        let clearedStatusItem = try #require(status.menu.items.first { $0.title == "Quick Capture…" })
        #expect(clearedStatusItem.keyEquivalent.isEmpty)
        #expect(appItem.keyEquivalent == "n")
    }
}

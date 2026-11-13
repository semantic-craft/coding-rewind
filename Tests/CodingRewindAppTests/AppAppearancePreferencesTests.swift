// SPDX-License-Identifier: MIT

import AppKit
@testable import CodingRewindApp
import Testing

@Suite(.serialized)
@MainActor
struct AppAppearancePreferencesTests {
    @Test func dockDefaultsVisibleAndPersistsExplicitChoice() {
        let domain = "dev.codingrewind.qa.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var policy: NSApplication.ActivationPolicy?
        let preferences = AppAppearancePreferences(defaults: defaults) { policy = $0; return true }
        preferences.apply()
        #expect(preferences.showsDockIcon)
        #expect(policy == .regular)
        preferences.setShowsDockIcon(false)
        #expect(policy == .accessory)
        let reopened = AppAppearancePreferences(defaults: defaults) { policy = $0; return true }
        reopened.apply()
        #expect(!reopened.showsDockIcon)
        #expect(policy == .accessory)
        reopened.setShowsDockIcon(true)
        #expect(policy == .regular)
        #expect(AppAppearancePreferences(defaults: defaults).showsDockIcon)
    }

    @Test func applyingAlreadyHiddenPolicyIsSuccessful() {
        let domain = "dev.codingrewind.qa.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        defer {
            defaults.removePersistentDomain(forName: domain)
            app.setActivationPolicy(previous)
        }
        app.setActivationPolicy(.accessory)
        #expect(app.activationPolicy() == .accessory)
        AppAppearancePreferences(defaults: defaults) { _ in true }.setShowsDockIcon(false)
        let reopened = AppAppearancePreferences(defaults: defaults)
        reopened.apply()
        #expect(reopened.errorMessage == nil)
        #expect(!reopened.showsDockIcon)
        #expect(app.activationPolicy() == .accessory)
    }

    @Test func failedSystemChangeDoesNotSaveFalseSuccess() {
        let domain = "dev.codingrewind.qa.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppAppearancePreferences(defaults: defaults) { _ in false }
        preferences.setShowsDockIcon(false)
        #expect(preferences.showsDockIcon)
        #expect(preferences.errorMessage != nil)
        #expect(AppAppearancePreferences(defaults: defaults).showsDockIcon)
    }

    @Test func qaAppearanceDoesNotEscapeDataDirectory() {
        let root = URL(fileURLWithPath: "/qa/appearance/\(UUID().uuidString)")
        let env = ["CODING_REWIND_QA": "1"]
        let first = AppShortcuts.preferences(environment: env, dataDirectory: root)
        let second = AppShortcuts.preferences(environment: env, dataDirectory: root.appendingPathComponent("other"))
        defer {
            for path in [root, root.appendingPathComponent("other")] {
                first.removePersistentDomain(forName: AppShortcuts.preferencesSuite(environment: env, dataDirectory: path)!)
            }
        }
        AppAppearancePreferences(defaults: first) { _ in true }.setShowsDockIcon(false)
        #expect(!AppAppearancePreferences(defaults: first).showsDockIcon)
        #expect(AppAppearancePreferences(defaults: second).showsDockIcon)
    }
}

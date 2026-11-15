// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
@testable import CodingRewindApp
import Testing

@Suite(.serialized)
@MainActor
struct AppAppearancePreferencesTests {
    private static let domain = "dev.codingrewind.qa.appearance"
    private static let popupDomain = "dev.codingrewind.qa.appearance.popup"

    nonisolated private static func cleanSuite(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        _ = CFPreferencesAppSynchronize(suiteName as CFString)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }

    @Test func dockDefaultsVisibleAndPersistsExplicitChoice() {
        let domain = Self.domain
        Self.cleanSuite(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { Self.cleanSuite(domain) }
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
        let domain = Self.domain
        Self.cleanSuite(domain)
        let defaults = UserDefaults(suiteName: domain)!
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        defer {
            Self.cleanSuite(domain)
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
        let domain = Self.domain
        Self.cleanSuite(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { Self.cleanSuite(domain) }
        let preferences = AppAppearancePreferences(defaults: defaults) { _ in false }
        preferences.setShowsDockIcon(false)
        #expect(preferences.showsDockIcon)
        #expect(preferences.errorMessage != nil)
        #expect(AppAppearancePreferences(defaults: defaults).showsDockIcon)
    }

    @Test func qaAppearanceDoesNotEscapeDataDirectory() {
        let env = ["CODING_REWIND_QA": "1"]
        let root = URL(fileURLWithPath: "/qa/appearance/first")
        let other = root.appendingPathComponent("other")
        let firstSuite = AppPreferences.preferencesSuite(environment: env, dataDirectory: root)!
        let secondSuite = AppPreferences.preferencesSuite(environment: env, dataDirectory: other)!
        Self.cleanSuite(firstSuite)
        Self.cleanSuite(secondSuite)
        let first = AppPreferences.userDefaults(environment: env, dataDirectory: root)
        let second = AppPreferences.userDefaults(environment: env, dataDirectory: other)
        defer {
            Self.cleanSuite(firstSuite)
            Self.cleanSuite(secondSuite)
        }
        AppAppearancePreferences(defaults: first) { _ in true }.setShowsDockIcon(false)
        #expect(!AppAppearancePreferences(defaults: first).showsDockIcon)
        #expect(AppAppearancePreferences(defaults: second).showsDockIcon)
    }

    @Test func selectionPopupPreferenceDefaultsEnabledAndPersists() {
        let domain = Self.popupDomain
        Self.cleanSuite(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { Self.cleanSuite(domain) }

        let initial = AppAppearancePreferences(defaults: defaults) { _ in true }
        #expect(initial.showsSelectionPopup)

        initial.setShowsSelectionPopup(false)
        #expect(!initial.showsSelectionPopup)
        let reopenedDisabled = AppAppearancePreferences(defaults: defaults) { _ in true }
        #expect(!reopenedDisabled.showsSelectionPopup)

        reopenedDisabled.setShowsSelectionPopup(true)
        #expect(reopenedDisabled.showsSelectionPopup)
        #expect(AppAppearancePreferences(defaults: defaults) { _ in true }.showsSelectionPopup)
    }

    @Test func languagePreferencePersistsResolvesSystemAndFiresLiveCallback() {
        let domain = Self.domain
        Self.cleanSuite(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defer { Self.cleanSuite(domain) }

        var systemPreferred = ["zh-Hans-CN"]
        let preferences = AppAppearancePreferences(
            defaults: defaults,
            applyPolicy: { _ in false },
            preferredLanguagesProvider: { systemPreferred }
        )
        #expect(preferences.languagePreference == .system)
        #expect(preferences.effectiveLanguage == .zhHans)

        var observedLanguages: [AppLanguage] = []
        preferences.onEffectiveLanguageChange = { observedLanguages.append($0) }
        preferences.setShowsDockIcon(false)
        #expect(preferences.errorMessage == AppStrings.dockIconError(in: .zhHans))

        preferences.setLanguagePreference(.en)
        #expect(preferences.languagePreference == .en)
        #expect(preferences.effectiveLanguage == .en)
        #expect(observedLanguages == [.en])
        #expect(preferences.errorMessage == AppStrings.dockIconError(in: .en))

        let reopened = AppAppearancePreferences(
            defaults: defaults,
            applyPolicy: { _ in true },
            preferredLanguagesProvider: { ["zh-Hans-CN"] }
        )
        #expect(reopened.languagePreference == .en)
        #expect(reopened.effectiveLanguage == .en)

        systemPreferred = ["en-US"]
        preferences.setLanguagePreference(.system)
        #expect(observedLanguages == [.en])
        systemPreferred = ["zh-Hant-TW"]
        preferences.refreshSystemLanguageIfNeeded()
        #expect(preferences.effectiveLanguage == .zhHans)
        #expect(observedLanguages == [.en, .zhHans])
    }
}

// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import CryptoKit
import Observation

public enum AppPreferences {
    public static func preferencesSuite(environment: [String: String], dataDirectory: URL) -> String? {
        guard environment["CODING_REWIND_QA"] == "1" else { return nil }
        if let suite = environment["CODING_REWIND_SHORTCUTS_SUITE"],
           suite.hasPrefix("dev.codingrewind.qa."),
           suite.count > 20 {
            return suite
        }
        let digest = SHA256.hash(data: Data(dataDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return "dev.codingrewind.qa.shortcuts.\(digest)"
    }

    public static func userDefaults(environment: [String: String], dataDirectory: URL) -> UserDefaults {
        if let suite = preferencesSuite(environment: environment, dataDirectory: dataDirectory) {
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Invalid QA preferences suite")
            }
            return defaults
        }
        return .standard
    }
}

@MainActor
@Observable
public final class AppAppearancePreferences {
    public private(set) var showsDockIcon: Bool
    public private(set) var showsSelectionPopup: Bool
    public private(set) var languagePreference: AppLanguagePreference
    public private(set) var effectiveLanguage: AppLanguage
    public private(set) var errorMessage: String?
    @ObservationIgnored public var onEffectiveLanguageChange: ((AppLanguage) -> Void)?

    private let defaults: UserDefaults
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let preferredLanguagesProvider: () -> [String]
    private var hasDockPolicyError = false
    @ObservationIgnored private var localeObserver: NSObjectProtocol?

    private static let dockKey = "showsDockIcon"
    private static let selectionPopupKey = "showsSelectionPopup"
    private static let languagePreferenceKey = "languagePreference"

    public init(
        defaults: UserDefaults,
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { policy in
            NSApplication.shared.activationPolicy() == policy || NSApplication.shared.setActivationPolicy(policy)
        },
        preferredLanguagesProvider: @escaping () -> [String] = { Locale.preferredLanguages }
    ) {
        self.defaults = defaults
        self.preferredLanguagesProvider = preferredLanguagesProvider
        self.applyPolicy = applyPolicy
        self.showsDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        self.showsSelectionPopup = defaults.object(forKey: Self.selectionPopupKey) as? Bool ?? true
        let rawPref = defaults.string(forKey: Self.languagePreferenceKey)
        let pref = rawPref.flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        self.languagePreference = pref
        self.effectiveLanguage = pref.resolved(preferredLanguages: preferredLanguagesProvider())

        self.localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemLanguageIfNeeded()
            }
        }
    }

    isolated deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    public func apply() {
        setShowsDockIcon(showsDockIcon)
    }

    public func setShowsDockIcon(_ visible: Bool) {
        guard applyPolicy(visible ? .regular : .accessory) else {
            hasDockPolicyError = true
            errorMessage = AppStrings.dockIconError(in: effectiveLanguage)
            return
        }
        showsDockIcon = visible
        defaults.set(visible, forKey: Self.dockKey)
        hasDockPolicyError = false
        errorMessage = nil
    }

    public func setShowsSelectionPopup(_ enabled: Bool) {
        showsSelectionPopup = enabled
        defaults.set(enabled, forKey: Self.selectionPopupKey)
    }

    public func setLanguagePreference(_ preference: AppLanguagePreference) {
        languagePreference = preference
        defaults.set(preference.rawValue, forKey: Self.languagePreferenceKey)
        updateEffectiveLanguage(preference.resolved(preferredLanguages: preferredLanguagesProvider()))
    }

    public func refreshSystemLanguageIfNeeded() {
        guard languagePreference == .system else { return }
        updateEffectiveLanguage(languagePreference.resolved(preferredLanguages: preferredLanguagesProvider()))
    }

    private func updateEffectiveLanguage(_ resolved: AppLanguage) {
        let changed = (effectiveLanguage != resolved)
        effectiveLanguage = resolved
        if hasDockPolicyError {
            errorMessage = AppStrings.dockIconError(in: resolved)
        }
        if changed {
            onEffectiveLanguageChange?(resolved)
        }
    }
}

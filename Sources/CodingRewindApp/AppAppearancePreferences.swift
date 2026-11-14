// SPDX-License-Identifier: MIT

import AppKit
import Observation

@MainActor
@Observable
public final class AppAppearancePreferences {
    public private(set) var showsDockIcon: Bool
    public private(set) var showsSelectionPopup: Bool
    public private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Bool
    private static let dockKey = "showsDockIcon"
    private static let selectionPopupKey = "showsSelectionPopup"

    public init(
        defaults: UserDefaults,
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { policy in
            NSApplication.shared.activationPolicy() == policy || NSApplication.shared.setActivationPolicy(policy)
        }
    ) {
        self.defaults = defaults
        self.applyPolicy = applyPolicy
        self.showsDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        self.showsSelectionPopup = defaults.object(forKey: Self.selectionPopupKey) as? Bool ?? true
    }

    public func apply() {
        setShowsDockIcon(showsDockIcon)
    }

    public func setShowsDockIcon(_ visible: Bool) {
        guard applyPolicy(visible ? .regular : .accessory) else {
            errorMessage = "无法更改 Dock 图标的显示状态，请重新打开应用后再试。"
            return
        }
        showsDockIcon = visible
        defaults.set(visible, forKey: Self.dockKey)
        errorMessage = nil
    }

    public func setShowsSelectionPopup(_ enabled: Bool) {
        showsSelectionPopup = enabled
        defaults.set(enabled, forKey: Self.selectionPopupKey)
    }
}

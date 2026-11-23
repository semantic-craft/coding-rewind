// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import Observation

public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case captureSelection
    case toggleHUD
    case quickCapture

    public var id: String { rawValue }
    public func title(in language: AppLanguage) -> String {
        AppStrings.shortcutTitle(self, in: language)
    }
    public var title: String { title(in: .zhHans) }
    public var defaultShortcut: KeyboardShortcuts.Shortcut? {
        switch self {
        case .captureSelection:
            .init(.s, modifiers: [.control, .option, .shift, .command])
        case .toggleHUD:
            .init(.r, modifiers: [.control, .option])
        case .quickCapture:
            nil
        }
    }
    public var name: KeyboardShortcuts.Name { .init(rawValue, initial: defaultShortcut) }
    public var command: AppCommand {
        switch self {
        case .captureSelection: .captureSelectionHotkey
        case .toggleHUD: .toggleHUD
        case .quickCapture: .quickCapture
        }
    }
}

@MainActor
@Observable
public final class AppShortcuts {
    public private(set) var revision = 0
    public var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            validationMessages.removeAll()
            revision &+= 1
        }
    }
    public private(set) var validationMessages: [ShortcutAction: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuItems: [ShortcutAction: [NSMenuItem]] = [:]

    public static func configurePreferences(environment: [String: String], dataDirectory: URL) {
        KeyboardShortcuts.configure(userDefaults: AppPreferences.userDefaults(environment: environment, dataDirectory: dataDirectory))
    }

    private static let captureSelectionSchemaKey = "CodingRewind.captureSelectionShortcutSchemaVersion"
    private static let legacyCaptureSelectionShortcut = KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option])

    public init(language: AppLanguage = .zhHans, onCommand: @escaping @MainActor (AppCommand) -> Void) {
        self.language = language
        Self.migrateCaptureSelectionShortcutIfNeeded()
        for action in ShortcutAction.allCases {
            KeyboardShortcuts.onKeyUp(for: action.name) { onCommand(action.command) }
        }
        for notification in [KeyboardShortcuts.registrationStateDidChange, .shortcutByNameDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                let changedName = note.keyboardShortcutsName
                MainActor.assumeIsolated {
                    if notification == .shortcutByNameDidChange,
                       let name = changedName,
                       let action = ShortcutAction(rawValue: name.rawValue) {
                        self?.validationMessages[action] = nil
                    }
                    self?.refresh()
                }
            })
        }
    }

    private static func migrateCaptureSelectionShortcutIfNeeded() {
        let defaults = KeyboardShortcuts.configuredUserDefaults
        guard defaults.integer(forKey: captureSelectionSchemaKey) < 2 else { return }
        defer { defaults.set(2, forKey: captureSelectionSchemaKey) }

        guard let raw = defaults.object(forKey: "KeyboardShortcuts_captureSelection") as? String,
              let stored = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: Data(raw.utf8)),
              stored == legacyCaptureSelectionShortcut else {
            return
        }

        guard let newDefault = ShortcutAction.captureSelection.defaultShortcut,
              !ShortcutAction.allCases.contains(where: { $0 != .captureSelection && $0.name.shortcut == newDefault }) else {
            return
        }

        KeyboardShortcuts.setShortcut(newDefault, for: ShortcutAction.captureSelection.name)
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for action in ShortcutAction.allCases { KeyboardShortcuts.removeHandler(for: action.name) }
    }

    public func shortcut(for action: ShortcutAction) -> KeyboardShortcuts.Shortcut? {
        _ = revision
        return action.name.shortcut
    }

    public func state(for action: ShortcutAction) -> KeyboardShortcuts.RegistrationState {
        _ = revision
        return KeyboardShortcuts.registrationState(for: action.name)
    }

    public func hint(for action: ShortcutAction) -> String {
        let value = shortcut(for: action)?.description ?? ""
        switch state(for: action) {
        case .active: return value
        case .paused: return AppStrings.shortcutPausedHint(value: value, in: language)
        case .unassigned: return AppStrings.shortcutDisabled(in: language)
        case .failed: return AppStrings.shortcutFailedHint(value: value, in: language)
        }
    }

    public func instruction(for action: ShortcutAction) -> String {
        let actionTitle = action.title(in: language)
        switch state(for: action) {
        case .active:
            return AppStrings.shortcutInstructionActive(action, hint: hint(for: action), in: language)
        case .unassigned:
            return AppStrings.shortcutInstructionUnassigned(title: actionTitle, in: language)
        case .paused:
            return AppStrings.shortcutInstructionPaused(title: actionTitle, in: language)
        case .failed:
            return AppStrings.shortcutInstructionFailed(title: actionTitle, in: language)
        }
    }

    public func statusText(for action: ShortcutAction) -> String {
        switch state(for: action) {
        case .active: return AppStrings.shortcutStatusActive(in: language)
        case .unassigned: return AppStrings.shortcutDisabled(in: language)
        case .paused: return AppStrings.shortcutStatusPaused(in: language)
        case .failed(let status): return AppStrings.shortcutStatusFailed(status: Int(status), in: language)
        }
    }

    public func validate(_ shortcut: KeyboardShortcuts.Shortcut, for action: ShortcutAction) -> KeyboardShortcuts.ValidationResult {
        if shortcut.modifiers.intersection([.command, .control, .option]).isEmpty,
           shortcut.key?.isFunctionKey != true {
            return .disallow(reason: AppStrings.shortcutValidationNeedsModifier(in: language))
        }
        if shortcut.isTakenBySystem {
            return .disallow(reason: AppStrings.shortcutValidationSystemTaken(in: language))
        }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && $0.name.shortcut == shortcut }) {
            return .disallow(reason: AppStrings.shortcutValidationDuplicateAction(otherTitle: other.title(in: language), in: language))
        }
        if let menu = NSApplication.shared.mainMenu,
           let conflict = shortcut.menuItemWithMatchingShortcut(in: menu, excluding: Set(menuItems[action] ?? [])) {
            return .disallow(reason: AppStrings.shortcutValidationMenuConflict(menuTitle: conflict.title, in: language))
        }
        return .allow
    }

    @discardableResult
    public func set(_ shortcut: KeyboardShortcuts.Shortcut?, for action: ShortcutAction) -> Bool {
        if let shortcut, case .disallow(let reason) = validate(shortcut, for: action) {
            validationMessages[action] = reason
            return false
        }
        validationMessages[action] = nil
        KeyboardShortcuts.setShortcut(shortcut, for: action.name)
        return true
    }

    public func restoreDefault(for action: ShortcutAction) { set(action.defaultShortcut, for: action) }
    public func retry(_ action: ShortcutAction) { KeyboardShortcuts.retryRegistration(for: action.name) }

    public func resetBoundMenuItems() {
        menuItems.removeAll()
    }

    public func bindMenuItem(_ item: NSMenuItem, to action: ShortcutAction) {
        menuItems[action, default: []].append(item)
        item.setShortcut(state(for: action) == .active ? shortcut(for: action) : nil)
    }

    public func applyMenuShortcut(to item: NSMenuItem, for action: ShortcutAction) {
        item.setShortcut(state(for: action) == .active ? shortcut(for: action) : nil)
    }

    private func refresh() {
        revision &+= 1
        for (action, items) in menuItems {
            for item in items { applyMenuShortcut(to: item, for: action) }
        }
    }
}

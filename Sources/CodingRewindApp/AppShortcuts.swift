// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import KeyboardShortcuts
import Observation

public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case captureSelection
    case toggleHUD

    public var id: String { rawValue }
    public var title: String { self == .captureSelection ? "捕获当前选段" : "切换速览浮窗" }
    public var defaultShortcut: KeyboardShortcuts.Shortcut {
        .init(self == .captureSelection ? .s : .r, modifiers: [.control, .option])
    }
    public var name: KeyboardShortcuts.Name { .init(rawValue, initial: defaultShortcut) }
    public var command: AppCommand { self == .captureSelection ? .captureSelectionHotkey : .toggleHUD }
}

@MainActor
@Observable
public final class AppShortcuts {
    public private(set) var revision = 0
    public private(set) var validationMessages: [ShortcutAction: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuItems: [ShortcutAction: [NSMenuItem]] = [:]

    public static func preferencesSuite(environment: [String: String], dataDirectory: URL) -> String? {
        guard environment["CODING_REWIND_QA"] == "1" else { return nil }
        if let suite = environment["CODING_REWIND_SHORTCUTS_SUITE"], suite.hasPrefix("dev.codingrewind.qa."), suite.count > 20 {
            return suite
        }
        let digest = SHA256.hash(data: Data(dataDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return "dev.codingrewind.qa.shortcuts.\(digest)"
    }

    public static func configurePreferences(environment: [String: String], dataDirectory: URL) {
        if let suite = preferencesSuite(environment: environment, dataDirectory: dataDirectory) {
            guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Invalid QA preferences suite") }
            KeyboardShortcuts.configure(userDefaults: defaults)
        } else {
            KeyboardShortcuts.configure(userDefaults: .standard)
        }
    }

    public init(onCommand: @escaping @MainActor (AppCommand) -> Void) {
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
        let value = shortcut(for: action).map(String.init(describing:)) ?? ""
        switch state(for: action) {
        case .active: return value
        case .paused: return value.isEmpty ? "已关闭" : "\(value)（暂停）"
        case .unassigned: return "已关闭"
        case .failed: return "\(value)（未生效）"
        }
    }

    public func instruction(for action: ShortcutAction) -> String {
        switch state(for: action) {
        case .active:
            return action == .captureSelection
                ? "选中文本后按 \(hint(for: action))，即可暂存选段"
                : "按 \(hint(for: action)) 速览近 72 小时热流卡片"
        case .unassigned: return "\(action.title)快捷键已关闭，可在设置中开启"
        case .paused: return "\(action.title)快捷键录制期间暂停"
        case .failed: return "\(action.title)快捷键未生效，请在设置中重试或改键"
        }
    }

    public func statusText(for action: ShortcutAction) -> String {
        switch state(for: action) {
        case .active: return "已生效"
        case .unassigned: return "已关闭"
        case .paused: return "录制期间暂停"
        case .failed(let status): return "未生效 · 系统注册失败（\(status)），请释放冲突后重试或改键"
        }
    }

    public func validate(_ shortcut: KeyboardShortcuts.Shortcut, for action: ShortcutAction) -> KeyboardShortcuts.ValidationResult {
        if shortcut.modifiers.intersection([.command, .control, .option]).isEmpty,
           shortcut.key?.isFunctionKey != true {
            return .disallow(reason: "字母等普通按键请至少搭配 ⌃、⌥、⌘ 中的一个修饰键。")
        }
        if shortcut.isTakenBySystem { return .disallow(reason: "此组合键已由系统使用，请选择其他快捷键。") }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && $0.name.shortcut == shortcut }) {
            return .disallow(reason: "此组合键已用于“\(other.title)”。")
        }
        if let menu = NSApplication.shared.mainMenu,
           let conflict = shortcut.menuItemWithMatchingShortcut(in: menu, excluding: Set(menuItems[action] ?? [])) {
            return .disallow(reason: "此组合键用于菜单“\(conflict.title)”，请选择其他快捷键。")
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

#if os(macOS)
import Foundation

nonisolated private final class ShortcutPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var defaults: UserDefaults = .standard
    private var hasBeenRead = false

    func configure(_ defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        precondition(!hasBeenRead, "Configure shortcut preferences before creating any Name or using the library.")
        self.defaults = defaults
    }

    func read() -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        hasBeenRead = true
        return defaults
    }
}

extension KeyboardShortcuts {
    nonisolated private static let preferences = ShortcutPreferences()

    /// Configure once, before creating any shortcut names. All shortcut persistence uses this store.
    nonisolated public static func configure(userDefaults: UserDefaults) {
        preferences.configure(userDefaults)
    }

    nonisolated static var userDefaults: UserDefaults { preferences.read() }
}
#endif

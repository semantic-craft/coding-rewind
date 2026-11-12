# KeyboardShortcuts

Vendored from [sindresorhus/KeyboardShortcuts 3.1.0](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58), peeled commit `772133d9dbe800fdac0473226822994c5c162c58`. The original MIT copyright and permission notice is in [license](license).

The package retains its manifest, source, localization resources and tests. The application uses this single implementation for recording, persistence, hotkey registration and menu tracking.

Local changes:

- Carbon registration uses `kEventHotKeyExclusive` at the existing registration call. Upstream passes zero, which permits the same key to be shared across processes. An existing exclusive registration causes a real failure. Existing shared registrations are accepted by macOS but are suppressed while the exclusive registration is active; this API does not enumerate or report every other application binding. This applies to initial registration and resume.

- `HotKey.swift` and `KeyboardShortcuts.swift` report `.active`, `.paused`, `.failed(OSStatus)` and `.unassigned` through `registrationState(for:)` and `registrationStateDidChange`. Initial registration, event-handler installation and resume failures preserve their status. `retryRegistration(for:)` retries a failed binding without changing its stored value. `isEnabled(for:)` now reflects the effective registration.
- `Preferences.swift` injects a UserDefaults store once, before any Name or library storage access. All library reads, writes, disabled values and initial defaults use this store. Ordinary application runs use `.standard`; QA and tests use dedicated suites.
- `Key.isFunctionKey` exposes the existing recorder key classification for the application validation rule. `Shortcut.menuItemWithMatchingShortcut(in:excluding:)` exposes the existing recursive menu conflict check with excluded owned items. `Notification.keyboardShortcutsName` and `.shortcutByNameDidChange` expose existing change notifications so the application can clear stale validation messages after a recorder edit.
- Menu raw-key routing pairs release with its accepted key-down, so releasing Hyper modifiers before the letter still invokes the key-up action once. Mode changes and unregistration discard pending releases.
- The two synchronous AppKit run-loop tests use XCTest. Under the Swift 6.4 async testing entry point, their nested event loop lets `swift_task_asyncMainDrainQueue` return before the remaining tests complete. The same events and assertions run to completion under the synchronous runner; the repository gate requires both runner completion summaries.
- Tests use an isolated preferences suite instead of the caller's standard defaults. Application regression tests additionally exercise real Carbon occupancy, resume failure, retry, clearing and menu state.

Run the upstream suite with `swift test --package-path Vendor/KeyboardShortcuts`. The repository's `scripts/check` runs it alongside the application tests. The bundle builder copies the generated `KeyboardShortcuts_KeyboardShortcuts.bundle` into the application's resources.

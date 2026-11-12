import Testing
import Carbon.HIToolbox
@testable import KeyboardShortcuts

extension KeyboardShortcutsTests {
    @Test("Menu release follows the accepted press after modifiers are released")
    func rawReleaseAfterModifiers() {
        let shortcut = KeyboardShortcuts.Shortcut(.f16, modifiers: [.control, .option, .shift, .command])
        let name = KeyboardShortcuts.Name("rawReleaseAfterModifiers", initial: shortcut)
        var calls = 0
        KeyboardShortcuts.onKeyUp(for: name) { calls += 1 }
        defer { KeyboardShortcuts.removeHandler(for: name) }
        #expect(HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers, isRepeat: false, eventKind: kEventRawKeyDown) == noErr)
        #expect(HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: 0, isRepeat: false, eventKind: kEventRawKeyUp) == noErr)
        #expect(HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers, isRepeat: false, eventKind: kEventRawKeyUp) == OSStatus(eventNotHandledErr))
        #expect(calls == 1)
    }

    @Test("Mode changes and rebinding discard pending menu releases")
    func staleRawReleasesAreDiscarded() {
        let shortcut = KeyboardShortcuts.Shortcut(.f16, modifiers: [.control, .option, .shift, .command])
        let name = KeyboardShortcuts.Name("staleRawRelease", initial: shortcut)
        var calls = 0
        KeyboardShortcuts.onKeyUp(for: name) { calls += 1 }
        defer { KeyboardShortcuts.removeHandler(for: name) }
        _ = HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers, isRepeat: false, eventKind: kEventRawKeyDown)
        KeyboardShortcuts.isPaused = true
        KeyboardShortcuts.isPaused = false
        #expect(HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: 0, isRepeat: false, eventKind: kEventRawKeyUp) == OSStatus(eventNotHandledErr))
        _ = HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers, isRepeat: false, eventKind: kEventRawKeyDown)
        KeyboardShortcuts.setShortcut(.init(.f16, modifiers: [.command, .control]), for: name)
        #expect(HotKeyCenter.shared.handleRawKeyEvent(keyCode: shortcut.carbonKeyCode, modifiers: 0, isRepeat: false, eventKind: kEventRawKeyUp) == OSStatus(eventNotHandledErr))
        #expect(calls == 0)
    }
}

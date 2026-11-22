// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
public final class LibraryWorkspaceWindow: NSWindow {
    var onPerformKeyEquivalent: ((NSEvent) -> Bool)?
    var onKeyDownEvent: ((NSEvent) -> Bool)?
    var onCancelEscape: (() -> Bool)?
    var onWillOrderOut: (() -> Void)?
    var onDidOrderOut: (() -> Void)?
    var onWillOrderIn: (() -> Void)?

    public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out {
            onWillOrderOut?()
            super.order(place, relativeTo: otherWin)
            onDidOrderOut?()
        } else {
            onWillOrderIn?()
            super.order(place, relativeTo: otherWin)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onPerformKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if onKeyDownEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if onCancelEscape?() == true {
            return
        }
        super.cancelOperation(sender)
    }
}

@MainActor
public final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private let focusModel = LibraryWindowFocusModel()
    private let onCommand: @MainActor (AppCommand) -> Void
    private var hostingView: NSHostingView<LibrarySplitRootView>?
    nonisolated(unsafe) private var notificationObservers: [any NSObjectProtocol] = []
    public private(set) var isContentMounted: Bool = false

    public init(
        coordinator: AppCoordinator,
        language: AppLanguage,
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) {
        self.coordinator = coordinator
        self.onCommand = onCommand

        let initialSize = NSSize(width: 1280, height: 800)
        let window = LibraryWorkspaceWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppStrings.libraryWindowTitle(in: language)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CodingRewindLibraryWindow")
        window.contentView = NSView()

        super.init(window: window)
        window.delegate = self

        window.onWillOrderIn = { [weak self] in
            self?.mountContentIfNeeded()
        }
        window.onWillOrderOut = { [weak self] in
            self?.resignHostedFirstResponderIfNeeded()
        }
        window.onDidOrderOut = { [weak self] in
            self?.unmountContentIfNeeded()
        }
        window.onPerformKeyEquivalent = { [weak self] event in
            self?.handlePerformKeyEquivalent(event) ?? false
        }
        window.onKeyDownEvent = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        window.onCancelEscape = { [weak self] in
            self?.handleEscapeKey() ?? false
        }

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: NSApplication.didHideNotification,
                object: NSApplication.shared,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.unmountContentIfNeeded()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.unmountContentIfNeeded()
                    }
                }
            },
            center.addObserver(
                forName: NSApplication.didUnhideNotification,
                object: NSApplication.shared,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self,
                              self.window?.isVisible == true,
                              self.window?.isMiniaturized == false else { return }
                        self.mountContentIfNeeded()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.window?.isVisible == true,
                              self.window?.isMiniaturized == false else { return }
                        self.mountContentIfNeeded()
                    }
                }
            }
        ]
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateLanguage(_ language: AppLanguage) {
        window?.title = AppStrings.libraryWindowTitle(in: language)
    }

    public func mountContentIfNeeded() {
        guard !isContentMounted, let window else { return }
        let hosting = NSHostingView(
            rootView: LibrarySplitRootView(
                coordinator: coordinator,
                focusModel: focusModel,
                onCommand: onCommand,
                onResignTextInput: { [weak self] in self?.resignTextInputIfNeeded() }
            )
        )
        hosting.sizingOptions = []
        window.contentView = hosting
        hostingView = hosting
        isContentMounted = true
    }

    public func unmountContentIfNeeded() {
        guard isContentMounted || hostingView != nil else { return }
        resignHostedFirstResponderIfNeeded()
        hostingView = nil
        window?.contentView = NSView()
        isContentMounted = false
    }

    public func presentAndFocus() {
        let wasMounted = isContentMounted
        mountContentIfNeeded()
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !wasMounted {
            window.layoutIfNeeded()
            if !window.makeFirstResponder(nil) {
                window.endEditing(for: nil)
            }
            let searchFocusToken = focusModel.searchFocusToken
            DispatchQueue.main.async { [weak self, weak mountedHosting = hostingView] in
                guard let self,
                      let mountedHosting,
                      self.isContentMounted,
                      self.hostingView === mountedHosting,
                      let window = self.window,
                      window.isVisible,
                      self.focusModel.searchFocusToken == searchFocusToken,
                      self.coordinator.conversationDraft == nil,
                      self.coordinator.placePicker == nil,
                      self.isEditingTextInput else {
                    return
                }
                if !window.makeFirstResponder(nil) {
                    window.endEditing(for: nil)
                }
            }
        } else if !(window.firstResponder is NSTextView) {
            window.makeFirstResponder(nil)
        }
    }

    public func focusDraftEditorIfPresent() {
        mountContentIfNeeded()
        guard let contentView = window?.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        guard let editor = Self.findDraftTextView(in: contentView) else { return }
        _ = window?.makeFirstResponder(editor)
    }

    public func commitDraftEditorIfPresent() {
        guard let contentView = window?.contentView,
              let editor = Self.findDraftTextView(in: contentView),
              editor.hasMarkedText() else {
            return
        }
        editor.unmarkText()
        coordinator.updateConversationDraftText(editor.string)
    }

    public func windowWillClose(_ notification: Notification) {
        unmountContentIfNeeded()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        unmountContentIfNeeded()
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        if window?.isVisible == true {
            mountContentIfNeeded()
        }
    }

    private static func findDraftTextView(in view: NSView) -> DraftPromptTextView? {
        if let draft = view as? DraftPromptTextView {
            return draft
        }
        for child in view.subviews {
            if let found = findDraftTextView(in: child) {
                return found
            }
        }
        return nil
    }

    private var isEditingTextInput: Bool {
        guard let responder = window?.firstResponder else { return false }
        return (responder is NSTextView) || (responder is NSText) || ((responder as? NSTextField)?.isEditable == true)
    }

    private var hasMarkedTextInput: Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    private func resignTextInputIfNeeded() {
        guard isEditingTextInput, let window else { return }
        if !window.makeFirstResponder(nil) {
            window.endEditing(for: nil)
        }
    }

    private func resignHostedFirstResponderIfNeeded() {
        guard let window,
              let hosting = hostingView,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: hosting) else {
            return
        }
        if !window.makeFirstResponder(nil) {
            window.endEditing(for: nil)
        }
    }

    private func handleEscapeKey() -> Bool {
        guard !hasMarkedTextInput else { return false }
        if coordinator.placePicker != nil {
            resignTextInputIfNeeded()
            coordinator.closePlacePicker()
            return true
        }
        if coordinator.pendingDeleteConfirmation != nil {
            coordinator.cancelDeleteConfirmation()
            return true
        }
        if coordinator.conversationDraft != nil {
            if !coordinator.isLaunchingConversation {
                resignTextInputIfNeeded()
                coordinator.dismissConversationDraft()
            }
            return true
        }
        if isEditingTextInput {
            resignTextInputIfNeeded()
            return true
        }
        return false
    }

    private func handlePerformKeyEquivalent(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, event.type == .keyDown else { return false }
        let modifiers = relevantModifiers(for: event)
        if hasMarkedTextInput {
            return false
        }
        if event.keyCode == 53, modifiers.isEmpty {
            return handleEscapeKey()
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command], key == "f" {
            focusModel.requestSearchFocus()
            return true
        }
        if modifiers == [.option] {
            if key == "1" || event.keyCode == 18 {
                dispatchIntent(.setLayoutMode(.bentoCards))
                return true
            }
            if key == "2" || event.keyCode == 19 {
                dispatchIntent(.setLayoutMode(.sessionTimeline))
                return true
            }
        }
        if modifiers == [.command], key == "i" {
            coordinator.isLibraryInspectorPresented.toggle()
            return true
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == [.command] {
            if coordinator.conversationDraft != nil {
                guard !coordinator.isLaunchingConversation else { return true }
                commitDraftEditorIfPresent()
                resignTextInputIfNeeded()
                let command: AppCommand = coordinator.effectiveConversationHost.prefersDirectDraftAction
                    ? .sendConversationDraft
                    : .copyDraftAndWakeHost
                onCommand(command)
                return true
            }
            onCommand(.launchConversation)
            return true
        }
        guard !isEditingTextInput, coordinator.conversationDraft == nil else { return false }
        if modifiers == [.command], key == "p" {
            return triggerPlacePickerShortcut()
        }
        if modifiers == [.command], key == "e" {
            return triggerArchiveShortcut()
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if modifiers == [.command] {
                return triggerDeleteShortcut(immediate: false)
            }
            if modifiers == [.command, .option] {
                return triggerDeleteShortcut(immediate: true)
            }
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true,
              !isEditingTextInput,
              !hasMarkedTextInput,
              coordinator.conversationDraft == nil,
              coordinator.placePicker == nil else {
            return false
        }
        let modifiers = relevantModifiers(for: event)
        guard modifiers.isEmpty else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == 53 {
            return handleEscapeKey()
        }
        if key == "j" || event.keyCode == 125 {
            dispatchIntent(.stepFocus(delta: 1))
            return true
        }
        if key == "k" || event.keyCode == 126 {
            dispatchIntent(.stepFocus(delta: -1))
            return true
        }
        if key == "1" {
            return triggerSuggestionShortcut(index: 0, advanceFocus: false)
        }
        if key == "2" {
            return triggerSuggestionShortcut(index: 1, advanceFocus: false)
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if coordinator.pendingDeleteConfirmation != nil {
                Task { @MainActor [weak coordinator] in
                    await coordinator?.confirmPendingDelete()
                }
                return true
            }
            if coordinator.libraryScope == .unplacedInbox {
                return triggerSuggestionShortcut(index: 0, advanceFocus: true)
            }
            return false
        }
        if key == "p" {
            return triggerPlacePickerShortcut()
        }
        if key == "e" {
            return triggerArchiveShortcut()
        }
        return false
    }

    private func dispatchIntent(_ intent: LibraryUserIntent) {
        Task { @MainActor [weak coordinator] in
            await coordinator?.handleLibraryIntent(intent)
        }
    }

    private func targetIDs() -> [String] {
        let checked = coordinator.checkedActionableCardIDs
        if !checked.isEmpty {
            return checked
        }
        if let focused = coordinator.libraryProjection.inspectedItem?.id {
            return [focused]
        }
        return []
    }

    private func triggerSuggestionShortcut(index: Int, advanceFocus: Bool) -> Bool {
        guard let item = coordinator.libraryProjection.inspectedItem,
              item.suggestedPlaces.indices.contains(index) else {
            return false
        }
        let ref = item.suggestedPlaces[index].place.ref
        dispatchIntent(.acceptSuggestedPlaces(clipID: item.id, refs: [ref], advanceFocus: advanceFocus))
        return true
    }

    private func triggerPlacePickerShortcut() -> Bool {
        guard let focusedID = coordinator.libraryProjection.inspectedItem?.id else { return false }
        dispatchIntent(.openPlacePicker(clipID: focusedID))
        return true
    }

    private func triggerArchiveShortcut() -> Bool {
        let ids = targetIDs()
        guard !ids.isEmpty else { return false }
        dispatchIntent(.archiveClips(ids))
        return true
    }

    private func triggerDeleteShortcut(immediate: Bool) -> Bool {
        let ids = targetIDs()
        guard !ids.isEmpty else { return false }
        dispatchIntent(.requestDelete(ids, immediate: immediate))
        return true
    }
}

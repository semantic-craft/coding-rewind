// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore

@MainActor
final class QuickCapturePanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let editor = NSTextView(frame: .zero)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let closeButton = NSButton()
    private let onSave: @MainActor (String) async -> SelectionCaptureOutcome
    private var language: AppLanguage
    private var isSaving = false

    init(language: AppLanguage, onSave: @escaping @MainActor (String) async -> SelectionCaptureOutcome) {
        self.language = language
        self.onSave = onSave
        super.init()

        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        for button in [saveButton, closeButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\u{1b}"
        status.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [status, closeButton, saveButton])
        let stack = NSStackView(views: [hint, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        NSLayoutConstraint.activate([hint, scroll, buttons].map {
            $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16)
        })
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        updateLanguage(language)
        updateControls()
    }

    static func menuTitle(in language: AppLanguage) -> String {
        language == .zhHans ? "快速暂存…" : "Quick Capture…"
    }

    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        window.title = language == .zhHans ? "快速暂存" : "Quick Capture"
        hint.stringValue = language == .zhHans ? "输入想法，或粘贴代码、日志、链接。" : "Type an idea or paste code, logs, or a link."
        editor.setAccessibilityLabel(language == .zhHans ? "片段原文" : "Clip text")
        saveButton.title = language == .zhHans ? "保存片段" : "Save Clip"
        closeButton.title = AppStrings.closeWindow(in: language)
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if !isSaving {
            window.makeFirstResponder(editor)
        }
    }

    func textDidChange(_ notification: Notification) {
        status.stringValue = ""
        updateControls()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isSaving
    }

    private func updateControls() {
        editor.isEditable = !isSaving
        closeButton.isEnabled = !isSaving
        window.standardWindowButton(.closeButton)?.isEnabled = !isSaving
        saveButton.isEnabled = !isSaving && !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func close() {
        window.performClose(nil)
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return }
        let text = editor.string
        isSaving = true
        status.stringValue = language == .zhHans ? "正在保存…" : "Saving…"
        updateControls()
        Task {
            let outcome = await onSave(text)
            isSaving = false
            switch outcome {
            case .saved, .queuedOffline:
                editor.string = ""
                status.stringValue = ""
                window.close()
            case .ignoredBusy:
                status.stringValue = language == .zhHans ? "正在保存另一条片段，请稍后再试。" : "Another clip is being saved. Try again shortly."
            case .failed(let error):
                status.stringValue = error.localizedDescription(in: language)
            }
            updateControls()
        }
    }
}

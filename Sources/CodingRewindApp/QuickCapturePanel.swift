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
    private let chooseFileButton = NSButton()
    private let pasteImageButton = NSButton()
    private let removeFileButton = NSButton()
    private let fileLabel = NSTextField(labelWithString: "")
    private let onSave: @MainActor (String, ClipOriginal?) async -> SelectionCaptureOutcome
    private var language: AppLanguage
    private var isSaving = false
    private var isPreparing = false
    private var preparedOriginal: QuickCaptureOriginal?

    init(language: AppLanguage, onSave: @escaping @MainActor (String, ClipOriginal?) async -> SelectionCaptureOutcome) {
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
        for button in [saveButton, closeButton, chooseFileButton, pasteImageButton, removeFileButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        closeButton.action = #selector(close)
        closeButton.keyEquivalent = "\u{1b}"
        status.textColor = .secondaryLabelColor
        chooseFileButton.action = #selector(chooseOriginalFile)
        pasteImageButton.action = #selector(pasteScreenshot)
        removeFileButton.action = #selector(removeOriginal)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fileActions = NSStackView(views: [chooseFileButton, pasteImageButton, fileLabel, removeFileButton])

        let buttons = NSStackView(views: [status, closeButton, saveButton])
        let stack = NSStackView(views: [hint, scroll, fileActions, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        NSLayoutConstraint.activate([hint, scroll, fileActions, buttons].map {
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
        chooseFileButton.title = language == .zhHans ? "选择文件…" : "Choose File…"
        pasteImageButton.title = language == .zhHans ? "粘贴截图" : "Paste Screenshot"
        removeFileButton.title = language == .zhHans ? "移除" : "Remove"
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
        !isSaving && !isPreparing
    }

    @objc private func chooseOriginalFile() {
        guard !isSaving, !isPreparing else { return }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        isPreparing = true
        updateControls()
        Task {
            guard await picker.beginSheetModal(for: window) == .OK, let url = picker.url else {
                isPreparing = false
                updateControls()
                return
            }
            await prepare(Task.detached { try QuickCaptureOriginal.readFile(url) })
        }
    }

    @objc private func pasteScreenshot() {
        guard !isSaving, !isPreparing else { return }
        let clipboard = NSPasteboard.general
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "Screenshot.png"), (.tiff, "Screenshot.tiff")
        ]
        guard let (type, filename) = imageTypes.first(where: { clipboard.types?.contains($0.0) == true }),
              let bytes = clipboard.data(forType: type), bytes.count <= ClipOriginal.maximumBytes else {
            status.stringValue = language == .zhHans ? "请复制一张不超过 8 MiB 的截图。" : "Copy a screenshot of at most 8 MiB."
            return
        }
        isPreparing = true
        updateControls()
        Task {
            await prepare(Task.detached { try QuickCaptureOriginal.prepare(filename: filename, bytes: bytes) })
        }
    }

    private func prepare(_ task: Task<QuickCaptureOriginal, any Error>) async {
        status.stringValue = language == .zhHans ? "正在读取文件和文字…" : "Reading file and text…"
        do {
            preparedOriginal = try await task.value
            if preparedOriginal?.derivedText != nil {
                status.stringValue = language == .zhHans ? "已提取供检索的文字。" : "Text extracted for search."
            } else {
                status.stringValue = ""
            }
        } catch {
            status.stringValue = (error as? RewindError)?.localizedDescription(in: language) ?? error.localizedDescription
        }
        isPreparing = false
        updateControls()
    }

    @objc private func removeOriginal() {
        preparedOriginal = nil
        status.stringValue = ""
        updateControls()
    }

    private func updateControls() {
        let idle = !isSaving && !isPreparing
        editor.isEditable = !isSaving
        chooseFileButton.isEnabled = idle
        pasteImageButton.isEnabled = idle
        removeFileButton.isEnabled = idle
        removeFileButton.isHidden = preparedOriginal == nil
        fileLabel.stringValue = preparedOriginal?.original.filename ?? ""
        closeButton.isEnabled = idle
        window.standardWindowButton(.closeButton)?.isEnabled = idle
        saveButton.isEnabled = idle && (preparedOriginal != nil || !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @objc private func close() {
        window.performClose(nil)
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return }
        let draft = editor.string
        let original = preparedOriginal?.original
        if original != nil, draft.utf8.count > 6200 {
            status.stringValue = language == .zhHans ? "文件说明超过 6200 字节，请缩短。" : "Shorten the file note to at most 6200 bytes."
            return
        }
        let heading = language == .zhHans ? "提取文字" : "Extracted text"
        let separator = draft.isEmpty ? "## \(heading)\n\n" : "\n\n## \(heading)\n\n"
        let text = preparedOriginal?.derivedText.map {
            let excerpt = QuickCaptureOriginal.bounded($0, to: 6200 - draft.utf8.count - separator.utf8.count)
            return excerpt.isEmpty ? draft : draft + separator + excerpt
        } ?? draft
        isSaving = true
        status.stringValue = language == .zhHans ? "正在保存…" : "Saving…"
        updateControls()
        Task {
            let outcome = await onSave(text, original)
            isSaving = false
            switch outcome {
            case .saved, .queuedOffline:
                editor.string = ""
                preparedOriginal = nil
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

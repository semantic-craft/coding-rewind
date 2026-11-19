// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
final class DraftPromptTextView: NSTextView {
    var onCancel: (() -> Void)?
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        _ = window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let hadMarked = hasMarkedText()
        super.keyDown(with: event)
        if hadMarked, event.keyCode == 53, flags.isEmpty, hasMarkedText() {
            discardMarkedComposition()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              !hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == [.command] {
            switch key {
            case "a":
                selectAll(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "v":
                guard isEditable else { return false }
                pasteAsPlainText(nil)
                return true
            case "x":
                guard isEditable else { return false }
                cut(nil)
                return true
            case "z":
                guard isEditable else { return false }
                undoManager?.undo()
                return true
            default:
                break
            }
        } else if flags == [.command, .shift], key == "z" {
            guard isEditable else { return false }
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            discardMarkedComposition()
            return
        }
        if let onCancel {
            onCancel()
        } else {
            super.cancelOperation(sender)
        }
    }

    func discardMarkedComposition() {
        inputContext?.discardMarkedText()
        if hasMarkedText() {
            let range = markedRange()
            if range.location != NSNotFound {
                setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: range)
            }
            unmarkText()
        }
    }
}

@MainActor
private struct DraftPromptEditorView: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let accessibilityLabel: String
    let onTextChange: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = DraftPromptTextView()
        textView.delegate = context.coordinator
        textView.onCancel = onCancel
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityIdentifier("hud.draft.editor")
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        guard let textView = scrollView.documentView as? DraftPromptTextView else { return }
        textView.isEditable = isEditable
        textView.onCancel = onCancel
        textView.setAccessibilityLabel(accessibilityLabel)
        if !textView.hasMarkedText(), textView.string != text {
            let previousSelection = textView.selectedRange()
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.undoManager?.removeAllActions()
            let clamped = min(previousSelection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            context.coordinator.isProgrammaticUpdate = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: @MainActor (String) -> Void
        var isProgrammaticUpdate = false

        init(onTextChange: @escaping @MainActor (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView,
                  !textView.hasMarkedText() else {
                return
            }
            onTextChange(textView.string)
        }
    }
}

@MainActor
struct HUDConversationDraftView: View {
    @Bindable var coordinator: AppCoordinator
    let draft: ConversationDraft
    let language: AppLanguage
    let onCommand: @MainActor (AppCommand) -> Void

    var body: some View {
        let host = coordinator.effectiveConversationHost
        let isDraftEmpty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let copyWakeTitle = AppStrings.draftCopyAndWakeButton(hostName: host.displayName, in: language)
        let sendDirectTitle = AppStrings.draftSendDirectButton(for: host, in: language)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppStrings.draftComposerTitle(count: draft.cardIDs.count, in: language))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(AppStrings.draftComposerSubtitle(in: language))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if draft.isEdited {
                    Button(AppStrings.draftResetButton(in: language)) {
                        coordinator.resetConversationDraft()
                    }
                    .rewindButtonRole(.secondary)
                    .controlSize(.mini)
                    .accessibilityIdentifier("hud.draft.reset")
                    .help(AppStrings.draftResetHelp(in: language))
                    .disabled(coordinator.isLaunchingConversation)
                }
                Button {
                    coordinator.dismissConversationDraft()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .rewindButtonRole(.toolbar)
                .accessibilityLabel(AppStrings.draftCloseLabel(in: language))
                .accessibilityIdentifier("hud.draft.close")
                .help(AppStrings.draftCloseLabel(in: language))
                .disabled(coordinator.isLaunchingConversation)
            }

            DraftPromptEditorView(
                text: draft.text,
                isEditable: !coordinator.isLaunchingConversation,
                accessibilityLabel: AppStrings.draftEditorAccessibilityLabel(in: language),
                onTextChange: { coordinator.updateConversationDraftText($0) },
                onCancel: {
                    guard !coordinator.isLaunchingConversation else { return }
                    coordinator.dismissConversationDraft()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
            )

            Divider()

            HStack(spacing: 10) {
                let hostLabel = AppStrings.conversationHostLabel(in: language)
                Picker(hostLabel, selection: Binding(
                    get: { coordinator.effectiveConversationHost },
                    set: { coordinator.selectConversationDraftHost($0) }
                )) {
                    ForEach(ConversationHost.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel(hostLabel)
                .accessibilityIdentifier("hud.draft.host")
                .disabled(coordinator.isLaunchingConversation || coordinator.activeConversationHost != nil)

                Toggle(
                    AppStrings.archiveOnLaunchTitle(for: host, in: language),
                    isOn: $coordinator.markSynthesizedOnLaunch
                )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("hud.draft.archiveOnLaunch")
                    .help(AppStrings.archiveOnLaunchHelp(for: host, in: language))
                    .disabled(coordinator.isLaunchingConversation)

                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                Button(AppStrings.draftBackButton(in: language)) {
                    coordinator.dismissConversationDraft()
                }
                .rewindButtonRole(.secondary)
                .accessibilityIdentifier("hud.draft.cancel")
                .disabled(coordinator.isLaunchingConversation)

                Spacer(minLength: 4)

                if host.prefersDirectDraftAction {
                    Button(copyWakeTitle) {
                        onCommand(.copyDraftAndWakeHost)
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityLabel(copyWakeTitle)
                    .accessibilityIdentifier("hud.draft.copyAndWake")
                    .help(AppStrings.draftCopyAndWakeHelp(for: host, in: language))
                    .disabled(isDraftEmpty || coordinator.isLaunchingConversation)

                    Button {
                        onCommand(.sendConversationDraft)
                    } label: {
                        HStack(spacing: 6) {
                            Text(sendDirectTitle)
                            Text("⌘↵")
                        }
                    }
                    .buttonStyle(RewindLaunchButtonStyle())
                    .accessibilityLabel(sendDirectTitle)
                    .accessibilityIdentifier("hud.draft.sendDirect")
                    .help(AppStrings.draftSendDirectHelp(for: host, in: language))
                    .disabled(isDraftEmpty || coordinator.isLaunchingConversation)
                } else {
                    Button(sendDirectTitle) {
                        onCommand(.sendConversationDraft)
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityLabel(sendDirectTitle)
                    .accessibilityIdentifier("hud.draft.sendDirect")
                    .help(AppStrings.draftSendDirectHelp(for: host, in: language))
                    .disabled(isDraftEmpty || coordinator.isLaunchingConversation)

                    Button {
                        onCommand(.copyDraftAndWakeHost)
                    } label: {
                        HStack(spacing: 6) {
                            Text(copyWakeTitle)
                            Text("⌘↵")
                        }
                    }
                    .buttonStyle(RewindLaunchButtonStyle())
                    .accessibilityLabel(copyWakeTitle)
                    .accessibilityIdentifier("hud.draft.copyAndWake")
                    .help(AppStrings.draftCopyAndWakeHelp(for: host, in: language))
                    .disabled(isDraftEmpty || coordinator.isLaunchingConversation)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.draft.container")
    }
}

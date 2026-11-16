// SPDX-License-Identifier: MIT
// Non-activating frosted-glass floating NSPanel pattern adapted from p0deje/Maccy (MIT).

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import SwiftUI

@MainActor
public final class QuickPeekHUDPanel: NSPanel {
    private let coordinator: AppCoordinator
    private let shortcuts: AppShortcuts
    private let updater: AppUpdater?
    private let onCommand: @MainActor (AppCommand) -> Void
    private let frosted: NSVisualEffectView
    private var hostingView: NSHostingView<QuickPeekHUDRootView>?

    public init(
        coordinator: AppCoordinator,
        shortcuts: AppShortcuts,
        updater: AppUpdater? = nil,
        onCommand: @escaping @MainActor (AppCommand) -> Void
    ) {
        self.coordinator = coordinator
        self.shortcuts = shortcuts
        self.updater = updater
        self.onCommand = onCommand
        let rect = NSRect(x: 0, y: 0, width: 480, height: 560)
        self.frosted = NSVisualEffectView(frame: rect)
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 440, height: 480)

        frosted.material = .hudWindow
        frosted.blendingMode = .withinWindow
        frosted.state = .active
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = 14
        frosted.layer?.masksToBounds = true

        contentView = frosted
        position(relativeTo: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidHide(_:)),
            name: NSApplication.didHideNotification,
            object: nil
        )
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        if coordinator.pendingDeleteConfirmation != nil {
            coordinator.cancelDeleteConfirmation()
            return
        }
        if coordinator.inspectedCardID != nil {
            coordinator.closeCardPreview()
            return
        }
        orderOut(sender)
    }

    public override func orderFrontRegardless() {
        mountContentIfNeeded()
        super.orderFrontRegardless()
    }

    public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out {
            resignHostedFirstResponderIfNeeded()
            super.order(place, relativeTo: otherWin)
            unmountContentIfNeeded()
            coordinator.dismissTransientHUDState()
        } else {
            mountContentIfNeeded()
            super.order(place, relativeTo: otherWin)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if hasMarkedTextInput {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = relevantModifiers(for: event)
        if event.keyCode == 53, modifiers.isEmpty {
            if coordinator.pendingDeleteConfirmation != nil {
                coordinator.cancelDeleteConfirmation()
                return true
            }
            if coordinator.inspectedCardID != nil {
                coordinator.closeCardPreview()
                return true
            }
        }
        if !isEditingTextInput {
            if event.keyCode == 51 || event.keyCode == 117 {
                if modifiers == [.command] {
                    Task { @MainActor [weak self] in
                        await self?.coordinator.requestDeleteTargetCards(bypassConfirmation: false)
                    }
                    return true
                }
                if modifiers == [.command, .option] {
                    Task { @MainActor [weak self] in
                        await self?.coordinator.requestDeleteTargetCards(bypassConfirmation: true)
                    }
                    return true
                }
            }
            if event.charactersIgnoringModifiers?.lowercased() == "e", modifiers == [.command] {
                Task { @MainActor [weak self] in
                    await self?.coordinator.archiveTargetCards()
                }
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "i", modifiers == [.command] {
                coordinator.toggleFocusedCardPreview()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func sendEvent(_ event: NSEvent) {
        if isVisible,
           event.type == .keyDown,
           !hasMarkedTextInput,
           !isEditingTextInput,
           coordinator.pendingDeleteConfirmation != nil,
           event.keyCode == 36 || event.keyCode == 76,
           relevantModifiers(for: event).isEmpty {
            Task { @MainActor [weak self] in
                await self?.coordinator.confirmPendingDelete()
            }
            return
        }
        super.sendEvent(event)
    }

    private var isEditingTextInput: Bool {
        (firstResponder is NSText) || ((firstResponder as? NSTextField)?.isEditable == true)
    }

    private var hasMarkedTextInput: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    @objc private func handleApplicationDidHide(_ notification: Notification) {
        unmountContentIfNeeded()
        coordinator.dismissTransientHUDState()
    }

    private func mountContentIfNeeded() {
        guard hostingView == nil else { return }
        let hosting = NSHostingView(
            rootView: QuickPeekHUDRootView(
                coordinator: coordinator,
                shortcuts: shortcuts,
                updater: updater,
                onClose: { [weak self] in self?.orderOut(nil) },
                onCommand: onCommand,
                onResignTextInput: { [weak self] in self?.resignTextInputIfNeeded() }
            )
        )
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        frosted.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: frosted.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: frosted.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: frosted.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: frosted.bottomAnchor)
        ])
        hostingView = hosting
        frosted.layoutSubtreeIfNeeded()
        recalculateKeyViewLoop()
        if firstResponder === self,
           let keyView = frosted.nextValidKeyView,
           !(keyView is NSTextField) {
            _ = makeFirstResponder(keyView)
        }
    }

    private func resignTextInputIfNeeded() {
        guard isEditingTextInput else { return }
        if !makeFirstResponder(nil) {
            endEditing(for: nil)
        }
    }

    private func resignHostedFirstResponderIfNeeded() {
        guard let hosting = hostingView,
              let responder = firstResponder as? NSView,
              responder.isDescendant(of: hosting) else {
            return
        }
        if !makeFirstResponder(nil) {
            endEditing(for: nil)
        }
    }

    private func unmountContentIfNeeded() {
        guard let hosting = hostingView else { return }
        resignHostedFirstResponderIfNeeded()
        hostingView = nil
        hosting.removeFromSuperview()
    }

    public func position(relativeTo anchorFrame: NSRect?) {
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 560
        let screen: NSScreen? = {
            if let anchor = anchorFrame {
                let mid = NSPoint(x: anchor.midX, y: anchor.midY)
                return NSScreen.screens.first(where: { $0.frame.contains(mid) || $0.frame.intersects(anchor) })
                    ?? NSScreen.main
                    ?? NSScreen.screens.first
            }
            return NSScreen.main ?? NSScreen.screens.first
        }()
        guard let screen else { return }
        let visible = screen.visibleFrame

        if let anchor = anchorFrame,
           anchor.width > 0,
           anchor.height > 0,
           screen.frame.intersects(anchor),
           anchor.minX >= screen.frame.minX,
           anchor.maxX <= screen.frame.maxX {
            let notchSafe: Bool
            if let auxRight = screen.auxiliaryTopRightArea, !auxRight.isEmpty {
                notchSafe = anchor.minX >= auxRight.minX - 4
            } else {
                notchSafe = true
            }
            if notchSafe {
                let bounds = visible.insetBy(dx: 12, dy: 12)
                let minX = bounds.minX
                let maxX = max(bounds.minX, bounds.maxX - panelWidth)
                let minY = bounds.minY
                let maxY = max(bounds.minY, bounds.maxY - panelHeight)
                let x = min(max(anchor.midX - panelWidth / 2, minX), maxX)
                let y = min(max(anchor.minY - 8 - panelHeight, minY), maxY)
                setFrame(NSRect(x: round(x), y: round(y), width: panelWidth, height: panelHeight), display: isVisible)
                return
            }
        }

        setFrame(
            NSRect(x: visible.maxX - 496, y: visible.maxY - 572, width: panelWidth, height: panelHeight),
            display: isVisible
        )
    }

    public func presentNonActivating(anchorFrame: NSRect? = nil) {
        if !isVisible {
            position(relativeTo: anchorFrame)
        }
        orderFrontRegardless()
    }

    public func presentAndFocus(anchorFrame: NSRect? = nil) {
        if !isVisible {
            position(relativeTo: anchorFrame)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    public func toggle(anchorFrame: NSRect? = nil) {
        if isVisible {
            orderOut(nil)
        } else {
            presentNonActivating(anchorFrame: anchorFrame)
        }
    }
}

@MainActor
public struct QuickPeekHUDRootView: View {
    @Bindable public var coordinator: AppCoordinator
    @Bindable public var shortcuts: AppShortcuts
    public var updater: AppUpdater?
    public let onClose: @MainActor () -> Void
    public let onCommand: @MainActor (AppCommand) -> Void
    private let onResignTextInput: @MainActor () -> Void

    @FocusState private var isSearchFocused: Bool

    public init(
        coordinator: AppCoordinator,
        shortcuts: AppShortcuts,
        updater: AppUpdater? = nil,
        onClose: @escaping @MainActor () -> Void,
        onCommand: @escaping @MainActor (AppCommand) -> Void,
        onResignTextInput: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.shortcuts = shortcuts
        self.updater = updater
        self.onClose = onClose
        self.onCommand = onCommand
        self.onResignTextInput = onResignTextInput
    }

    private var lang: AppLanguage {
        coordinator.language
    }

    private func requestDeleteCards(ids: [String], bypassConfirmation: Bool) {
        if !bypassConfirmation {
            isSearchFocused = false
            onResignTextInput()
        }
        Task { @MainActor in
            await coordinator.requestDeleteCards(ids: ids, bypassConfirmation: bypassConfirmation)
        }
    }

    public var body: some View {
        let captureTitle = ShortcutAction.captureSelection.title(in: lang)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                Text("Coding Rewind").font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    onCommand(.captureSelection)
                } label: {
                    HStack(spacing: 5) {
                        Label(captureTitle, systemImage: "plus.viewfinder")
                        Text(shortcuts.hint(for: .captureSelection))
                            .foregroundStyle(.secondary)
                    }
                }
                .rewindButtonRole(.secondary)
                .accessibilityLabel(captureTitle)
                .accessibilityIdentifier("hud.capture")
                .help(shortcuts.instruction(for: .captureSelection))
                Button {
                    onCommand(.refreshHotStream)
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .rewindButtonRole(.toolbar)
                .accessibilityLabel(AppStrings.syncNow(in: lang))
                .accessibilityIdentifier("hud.refresh")
                .help(AppStrings.syncNowHelp(in: lang))
                Button {
                    onCommand(.openSettings)
                } label: {
                    Image(systemName: "gearshape").frame(width: 22, height: 22)
                }
                .rewindButtonRole(.toolbar)
                .accessibilityLabel(AppStrings.settingsLabel(in: lang))
                .accessibilityIdentifier("hud.settings")
                .help(AppStrings.settingsShortcutHelp(in: lang))
                Button { onClose() } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .keyboardShortcut(.cancelAction)
                .rewindButtonRole(.toolbar)
                .accessibilityLabel(AppStrings.closeHUDLabel(in: lang))
                .accessibilityIdentifier("hud.close")
                .help(AppStrings.closeHUDHelp(in: lang))
            }
            if let updater, case .readyToInstall(let staged) = updater.state {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(AppStrings.updateReadyHUDTitle(version: staged.candidate.version, in: lang))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button(AppStrings.restartToUpdateShortButton(in: lang)) {
                        Task { @MainActor in
                            await updater.installReadyUpdateAndRelaunch()
                        }
                    }
                    .rewindButtonRole(.secondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("hud.restartToUpdate")
                }
                .padding(7)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if let msg = coordinator.bannerMessage {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isErrorBanner ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(coordinator.isErrorBanner ? .orange : .green)
                    Text(msg).font(.system(size: 11)).lineLimit(2)
                    Spacer()
                    Button { coordinator.bannerMessage = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .rewindButtonRole(.toolbar)
                    .accessibilityLabel(AppStrings.dismissBannerLabel(in: lang))
                }
                .padding(7)
                .background((coordinator.isErrorBanner ? Color.orange : Color.green).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppStrings.searchPlaceholder(in: lang), text: $coordinator.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .accessibilityLabel(AppStrings.searchAccessibilityLabel(in: lang))
                    .accessibilityIdentifier("hud.search")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Button(filter.label(in: lang)) { coordinator.statusFilter = filter }
                        .rewindButtonRole(.toolbar)
                        .font(.system(size: 11, weight: coordinator.statusFilter == filter ? .semibold : .regular))
                        .foregroundStyle(coordinator.statusFilter == filter ? Color.accentColor : Color.secondary)
                        .accessibilityAddTraits(coordinator.statusFilter == filter ? .isSelected : [])
                        .accessibilityIdentifier("hud.filter.\(filter.rawValue)")
                }
            }

            if coordinator.filteredCards.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(coordinator.filteredCards) { cardRow($0) }
                    }
                }
            }

            if let inspectedCard = coordinator.inspectedCard {
                HUDCardInspectorView(
                    card: inspectedCard,
                    detailState: coordinator.cardDetailState(for: inspectedCard.id),
                    language: lang,
                    onCopyText: { coordinator.copyClipText(inspectedCard.verbatimText) },
                    onSourceAction: { coordinator.performSourceAction(for: inspectedCard) },
                    onWakeAntigravity: { coordinator.wakeAntigravity() },
                    onCopySessionID: { coordinator.copySessionID($0) },
                    onRetry: { coordinator.reloadCardDetail(id: inspectedCard.id) },
                    onClose: { coordinator.closeCardPreview() }
                )
            }

            if coordinator.canEndUnarchivedConversation {
                Button(AppStrings.keepClipsSkipArchiveButton(in: lang)) {
                    coordinator.endUnarchivedConversation()
                }
                .rewindButtonRole(.secondary)
            }
            if coordinator.canEndUnconfirmedConversation {
                Button(
                    AppStrings.clearUnconfirmedButton(
                        hostName: coordinator.effectiveConversationHost.displayName,
                        in: lang
                    )
                ) {
                    coordinator.endUnconfirmedConversation()
                }
                .rewindButtonRole(.secondary)
            }
            if coordinator.confirmedConversation?.host == .codex {
                Button(AppStrings.openCodexChatButton(in: lang)) {
                    coordinator.reopenConfirmedConversation()
                }
                .rewindButtonRole(.secondary)
            }
            if let pending = coordinator.pendingDeleteConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                    Text(
                        AppStrings.deleteConfirmationMessage(
                            count: pending.cardIDs.count,
                            allOfflinePending: pending.allOfflinePending,
                            in: lang
                        )
                    )
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(AppStrings.cancelButton(in: lang)) {
                        coordinator.cancelDeleteConfirmation()
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityIdentifier("hud.confirmDelete.cancel")
                    Button(AppStrings.confirmDeleteButton(in: lang)) {
                        Task { @MainActor in
                            await coordinator.confirmPendingDelete()
                        }
                    }
                    .buttonStyle(RewindDestructiveButtonStyle())
                    .accessibilityIdentifier("hud.confirmDelete.confirm")
                    .disabled(coordinator.isMutatingCards)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                        }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hud.confirmDelete.bar")
            }
            Divider()
            HStack(spacing: 10) {
                Text(AppStrings.selectedCountText(count: coordinator.checkedCardIDs.count, in: lang))
                    .font(.system(size: 11, weight: .medium))
                Toggle(AppStrings.archiveOnLaunchTitle(in: lang), isOn: $coordinator.markSynthesizedOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("hud.archiveOnLaunch")
                    .help(AppStrings.archiveOnLaunchHelp(in: lang))
                Spacer(minLength: 4)
                let checkedIDs = coordinator.checkedActionableCardIDs
                if !checkedIDs.isEmpty {
                    let batchDisabled = coordinator.isMutatingCards
                        || checkedIDs.contains(where: { coordinator.isCardLocked($0) })
                    HStack(spacing: 6) {
                        Button(AppStrings.archiveSelectedShortButton(in: lang)) {
                            Task { @MainActor in
                                await coordinator.archiveCards(ids: coordinator.checkedActionableCardIDs)
                            }
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityIdentifier("hud.archiveSelected")
                        .help(AppStrings.archiveSelectedHelp(in: lang))
                        .disabled(batchDisabled)

                        Button(AppStrings.deleteSelectedShortButton(in: lang)) {
                            requestDeleteCards(
                                ids: coordinator.checkedActionableCardIDs,
                                bypassConfirmation: isOptionKeyHeld()
                            )
                        }
                        .rewindButtonRole(.secondary)
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("hud.deleteSelected")
                        .help(AppStrings.deleteSelectedHelp(in: lang))
                        .disabled(batchDisabled)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                let hostLabel = AppStrings.conversationHostLabel(in: lang)
                Picker(hostLabel, selection: Binding(
                    get: { coordinator.effectiveConversationHost },
                    set: { coordinator.conversationHost = $0 }
                )) {
                    ForEach(ConversationHost.allCases, id: \.self) { host in
                        Text(host.displayName).tag(host)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel(hostLabel)
                .accessibilityIdentifier("hud.conversationHost")
                .disabled(coordinator.isLaunchingConversation || coordinator.activeConversationHost != nil)
                Button {
                    onCommand(.launchConversation)
                } label: {
                    HStack(spacing: 6) {
                        Text(coordinator.conversationActionTitle)
                        Text("⌘↵")
                    }
                }
                .buttonStyle(RewindLaunchButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityLabel(coordinator.conversationActionTitle)
                .accessibilityIdentifier("hud.launch")
                .disabled(coordinator.checkedCardIDs.isEmpty || coordinator.isLaunchingConversation)
            }
        }
        .environment(\.locale, lang.locale)
        .padding(.top, 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(minWidth: 440, minHeight: 480)
        .onKeyPress(.space) {
            guard !isSearchFocused else { return .ignored }
            coordinator.toggleFocusedCardCheck()
            return .handled
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                Text(AppStrings.emptyStateHeading(isAllCardsEmpty: coordinator.cards.isEmpty, in: lang))
                    .font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("• \(shortcuts.instruction(for: .captureSelection))")
                Text(
                    AppStrings.emptyBulletToggleAndLaunch(
                        toggleInstruction: shortcuts.instruction(for: .toggleHUD),
                        in: lang
                    )
                )
                Text(AppStrings.emptyBulletMemosAndOffline(in: lang))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(AppStrings.settingsShortcutHelp(in: lang)) { onCommand(.openSettings) }
                    .rewindButtonRole(.secondary)
                if !coordinator.cards.isEmpty {
                    Button(AppStrings.clearFiltersButton(in: lang)) {
                        coordinator.searchText = ""
                        coordinator.statusFilter = .all
                    }
                    .rewindButtonRole(.toolbar)
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func cardRow(_ card: RewindCard) -> some View {
        let checked = coordinator.checkedCardIDs.contains(card.id)
        let isInspected = coordinator.inspectedCardID == card.id
        let isLocked = coordinator.isCardLocked(card.id)
        let isPendingDelete = coordinator.pendingDeleteConfirmation?.cardIDs.contains(card.id) == true
        return HUDCardRowView(
            card: card,
            isChecked: checked,
            isInspected: isInspected,
            isLocked: isLocked,
            isMutating: coordinator.isMutatingCards,
            isPendingDelete: isPendingDelete,
            language: lang,
            onToggleSelect: {
                coordinator.focusedCardID = card.id
                coordinator.toggleCheck(for: card.id)
            },
            onTogglePreview: {
                coordinator.toggleCardPreview(id: card.id)
            },
            onCopyText: {
                coordinator.copyClipText(card.verbatimText)
            },
            onSourceAction: {
                coordinator.performSourceAction(for: card)
            },
            onWakeAntigravity: {
                coordinator.wakeAntigravity()
            },
            onArchive: {
                Task { @MainActor in
                    await coordinator.archiveCards(ids: [card.id])
                }
            },
            onDelete: { bypass in
                requestDeleteCards(ids: [card.id], bypassConfirmation: bypass)
            }
        )
    }
}

@MainActor
private struct HUDCardRowView: View {
    let card: RewindCard
    let isChecked: Bool
    let isInspected: Bool
    let isLocked: Bool
    let isMutating: Bool
    let isPendingDelete: Bool
    let language: AppLanguage
    let onToggleSelect: () -> Void
    let onTogglePreview: () -> Void
    let onCopyText: () -> Void
    let onSourceAction: () -> Void
    let onWakeAntigravity: () -> Void
    let onArchive: () -> Void
    let onDelete: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        let backgroundColor: Color = isPendingDelete
            ? Color.red.opacity(0.10)
            : (isChecked ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        let actionOpacity = (isHovered || isChecked || isInspected || isPendingDelete) ? 0.95 : 0.55

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                Circle()
                    .fill(card.status == .ready ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(card.status.badgeText(in: language))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("#\(card.sourcePlatform)").font(.system(size: 10)).foregroundStyle(.secondary)
                if card.isOfflinePending {
                    Text(AppStrings.pendingSyncBadge(in: language))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        onTogglePreview()
                    } label: {
                        Text(AppStrings.contextPreviewButton(in: language))
                            .font(.system(size: 10, weight: isInspected ? .semibold : .regular))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .rewindButtonRole(.toolbar)
                    .focusEffectDisabled()
                    .foregroundStyle(isInspected ? Color.accentColor : Color.secondary)
                    .opacity(isInspected ? 1.0 : actionOpacity)
                    .accessibilityAddTraits(isInspected ? [.isSelected] : [])
                    .accessibilityIdentifier("hud.card.preview.\(card.id)")
                    .help(AppStrings.contextPreviewHelp(isInspected: isInspected, in: language))

                    if let locator = card.sourceLocator {
                        Button(AppStrings.sourceActionButton(for: locator, in: language)) {
                            onSourceAction()
                        }
                        .rewindButtonRole(.toolbar)
                        .focusEffectDisabled()
                        .font(.system(size: 10))
                        .accessibilityIdentifier("hud.card.source.\(card.id)")
                    }

                    Button {
                        onArchive()
                    } label: {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .rewindButtonRole(.toolbar)
                    .focusEffectDisabled()
                    .foregroundStyle(Color.secondary)
                    .opacity(actionOpacity)
                    .accessibilityIdentifier("hud.card.archive.\(card.id)")
                    .accessibilityLabel(AppStrings.archiveClipLabel(in: language))
                    .help(AppStrings.archiveClipHelp(in: language))
                    .disabled(isLocked || isMutating)

                    Button {
                        onDelete(isOptionKeyHeld())
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .rewindButtonRole(.toolbar)
                    .focusEffectDisabled()
                    .foregroundStyle((isHovered || isPendingDelete) ? Color.red : Color.secondary)
                    .opacity(actionOpacity)
                    .accessibilityIdentifier("hud.card.delete.\(card.id)")
                    .accessibilityLabel(AppStrings.deleteClipLabel(in: language))
                    .help(AppStrings.deleteClipHelp(in: language))
                    .disabled(isLocked || isMutating)
                }
            }
            if let title = card.title {
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            if let ctx = card.contextSummary {
                Text(ctx).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(card.verbatimText).font(.system(size: 11.5)).lineLimit(3).textSelection(.enabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(backgroundColor))
        .overlay {
            if isPendingDelete {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.red.opacity(0.65), lineWidth: 1)
            } else if isInspected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
        .onTapGesture {
            onToggleSelect()
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(AppStrings.toggleContextMenu(isInspected: isInspected, in: language)) {
                onTogglePreview()
            }

            Button(AppStrings.copyClipTextMenu(in: language)) {
                onCopyText()
            }

            if let locator = card.sourceLocator {
                Button(AppStrings.sourceActionButton(for: locator, in: language)) {
                    onSourceAction()
                }
                if case .antigravitySession = locator {
                    Button(AppStrings.wakeAntigravityButton(in: language)) {
                        onWakeAntigravity()
                    }
                }
            }

            Button(AppStrings.archiveClipLabel(in: language)) {
                onArchive()
            }
            .disabled(isLocked || isMutating)

            Divider()

            Button(AppStrings.deleteClipMenuEllipsis(in: language), role: .destructive) {
                onDelete(false)
            }
            .disabled(isLocked || isMutating)
        }
    }
}

@MainActor
private struct HUDCardInspectorView: View {
    let card: RewindCard
    let detailState: CardDetailLoadState
    let language: AppLanguage
    let onCopyText: () -> Void
    let onSourceAction: () -> Void
    let onWakeAntigravity: () -> Void
    let onCopySessionID: (String) -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var isTurnsExpanded = true
    @State private var isNotesExpanded = true

    private var resolvedDetail: CardDetail? {
        switch detailState {
        case .idle:
            return nil
        case .loading(let partial):
            return partial
        case .loaded(let detail):
            return detail
        case .failed(let partial, _):
            return partial
        }
    }

    var body: some View {
        let context = resolvedDetail?.context
        let notes = resolvedDetail?.notes ?? []
        let effectiveSessionID = card.effectiveSessionID(context: context)
        let formattedDate = card.createdAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(card.sourceTitle) · \(formattedDate)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(AppStrings.copyClipTextMenu(in: language)) {
                    onCopyText()
                }
                .rewindButtonRole(.toolbar)
                .focusEffectDisabled()
                .font(.system(size: 10.5))
                .accessibilityIdentifier("hud.inspector.copyText")
                .help(AppStrings.inspectorCopyTextHelp(in: language))

                if let locator = card.sourceLocator {
                    Button(AppStrings.sourceActionButton(for: locator, in: language)) {
                        onSourceAction()
                    }
                    .rewindButtonRole(.toolbar)
                    .focusEffectDisabled()
                    .font(.system(size: 10.5))
                    .accessibilityIdentifier("hud.inspector.sourceAction")

                    if case .antigravitySession = locator {
                        Button(AppStrings.wakeAntigravityButton(in: language)) {
                            onWakeAntigravity()
                        }
                        .rewindButtonRole(.toolbar)
                        .focusEffectDisabled()
                        .font(.system(size: 10.5))
                        .accessibilityIdentifier("hud.inspector.wakeAntigravity")
                    }
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .rewindButtonRole(.toolbar)
                .focusEffectDisabled()
                .accessibilityLabel(AppStrings.inspectorCloseLabel(in: language))
                .accessibilityIdentifier("hud.inspector.close")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if case .loading = detailState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(AppStrings.inspectorLoadingText(in: language))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("hud.inspector.loading")
                    } else if case .failed(_, let message) = detailState {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Button(AppStrings.inspectorRetryButton(in: language)) {
                                onRetry()
                            }
                            .rewindButtonRole(.secondary)
                            .controlSize(.mini)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.retry")
                        }
                    }

                    if let sessionID = effectiveSessionID {
                        HStack(spacing: 6) {
                            Text(AppStrings.inspectorSessionIDLabel(in: language))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(sessionID)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button(AppStrings.inspectorCopySessionIDButton(in: language)) {
                                onCopySessionID(sessionID)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .font(.system(size: 10))
                            .accessibilityIdentifier("hud.inspector.copySessionID")
                            .help(AppStrings.inspectorCopySessionIDHelp(in: language))
                        }
                    }

                    if let lead = context?.lead {
                        switch lead {
                        case .sessionOpening(let opening) where opening != (context?.prompt ?? ""):
                            inspectorSection(
                                heading: AppStrings.inspectorSessionOpeningHeading(in: language),
                                text: opening
                            )
                        case .pageLead(let pageLead):
                            inspectorSection(
                                heading: AppStrings.inspectorPageLeadHeading(in: language),
                                text: pageLead
                            )
                        default:
                            EmptyView()
                        }
                    }

                    if let prompt = context?.prompt, !prompt.isEmpty {
                        inspectorSection(
                            heading: AppStrings.inspectorPrecedingPromptHeading(in: language),
                            text: prompt
                        )
                    }

                    inspectorSection(
                        heading: AppStrings.inspectorFullExcerptHeading(in: language),
                        text: card.verbatimText
                    )

                    if let turns = context?.recentTurns, !turns.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                isTurnsExpanded.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isTurnsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(AppStrings.inspectorRecentTurnsHeading(count: turns.count, in: language))
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.toggleTurns")

                            if isTurnsExpanded {
                                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(turn.role)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(turn.text)
                                            .font(.system(size: 11))
                                            .textSelection(.enabled)
                                    }
                                    .padding(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                                }
                            }
                        }
                    }

                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                isNotesExpanded.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isNotesExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(AppStrings.inspectorNotesHeading(count: notes.count, in: language))
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .rewindButtonRole(.toolbar)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("hud.inspector.toggleNotes")

                            if isNotesExpanded {
                                ForEach(notes) { note in
                                    let noteDate = note.createdAt.formatted(
                                        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(note.author) · \(noteDate)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(note.content)
                                            .font(.system(size: 11))
                                            .textSelection(.enabled)
                                    }
                                    .padding(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.inspector")
    }

    private func inspectorSection(heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private func isOptionKeyHeld() -> Bool {
    if NSEvent.modifierFlags.contains(.option) {
        return true
    }
    guard let event = NSApp.currentEvent else { return false }
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
        return event.modifierFlags.contains(.option)
    default:
        return false
    }
}

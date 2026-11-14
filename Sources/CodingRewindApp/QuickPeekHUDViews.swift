// SPDX-License-Identifier: MIT
// Non-activating frosted-glass floating NSPanel pattern adapted from p0deje/Maccy (MIT).

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import SwiftUI

@MainActor
public final class QuickPeekHUDPanel: NSPanel {
    public init(
        coordinator: AppCoordinator,
        shortcuts: AppShortcuts,
        onInstallPlugin: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 560)
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

        let frosted = NSVisualEffectView(frame: rect)
        frosted.material = .hudWindow
        frosted.blendingMode = .withinWindow
        frosted.state = .active
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = 14
        frosted.layer?.masksToBounds = true

        let hosting = NSHostingView(
            rootView: QuickPeekHUDRootView(
                coordinator: coordinator,
                shortcuts: shortcuts,
                onClose: { [weak self] in self?.orderOut(nil) },
                onInstallPlugin: onInstallPlugin,
                onOpenSettings: onOpenSettings
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        frosted.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: frosted.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: frosted.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: frosted.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: frosted.bottomAnchor)
        ])
        contentView = frosted
        position(relativeTo: nil)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override func cancelOperation(_ sender: Any?) { orderOut(sender) }

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
                setFrame(NSRect(x: round(x), y: round(y), width: panelWidth, height: panelHeight), display: true)
                return
            }
        }

        setFrame(
            NSRect(x: visible.maxX - 496, y: visible.maxY - 572, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    public func positionNearTopRight() {
        position(relativeTo: nil)
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
    public let onClose: @MainActor () -> Void
    public let onInstallPlugin: @MainActor () -> Void
    public let onOpenSettings: @MainActor () -> Void

    @FocusState private var isSearchFocused: Bool

    public init(
        coordinator: AppCoordinator,
        shortcuts: AppShortcuts,
        onClose: @escaping @MainActor () -> Void,
        onInstallPlugin: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.shortcuts = shortcuts
        self.onClose = onClose
        self.onInstallPlugin = onInstallPlugin
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                Text("Coding Rewind").font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    Task { await coordinator.captureSelection() }
                } label: {
                    HStack(spacing: 5) {
                        Label("保存所选文本", systemImage: "plus.viewfinder")
                        Text(shortcuts.hint(for: .captureSelection))
                            .foregroundStyle(.secondary)
                    }
                }
                .rewindButtonRole(.secondary)
                .accessibilityLabel("保存所选文本")
                .accessibilityIdentifier("hud.capture")
                .help(shortcuts.instruction(for: .captureSelection))
                Button {
                    Task { await coordinator.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .rewindButtonRole(.toolbar)
                .accessibilityLabel("立即同步")
                .accessibilityIdentifier("hud.refresh")
                .help("立即同步 (⌘R)")
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape").frame(width: 22, height: 22)
                }
                .rewindButtonRole(.toolbar)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("hud.settings")
                .help("设置… (⌘,)")
                Button { onClose() } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .keyboardShortcut(.cancelAction)
                .rewindButtonRole(.toolbar)
                .accessibilityLabel("关闭片段浮窗")
                .accessibilityIdentifier("hud.close")
                .help("关闭片段浮窗 (Esc)")
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
                    .accessibilityLabel("关闭提示")
                }
                .padding(7)
                .background((coordinator.isErrorBanner ? Color.orange : Color.green).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题、摘要或原文…", text: $coordinator.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .accessibilityLabel("搜索标题、摘要或原文")
                    .accessibilityIdentifier("hud.search")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Button(filter.label) { coordinator.statusFilter = filter }
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

            if coordinator.canEndUnarchivedConversation {
                Button("暂不归档，保留片段") {
                    coordinator.endUnarchivedConversation()
                }
                .rewindButtonRole(.secondary)
            }
            if coordinator.canEndUnconfirmedConversation {
                Button("已检查 \(coordinator.effectiveConversationHost.displayName)，清除待确认请求") {
                    coordinator.endUnconfirmedConversation()
                }
                .rewindButtonRole(.secondary)
            }
            if coordinator.confirmedConversation?.host == .codex {
                Button("打开 Codex 对话") { coordinator.reopenConfirmedConversation() }
                    .rewindButtonRole(.secondary)
            }
            Divider()
            HStack(spacing: 12) {
                Text("已选 \(coordinator.checkedCardIDs.count) 条")
                    .font(.system(size: 11, weight: .medium))
                Toggle("发送后归档", isOn: $coordinator.markSynthesizedOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("hud.archiveOnLaunch")
                    .help("成功发送后，将所选片段从最近片段列表中移除。原文仍保留在 Memos 中。")
                Spacer()
            }
            HStack(spacing: 8) {
                Spacer()
                Picker("对话应用", selection: Binding(
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
                .accessibilityLabel("对话应用")
                .accessibilityIdentifier("hud.conversationHost")
                .disabled(coordinator.isLaunchingConversation || coordinator.activeConversationHost != nil)
                Button {
                    Task { await coordinator.launchChecked() }
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
                Text(coordinator.cards.isEmpty ? "近 72 小时没有保存的片段" : "没有符合筛选条件的片段")
                    .font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("• \(shortcuts.instruction(for: .captureSelection))")
                Text("• \(shortcuts.instruction(for: .toggleHUD))，勾选片段后按 ⌘↵ 开始对话")
                Text("• 在设置中填写 Memos 服务地址和访问令牌后可同步，离线时也可保存片段")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("设置… (⌘,)") { onOpenSettings() }
                    .rewindButtonRole(.secondary)
                if !coordinator.cards.isEmpty {
                    Button("清除筛选") {
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                Circle()
                    .fill(card.status == .ready ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(card.status.badgeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("#\(card.sourcePlatform)").font(.system(size: 10)).foregroundStyle(.secondary)
                if card.isOfflinePending {
                    Text("待同步").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Spacer()
                if let url = card.reopenURL {
                    Button("查看来源 ↗") { coordinator.onOpenURL?(url) }
                        .rewindButtonRole(.toolbar)
                        .font(.system(size: 10))
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
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.focusedCardID = card.id
            coordinator.toggleCheck(for: card.id)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(checked ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
    }
}

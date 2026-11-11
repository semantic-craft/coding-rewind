// SPDX-License-Identifier: MIT
// Non-activating frosted-glass floating NSPanel pattern adapted from p0deje/Maccy (MIT).

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
public final class QuickPeekHUDPanel: NSPanel {
    public init(coordinator: AppCoordinator, onInstallPlugin: @escaping @MainActor () -> Void) {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 560)
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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

        let hosting = NSHostingView(rootView: QuickPeekHUDRootView(coordinator: coordinator, onClose: { [weak self] in self?.orderOut(nil) }, onInstallPlugin: onInstallPlugin))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        frosted.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: frosted.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: frosted.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: frosted.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: frosted.bottomAnchor)
        ])
        contentView = frosted
        positionNearTopRight()
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override func cancelOperation(_ sender: Any?) { orderOut(sender) }
    public func positionNearTopRight() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        setFrame(NSRect(x: visible.maxX - 500, y: visible.maxY - 580, width: 480, height: 560), display: true)
    }
    public func presentNonActivating() { if !isVisible { positionNearTopRight() }; orderFrontRegardless() }
    public func toggle() { isVisible ? orderOut(nil) : presentNonActivating() }
}

@MainActor
public struct QuickPeekHUDRootView: View {
    @Bindable public var coordinator: AppCoordinator
    public let onClose: @MainActor () -> Void
    public let onInstallPlugin: @MainActor () -> Void

    @State private var showSettings = false
    @State private var markSynthesizedOnLaunch = false
    @State private var urlDraft = ""
    @State private var tokenDraft = ""
    @FocusState private var isSearchFocused: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.cyan)
                Text("Coding Rewind").font(.system(size: 13, weight: .bold))
                Spacer()
                Button { Task { await coordinator.captureSelection() } } label: { Label("抓选段 ⌃⌥S", systemImage: "plus.viewfinder").font(.system(size: 11)) }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { Task { await coordinator.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                Button {
                    urlDraft = coordinator.paths.readConfiguredMemosURLString(environment: coordinator.environment) ?? ""
                    tokenDraft = ""
                    coordinator.refreshPluginStatus()
                    showSettings = true
                } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                Button("关闭") { onClose() }.keyboardShortcut(.cancelAction).buttonStyle(.borderless).font(.system(size: 11))
            }
            if let msg = coordinator.bannerMessage {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isErrorBanner ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(coordinator.isErrorBanner ? .orange : .green)
                    Text(msg).font(.system(size: 11)).lineLimit(2)
                    Spacer()
                    Button("×") { coordinator.bannerMessage = nil }.buttonStyle(.borderless)
                }
                .padding(7).background((coordinator.isErrorBanner ? Color.orange : Color.green).opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题、上下文或选中原文…", text: $coordinator.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($isSearchFocused)
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Button(filter.label) { coordinator.statusFilter = filter }.buttonStyle(.plain)
                        .font(.system(size: 10, weight: coordinator.statusFilter == filter ? .semibold : .regular))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(coordinator.statusFilter == filter ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06)).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))

            ScrollView { LazyVStack(alignment: .leading, spacing: 7) { ForEach(coordinator.filteredCards) { cardRow($0) } } }
            Divider()
            HStack(spacing: 8) {
                Text("已选 \(coordinator.checkedCardIDs.count) 张").font(.system(size: 11, weight: .medium))
                Toggle("开聊后归档", isOn: $markSynthesizedOnLaunch).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("在 Antigravity 开聊 ⌘↵") { Task { await coordinator.launchCheckedInAntigravity(markSynthesized: markSynthesizedOnLaunch) } }
                    .buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.top, 24).padding(.horizontal, 12).padding(.bottom, 10).frame(minWidth: 440, minHeight: 480)
        .onKeyPress(.space) {
            guard !isSearchFocused else { return .ignored }
            coordinator.toggleFocusedCardCheck()
            return .handled
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private func cardRow(_ card: RewindCard) -> some View {
        let checked = coordinator.checkedCardIDs.contains(card.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Color.accentColor : .secondary)
                Text(card.status.badgeText).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1).background((card.status == .ready ? Color.green : Color.orange).opacity(0.2)).clipShape(Capsule())
                Text("#\(card.sourcePlatform)").font(.system(size: 10)).foregroundStyle(.secondary)
                if card.isOfflinePending { Text("离线待同步").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                if let url = card.reopenURL { Button("原出处 ↗") { coordinator.onOpenURL?(url) }.buttonStyle(.borderless).font(.system(size: 10)) }
            }
            if let title = card.title { Text(title).font(.system(size: 12, weight: .semibold)) }
            if let ctx = card.contextSummary { Text(ctx).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            Text(card.verbatimText).font(.system(size: 11.5)).lineLimit(3).textSelection(.enabled)
        }
        .padding(8).contentShape(Rectangle())
        .onTapGesture { coordinator.focusedCardID = card.id; coordinator.toggleCheck(for: card.id) }
        .background(RoundedRectangle(cornerRadius: 8).fill(checked ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coding Rewind 设置").font(.headline)
            TextField("Memos 地址 (https://...)", text: $urlDraft).textFieldStyle(.roundedBorder)
            SecureField("Memos Access Token (仅存 macOS 钥匙串)", text: $tokenDraft).textFieldStyle(.roundedBorder)
            HStack {
                Button("安装或检查 Antigravity 插件") { onInstallPlugin() }
                Text(coordinator.pluginStatusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { showSettings = false }
                Button("保存") {
                    try? coordinator.saveCredentials(memosURL: urlDraft, token: tokenDraft)
                    showSettings = false
                    Task { await coordinator.refresh() }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16).frame(width: 400)
    }
}

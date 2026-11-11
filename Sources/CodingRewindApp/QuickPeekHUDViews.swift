// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
public final class QuickPeekHUDPanel: NSPanel {
    private let coordinator: AppCoordinator
    private let onRequestOpenStudio: @MainActor (Bool) -> Void

    public init(
        coordinator: AppCoordinator,
        onRequestOpenStudio: @escaping @MainActor (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.onRequestOpenStudio = onRequestOpenStudio

        let initialRect = NSRect(x: 0, y: 0, width: 520, height: 640)
        super.init(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = "Coding-Rewind 近期灵感暂存 HUD"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isFloatingPanel = true
        self.level = .floating
        self.becomesKeyOnlyIfNeeded = true
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView(frame: initialRect)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .withinWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true

        let rootView = QuickPeekHUDRootView(
            coordinator: coordinator,
            onOpenStudio: { openDrawer in
                onRequestOpenStudio(openDrawer)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        self.contentView = visualEffect
        positionNearTopRight()
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        false
    }

    public func positionNearTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = min(650, visible.height - 60)
        let x = visible.maxX - panelWidth - 24
        let y = visible.maxY - panelHeight - 18
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    public func presentNonActivating() {
        if !isVisible {
            positionNearTopRight()
        }
        orderFrontRegardless()
    }

    public func presentBanner(_ banner: HUDBanner) {
        coordinator.hudBanner = banner
        presentNonActivating()
    }

    public func toggleQuickPeek() {
        if isVisible {
            orderOut(nil)
        } else {
            presentNonActivating()
        }
    }
}

@MainActor
public struct QuickPeekHUDRootView: View {
    @Bindable public var coordinator: AppCoordinator
    public let onOpenStudio: @MainActor (Bool) -> Void

    @State private var isConfirmingDeleteAll: Bool = false
    @State private var draftNoteMap: [ClipID: String] = [:]
    @State private var draftTitleMap: [ClipID: String] = [:]
    @State private var draftTagsMap: [ClipID: String] = [:]

    public init(
        coordinator: AppCoordinator,
        onOpenStudio: @escaping @MainActor (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.onOpenStudio = onOpenStudio
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            if let banner = coordinator.hudBanner {
                bannerView(banner)
            }
            searchAndScopeBar
            Divider()
            clipListSection
            Divider()
            bottomActionBar
        }
        .padding(.top, 26)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(minWidth: 480, minHeight: 540)
        .confirmationDialog(
            "确认清空全部暂存片段与检索索引？",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("确认清空全部 (含 FTS5 索引)", role: .destructive) {
                Task {
                    await coordinator.deleteAllClips(confirmation: .userConfirmedPurgeAll)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会同步删除本地 SQLite 归档中的所有片段以及 FTS5 倒排索引词条，且不可恢复。")
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("Coding-Rewind")
                        .font(.system(size: 14, weight: .bold))
                    Text("Gear 1 · 速览浮窗 · 不抢焦点")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.16))
                        .clipShape(Capsule())
                }
                Text("跨 Antigravity 2.x 与网页聊天的近 72 小时灵感暂存池")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await coordinator.captureSelectionFromHotkey()
                }
            } label: {
                Label("抓选段 ⌃⌥S", systemImage: "plus.viewfinder")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("静默捕获当前前台应用的选中文本")

            Button {
                coordinator.simulateFailedCaptureBanner()
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("演示捕获失败时的显式错误横幅 (M2.5)")
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: HUDBanner) -> some View {
        switch banner {
        case .capturedToast(_, let excerptPreview, let sourceLabel):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已静默存入暂存池 · \(sourceLabel)")
                        .font(.system(size: 11, weight: .semibold))
                    Text(excerptPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("关闭") {
                    coordinator.dismissBanner()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(8)
            .background(Color.green.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .errorBanner(let title, let detail):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button("知道了") {
                    coordinator.dismissBanner()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(9)
            .background(Color.red.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var searchAndScopeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "用自然语言找回，如：不抢焦点的浮窗 / 钩子空输出拒绝调用...",
                    text: Binding(
                        get: { coordinator.hudSearchText },
                        set: { newValue in
                            coordinator.hudSearchText = newValue
                            Task { await coordinator.refreshHUDClips() }
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))

                if !coordinator.hudSearchText.isEmpty {
                    Button("清除") {
                        coordinator.hudSearchText = ""
                        Task { await coordinator.refreshHUDClips() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                ForEach(ClipScope.allCases, id: \.self) { scope in
                    let isSelected = coordinator.hudScope == scope
                    Button {
                        coordinator.hudScope = scope
                        Task { await coordinator.refreshHUDClips() }
                    } label: {
                        Text(scope.displayTitle)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("共 \(coordinator.hudClips.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clipListSection: some View {
        ScrollView {
            if coordinator.hudClips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(
                        coordinator.hudSearchText.isEmpty
                            ? "当前筛选范围内暂无灵感片段"
                            : "没有找到与「\(coordinator.hudSearchText)」相关的片段 (M4.3 相关性阈值过滤)"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.hudClips) { clip in
                        clipCard(clip)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func clipCard(_ clip: Clip) -> some View {
        let isChecked = coordinator.checkedClipIDs.contains(clip.id)
        let isExpanded = coordinator.expandedHUDClipIDs.contains(clip.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    coordinator.toggleCheckmark(for: clip.id)
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

                Text(clip.source.displayBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(Capsule())

                Text(clip.lifecycle().displayName)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(Capsule())

                switch clip.promptContext {
                case .captured:
                    Text("含原问题")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                case .missing:
                    Text("原问题缺失")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }

                Spacer()

                Text(Self.relativeTimestamp(from: clip.capturedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button(isExpanded ? "收起详情" : "详情/批注") {
                    if !isExpanded {
                        draftTitleMap[clip.id] = clip.annotation.title ?? ""
                        draftTagsMap[clip.id] = clip.annotation.tags.joined(separator: ", ")
                        draftNoteMap[clip.id] = clip.annotation.userNote ?? ""
                    }
                    coordinator.toggleHUDCardExpansion(for: clip.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            }

            if let title = clip.annotation.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(clip.excerpt)
                .font(.system(size: 12))
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)

            if let note = clip.annotation.userNote, !note.isEmpty, !isExpanded {
                HStack(spacing: 4) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("用户笔记: \(note)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    switch clip.promptContext {
                    case .captured(let prompt):
                        Text("触发原问题: \(prompt)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .missing:
                        Text("触发原问题: 原问题缺失（捕获时未取到上下文，不编造虚假问题）")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Text("后补注释（与选中原文严格分离，非必填）")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        TextField(
                            "可选标题...",
                            text: Binding(
                                get: { draftTitleMap[clip.id] ?? clip.annotation.title ?? "" },
                                set: { draftTitleMap[clip.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                        TextField(
                            "可选标签 (逗号分隔)...",
                            text: Binding(
                                get: { draftTagsMap[clip.id] ?? clip.annotation.tags.joined(separator: ", ") },
                                set: { draftTagsMap[clip.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    }

                    HStack(spacing: 6) {
                        TextField(
                            "可选个人笔记 (独立于原文保存与导出)...",
                            text: Binding(
                                get: { draftNoteMap[clip.id] ?? clip.annotation.userNote ?? "" },
                                set: { draftNoteMap[clip.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                        Button("保存批注") {
                            let t = draftTitleMap[clip.id]
                            let tags = draftTagsMap[clip.id] ?? ""
                            let n = draftNoteMap[clip.id]
                            Task {
                                await coordinator.saveAnnotation(
                                    for: clip.id,
                                    title: t,
                                    tagsText: tags,
                                    userNote: n
                                )
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        if clip.source.reopenURL != nil {
                            Button("回到原出处") {
                                _ = coordinator.openSourceOrigin(for: clip)
                            }
                            .controlSize(.small)
                        }
                        Button(clip.lifecycle() == .archived ? "重新激活回热窗" : "移入已冷却") {
                            Task {
                                await coordinator.toggleClipCooling(clip)
                            }
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("删除此条", role: .destructive) {
                            Task {
                                await coordinator.deleteClip(id: clip.id)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isChecked ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isChecked ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var bottomActionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("已勾选 \(coordinator.checkedClipIDs.count) 条")
                    .font(.system(size: 11, weight: .semibold))

                Button("展开递进写作舱 ⌘↵") {
                    onOpenStudio(false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])

                Button("展开写作舱 + 对话侧栏") {
                    onOpenStudio(true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("复制 /rewind 指令") {
                    _ = coordinator.copyAntigravitySlashCommand()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("导出 Markdown") {
                    exportWithSavePanel(format: .markdown)
                }
                .controlSize(.mini)

                Button("导出 JSON") {
                    exportWithSavePanel(format: .json)
                }
                .controlSize(.mini)

                Spacer()

                Button("清空全部归档", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
                .controlSize(.mini)
            }
        }
    }

    private func exportWithSavePanel(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .markdown ? "coding-rewind-export.md" : "coding-rewind-export.json"
        if panel.runModal() == .OK, let url = panel.url {
            let selected = coordinator.checkedClipIDs.isEmpty ? nil : coordinator.checkedClipIDs
            Task {
                try? await coordinator.exportClips(ids: selected, format: format, to: url)
            }
        }
    }

    private static func relativeTimestamp(from date: Date) -> String {
        let delta = max(0, Int(Date().timeIntervalSince(date)))
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(delta / 60) 分钟前" }
        if delta < 86400 { return "\(delta / 3600) 小时前" }
        return "\(delta / 86400) 天前"
    }
}

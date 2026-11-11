// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
public final class WritingStudioWindowController: NSWindowController {
    private let coordinator: AppCoordinator
    private let onInstallPlugin: @MainActor () -> Void

    public init(
        coordinator: AppCoordinator,
        onInstallPlugin: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.onInstallPlugin = onInstallPlugin

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Coding-Rewind 递进写作舱 (Gear 2 · A+C 互动成文)"
        window.minSize = NSSize(width: 920, height: 600)
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.center()

        let rootView = WritingStudioRootView(
            coordinator: coordinator,
            onInstallPlugin: onInstallPlugin
        )
        window.contentView = NSHostingView(rootView: rootView)
        super.init(window: window)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func presentStudio() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
public struct WritingStudioRootView: View {
    @Bindable public var coordinator: AppCoordinator
    public let onInstallPlugin: @MainActor () -> Void

    public init(
        coordinator: AppCoordinator,
        onInstallPlugin: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.onInstallPlugin = onInstallPlugin
    }

    public var body: some View {
        VStack(spacing: 0) {
            studioTopToolbar
            Divider()
            if let state = coordinator.studioState {
                pinnedClipsStrip(state: state)
                Divider()
                HStack(spacing: 0) {
                    markdownEditorZone(state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if state.isChatDrawerPresented {
                        Divider()
                        ScenarioAChatDrawerView(coordinator: coordinator)
                            .frame(width: 400)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Text("尚未加载成文草稿")
                        .font(.headline)
                    Button("从已勾选片段创建草稿") {
                        Task {
                            await coordinator.openStudioWithCheckedClips()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var studioTopToolbar: some View {
        let isDrawerOpen = coordinator.studioState?.isChatDrawerPresented ?? false
        let draftFilename = coordinator.studioState?.activeDraft.id.filename ?? "draft.md"
        let backendBadge = coordinator.studioState?.synthesisBackend.privacyBadgeText ?? "本地离线推演 · 零外发"

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(draftFilename)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text("Gear 2 · 递进写作舱")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(Capsule())
            }

            Button {
                Task {
                    await coordinator.saveActiveDraft()
                }
            } label: {
                Label("保存草稿 ⌘S", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("s", modifiers: [.command])

            Divider()
                .frame(height: 18)

            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                Text(backendBadge)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14))
            .clipShape(Capsule())

            Button {
                onInstallPlugin()
            } label: {
                Label("安装/检查 Antigravity 插件", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)

            Text(coordinator.antigravityStatusSummary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                coordinator.toggleChatDrawer()
            } label: {
                Label(
                    isDrawerOpen ? "收起对话侧栏" : "展开对话侧栏",
                    systemImage: "sidebar.right"
                )
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(isDrawerOpen ? .indigo : .blue)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func pinnedClipsStrip(state: StudioWorkspaceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    "顶部对照片段条 (\(state.pinnedClips.count) 条已固定 · 点击卡片展开原问题与个人批注)",
                    systemImage: "pin.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

                Spacer()

                Button("复制 /rewind 到 Antigravity") {
                    _ = coordinator.copyAntigravitySlashCommand(for: state.pinnedClips)
                }
                .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(state.pinnedClips) { clip in
                        pinnedClipCard(clip, isExpanded: state.expandedClipIDs.contains(clip.id))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private func pinnedClipCard(_ clip: Clip, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("[^clip-\(clip.id.shortCode)]")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(clip.source.displayBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(Capsule())

                switch clip.promptContext {
                case .captured:
                    Text("含原问题")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                case .missing:
                    Text("原问题缺失")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                Button(isExpanded ? "收起" : "展开") {
                    coordinator.togglePinnedClipExpansion(clip.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .fixedSize(horizontal: true, vertical: false)
            }

            if let title = clip.annotation.title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }

            Text(clip.excerpt)
                .font(.system(size: 11))
                .lineLimit(isExpanded ? 6 : 2)
                .textSelection(.enabled)

            if isExpanded {
                Divider()
                switch clip.promptContext {
                case .captured(let prompt):
                    Text("原问题: \(prompt)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                case .missing:
                    Text("原问题: 原问题缺失（未采集到触发该段落的原始提问）")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if let note = clip.annotation.userNote {
                    Text("用户笔记: \(note)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Button("插入原文引用") {
                        let quote = "> \(clip.excerpt.replacingOccurrences(of: "\n", with: "\n> "))"
                        Task {
                            await coordinator.insertIntoDraft(quote, citing: [clip.id])
                        }
                    }
                    .controlSize(.mini)

                    if clip.source.reopenURL != nil {
                        Button("回到原出处") {
                            _ = coordinator.openSourceOrigin(for: clip)
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(9)
        .frame(width: isExpanded ? 410 : 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func markdownEditorZone(state: StudioWorkspaceState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inlineSynthesisBar(state: state)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("场景 C · 本地可读 Markdown 成文草稿")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("磁盘路径: \(state.activeDraft.fileURL.path)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TextEditor(
                    text: Binding(
                        get: { coordinator.studioState?.activeDraft.markdownBody ?? "" },
                        set: { newValue in
                            coordinator.updateDraftBody(newValue)
                        }
                    )
                )
                .font(.system(size: 13, design: .monospaced))
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func inlineSynthesisBar(state: StudioWorkspaceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("内联 ⌘J 场景 A 推演条 · 围绕顶部已固定片段一键提炼并插入草稿")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(state.isInlineSynthesisBarPresented ? "折叠 ⌘J" : "展开 ⌘J") {
                    if var current = coordinator.studioState {
                        current.isInlineSynthesisBarPresented.toggle()
                        coordinator.studioState = current
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("j", modifiers: [.command])
            }

            if state.isInlineSynthesisBarPresented {
                HStack(spacing: 8) {
                    TextField(
                        "输入成文指令，如：串联这几条片段写一段「非阻塞钩子与不抢焦点 HUD」的设计理由...",
                        text: Binding(
                            get: { coordinator.studioState?.inlinePromptText ?? "" },
                            set: { newValue in
                                if var current = coordinator.studioState {
                                    current.inlinePromptText = newValue
                                    coordinator.studioState = current
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                    Button("插入正文并记下引用") {
                        let prompt = coordinator.studioState?.inlinePromptText ?? ""
                        Task {
                            await coordinator.submitStudioPrompt(prompt, insertDirectlyIntoDraft: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isSynthesizing)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}

@MainActor
public struct ScenarioAChatDrawerView: View {
    @Bindable public var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let state = coordinator.studioState
        let turns = state?.chatConversation ?? []

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.indigo)
                        Text("场景 A · 片段追问对话侧栏")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text("围绕已勾选的 \(state?.pinnedClips.count ?? 0) 条片段持续追问，满意段落一键插入左侧草稿")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("收起侧栏") {
                    coordinator.toggleChatDrawer()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Button("提炼核心论点") {
                    Task {
                        await coordinator.submitStudioPrompt("提炼已勾选片段的核心架构取舍与证据链")
                    }
                }
                .controlSize(.mini)

                Button("对比片段异同") {
                    Task {
                        await coordinator.submitStudioPrompt("对比各条暂存片段解决的痛点与边界条件")
                    }
                }
                .controlSize(.mini)

                Button("生成 /rewind 指令") {
                    _ = coordinator.copyAntigravitySlashCommand()
                }
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)

            Divider()

            ScrollView {
                if turns.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("基于已勾选片段开启多轮追问推演")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("推演结果保留 [插入左侧草稿] 与 [复制 /rewind 到 Antigravity] 按钮")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(turns) { turn in
                            chatTurnCard(turn)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField(
                    "基于勾选片段继续追问...",
                    text: Binding(
                        get: { coordinator.studioState?.chatInputText ?? "" },
                        set: { newValue in
                            if var current = coordinator.studioState {
                                current.chatInputText = newValue
                                coordinator.studioState = current
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                Button("发送追问") {
                    let prompt = coordinator.studioState?.chatInputText ?? ""
                    Task {
                        await coordinator.submitStudioPrompt(prompt, insertDirectlyIntoDraft: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private func chatTurnCard(_ turn: ChatTurn) -> some View {
        let isUser = turn.role == .user
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isUser ? "追问指令" : "推演回复 (含引用锚点)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isUser ? Color.secondary : Color.indigo)
                Spacer()
                if !turn.citedClipIDs.isEmpty {
                    Text("引用 \(turn.citedClipIDs.count) 条片段")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text(turn.text)
                .font(.system(size: 11))
                .textSelection(.enabled)

            if !isUser {
                HStack(spacing: 8) {
                    Button("插入左侧草稿") {
                        Task {
                            await coordinator.insertIntoDraft(turn.text, citing: Set(turn.citedClipIDs))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("复制 /rewind 到 Antigravity") {
                        _ = coordinator.copyAntigravitySlashCommand(instruction: turn.text)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isUser ? Color.primary.opacity(0.06) : Color.indigo.opacity(0.10))
        )
    }
}

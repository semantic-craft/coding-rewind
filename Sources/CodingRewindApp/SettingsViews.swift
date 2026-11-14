// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case connection
    case keyboard
    case integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .connection: "连接"
        case .keyboard: "快捷键"
        case .integrations: "集成与权限"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .connection: "network"
        case .keyboard: "keyboard"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

enum SettingsLayout {
    static let contentSize = NSSize(width: 720, height: 520)
    static let sidebarWidth: CGFloat = 160
}

@MainActor
public struct SettingsFormView: View {
    @Bindable public var coordinator: AppCoordinator
    @Bindable public var appearance: AppAppearancePreferences
    @Bindable public var shortcuts: AppShortcuts
    public let onInstallPlugin: @MainActor () -> Void
    public let onRequestAccessibility: @MainActor () -> Void
    public let onClose: @MainActor () -> Void

    @State private var selectedPage: SettingsPage = .general
    @State private var urlDraft: String
    @State private var tokenDraft = ""
    @State private var isAccessibilityTrusted: Bool
    @State private var saveMessage: String?
    @State private var saveFailed = false

    public init(
        coordinator: AppCoordinator,
        appearance: AppAppearancePreferences,
        shortcuts: AppShortcuts,
        onInstallPlugin: @escaping @MainActor () -> Void,
        onRequestAccessibility: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.appearance = appearance
        self.shortcuts = shortcuts
        self.onInstallPlugin = onInstallPlugin
        self.onRequestAccessibility = onRequestAccessibility
        self.onClose = onClose
        self._urlDraft = State(initialValue: coordinator.connectionSettings.memosURL)
        self._isAccessibilityTrusted = State(initialValue: MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false))
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPage?>(
                get: { selectedPage },
                set: { if let page = $0 { selectedPage = page } }
            )) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(page)
                        .accessibilityIdentifier("settings.navigation.\(page.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("设置分类")
            .frame(width: SettingsLayout.sidebarWidth)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(selectedPage.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch selectedPage {
                        case .general: general
                        case .connection: connection
                        case .keyboard: keyboard
                        case .integrations: integrations
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: SettingsLayout.contentSize.width, height: SettingsLayout.contentSize.height)
        .onExitCommand(perform: onClose)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isAccessibilityTrusted = MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false)
            coordinator.refreshPluginStatus()
        }
    }

    private var general: some View {
        Group {
            SettingsSection("应用入口") {
                SettingsRow("在 Dock 中显示", help: "修改立即保存。点击 Dock 图标或从 Finder 重新打开应用，可唤出速览浮窗。") {
                    Toggle("在 Dock 中显示", isOn: Binding(
                        get: { appearance.showsDockIcon },
                        set: { appearance.setShowsDockIcon($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.dock")
                }
                if let error = appearance.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            SettingsSection("菜单栏") {
                SettingsRow("图标与入口", help: "菜单栏图标提供速览、捕获选段与设置入口。找不到图标时，请在系统设置的“菜单栏”中允许 CodingRewind。") {
                    Button("打开系统菜单栏设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .rewindButtonRole(.secondary)
                }
            }
        }
    }

    private var connection: some View {
        Group {
            SettingsSection("Memos 服务") {
                SettingsRow("服务地址", layout: .field, help: coordinator.connectionSettings.isURLManaged
                            ? "地址由启动环境管理，请在启动配置中修改。" : nil) {
                    TextField("服务地址", text: $urlDraft, prompt: Text("https://memos.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.connectionSettings.isURLManaged)
                        .accessibilityIdentifier("settings.memosURL")
                }
                Divider()
                SettingsRow("访问令牌", layout: .field, help: coordinator.connectionSettings.isTokenManaged
                            ? "令牌由启动环境提供，此处不会读取或改写。"
                            : "新令牌保存到 macOS 钥匙串，不写入配置文件。") {
                    SecureField("访问令牌", text: $tokenDraft, prompt: Text("留空则保留现有令牌"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.connectionSettings.isTokenManaged)
                        .accessibilityIdentifier("settings.memosToken")
                }
                SettingsRow("", layout: .field) {
                    Button("保存连接设置") { saveConnection() }
                        .rewindButtonRole(.primary)
                        .disabled(coordinator.connectionSettings.isURLManaged && coordinator.connectionSettings.isTokenManaged)
                        .accessibilityIdentifier("settings.saveConnection")
                }
                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(saveFailed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            SettingsSection("最近操作") {
                SettingsRow("连接检查") {
                    Button("立即同步") { Task { await coordinator.refresh() } }
                        .rewindButtonRole(.secondary)
                }
                Text(coordinator.bannerMessage ?? "点击立即同步检查连接。")
                    .font(.callout)
                    .foregroundStyle(coordinator.isErrorBanner ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var keyboard: some View {
        SettingsSection("全局快捷键") {
            Text("修改立即生效并保存；清空即关闭。Hyper = ⌃⌥⇧⌘。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ShortcutAction.allCases) { action in
                Divider()
                SettingsRow(action.title, help: shortcuts.validationMessages[action] ?? shortcuts.statusText(for: action)) {
                    HStack(spacing: 8) {
                        KeyboardShortcuts.Recorder(for: action.name)
                            .shortcutValidation { shortcuts.validate($0, for: action) }
                            .keyboardShortcutsConflictPolicy(.init(systemShortcut: .block))
                        Button("恢复默认") { shortcuts.restoreDefault(for: action) }
                            .rewindButtonRole(.secondary)
                        if case .failed = shortcuts.state(for: action) {
                            Button("重试") { shortcuts.retry(action) }
                                .rewindButtonRole(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var integrations: some View {
        Group {
            SettingsSection("Antigravity 插件") {
                SettingsRow("插件状态", help: coordinator.pluginStatusText) {
                    Button("安装或检查插件") {
                        onInstallPlugin()
                        coordinator.refreshPluginStatus()
                    }
                    .rewindButtonRole(.secondary)
                }
            }
            SettingsSection("辅助功能") {
                SettingsRow("选区读取") {
                    Button("检查或开启权限…") {
                        onRequestAccessibility()
                        isAccessibilityTrusted = MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false)
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityLabel("检查或开启辅助功能权限")
                }
                Text(isAccessibilityTrusted ? "已授权，可读取前台选区。" : "未授权，捕获其他应用选区前需要开启。")
                    .font(.callout)
                    .foregroundStyle(isAccessibilityTrusted ? Color.secondary : Color.orange)
            }
        }
    }

    private func saveConnection() {
        do {
            try coordinator.saveCredentials(memosURL: urlDraft, token: tokenDraft)
            tokenDraft = ""
            saveFailed = false
            saveMessage = "已保存。可点击立即同步检查连接。"
        } catch {
            saveFailed = true
            saveMessage = error.localizedDescription
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

private struct SettingsRow<Content: View>: View {
    enum Layout {
        case preference
        case field
    }

    let title: String
    let layout: Layout
    let help: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, layout: Layout = .preference, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.layout = layout
        self.help = help
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            switch layout {
            case .preference:
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                    helpText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                content()
                    .fixedSize(horizontal: true, vertical: false)
            case .field:
                Text(title)
                    .frame(width: 104, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    content()
                    helpText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var helpText: some View {
        if let help {
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import SwiftUI

@MainActor
public struct SettingsFormView: View {
    @Bindable public var coordinator: AppCoordinator
    @Bindable public var appearance: AppAppearancePreferences
    @Bindable public var shortcuts: AppShortcuts
    public let onInstallPlugin: @MainActor () -> Void
    public let onRequestAccessibility: @MainActor () -> Void
    public let onClose: @MainActor () -> Void

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
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("通用", systemImage: "gearshape") }
                connection.tabItem { Label("连接", systemImage: "network") }
                keyboard.tabItem { Label("快捷键", systemImage: "keyboard") }
                integrations.tabItem { Label("集成与权限", systemImage: "puzzlepiece.extension") }
            }
            .padding(12)
            HStack {
                Text("Coding Rewind").foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { onClose() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 580, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isAccessibilityTrusted = MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false)
            coordinator.refreshPluginStatus()
        }
    }

    private var general: some View {
        Form {
            Section("应用入口") {
                Toggle("在 Dock 中显示", isOn: Binding(
                    get: { appearance.showsDockIcon },
                    set: { appearance.setShowsDockIcon($0) }
                ))
                Text("修改立即保存。点击 Dock 图标或从 Finder 重新打开应用，可唤出速览浮窗。")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = appearance.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section("菜单栏") {
                Text("菜单栏图标提供速览、捕获选段与设置入口。")
                Text("找不到图标时，请在系统设置的“菜单栏”中允许 CodingRewind。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开系统菜单栏设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connection: some View {
        Form {
            Section("Memos 服务") {
                TextField("服务地址", text: $urlDraft, prompt: Text("https://memos.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(coordinator.connectionSettings.isURLManaged)
                if coordinator.connectionSettings.isURLManaged {
                    Text("地址由启动环境管理，请在启动配置中修改。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SecureField("访问令牌", text: $tokenDraft, prompt: Text("留空则保留现有令牌"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(coordinator.connectionSettings.isTokenManaged)
                Text(coordinator.connectionSettings.isTokenManaged
                     ? "令牌由启动环境提供，此处不会读取或改写。"
                     : "新令牌保存到 macOS 钥匙串，不写入配置文件。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("保存连接设置") { saveConnection() }
                    .disabled(coordinator.connectionSettings.isURLManaged && coordinator.connectionSettings.isTokenManaged)
                if let saveMessage {
                    Text(saveMessage).foregroundStyle(saveFailed ? Color.red : Color.secondary)
                }
            }
            Section("最近操作") {
                Text(coordinator.bannerMessage ?? "点击立即同步检查连接。")
                    .foregroundStyle(coordinator.isErrorBanner ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                Button("立即同步") { Task { await coordinator.refresh() } }
            }
        }
        .formStyle(.grouped)
    }

    private var keyboard: some View {
        Form {
            Section("全局快捷键") {
                Text("修改立即生效并保存；清空即关闭。Hyper = ⌃⌥⇧⌘。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            KeyboardShortcuts.Recorder(for: action.name)
                                .shortcutValidation { shortcuts.validate($0, for: action) }
                                .keyboardShortcutsConflictPolicy(.init(systemShortcut: .block))
                            Button("恢复默认") { shortcuts.restoreDefault(for: action) }
                        }
                        HStack {
                            Text(shortcuts.validationMessages[action] ?? shortcuts.statusText(for: action))
                                .font(.callout).foregroundStyle(.secondary)
                            if case .failed = shortcuts.state(for: action) {
                                Button("重试") { shortcuts.retry(action) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var integrations: some View {
        Form {
            Section("Antigravity 插件") {
                Text(coordinator.pluginStatusText).foregroundStyle(.secondary)
                Button("安装或检查插件") {
                    onInstallPlugin()
                    coordinator.refreshPluginStatus()
                }
            }
            Section("辅助功能") {
                Text(isAccessibilityTrusted ? "已授权，可读取前台选区。" : "未授权，捕获其他应用选区前需要开启。")
                    .foregroundStyle(isAccessibilityTrusted ? Color.secondary : Color.orange)
                Button("检查或开启辅助功能权限…") {
                    onRequestAccessibility()
                    isAccessibilityTrusted = MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false)
                }
            }
        }
        .formStyle(.grouped)
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

// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import SwiftUI

@MainActor
public final class CodingRewindAppDelegate: NSObject, NSApplicationDelegate {
    public var coordinator: AppCoordinator?
    public var hudPanel: QuickPeekHUDPanel?
    public var shortcutMonitor: GlobalShortcutMonitor?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            let paths = try StoragePaths.resolve()
            let coord = try AppCoordinator(paths: paths, capturer: MacOSAccessibilitySelectionCapturer())
            coord.onCopyToClipboard = { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            coord.onOpenURL = { url in NSWorkspace.shared.open(url) }
            coord.onOpenAntigravityApp = {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CapturedSelection.antigravityBundleIdentifier) {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            self.coordinator = coord
            if CommandLine.arguments.contains("--install-plugin") {
                installPlugin()
                NSApplication.shared.terminate(nil)
                return
            }
            let panel = QuickPeekHUDPanel(coordinator: coord, onInstallPlugin: { [weak self] in self?.installPlugin() })
            self.hudPanel = panel
            let shortcuts = GlobalShortcutMonitor(
                onCapture: { [weak self] in
                    guard let self, let coord = self.coordinator else { return }
                    Task { @MainActor in
                        await coord.captureSelection()
                        self.hudPanel?.presentNonActivating()
                    }
                },
                onToggleHUD: { [weak self] in self?.hudPanel?.toggle() }
            )
            shortcuts.register()
            self.shortcutMonitor = shortcuts
            if CommandLine.arguments.contains("--show-hud") { panel.presentNonActivating() }
            Task { @MainActor in await coord.refresh() }
        } catch {
            NSLog("CodingRewind startup failed: \(error.localizedDescription)")
        }
    }

    public func installPlugin() {
        guard let coord = coordinator else { return }
        let fm = FileManager.default
        let dirs = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        ]
        coord.installOrRepairPlugin(
            sourceHookURL: dirs.map { $0.appendingPathComponent("coding-rewind-hook") }.first { fm.isExecutableFile(atPath: $0.path) },
            sourceBridgeURL: dirs.map { $0.appendingPathComponent("memos-mcp-bridge.sh") }.first { fm.fileExists(atPath: $0.path) }
        )
    }
}

@main
struct CodingRewindAppMain: App {
    @NSApplicationDelegateAdaptor(CodingRewindAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Rewind", systemImage: "clock.arrow.circlepath") {
            Button("切换 Rewind 浮窗 (⌃⌥R)") { appDelegate.hudPanel?.toggle() }
            Button("捕获当前选段 (⌃⌥S)") {
                Task { @MainActor in await appDelegate.coordinator?.captureSelection(); appDelegate.hudPanel?.presentNonActivating() }
            }
            Button("在 Antigravity 开聊") { Task { @MainActor in _ = await appDelegate.coordinator?.launchCheckedInAntigravity() } }
            Divider()
            Button("安装或检查 Antigravity 插件") { appDelegate.installPlugin() }
            Divider()
            Button("退出 Coding Rewind") { NSApplication.shared.terminate(nil) }
        }
    }
}

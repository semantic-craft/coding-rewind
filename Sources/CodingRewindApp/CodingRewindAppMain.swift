// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Observation

@MainActor
public final class CodingRewindAppDelegate: NSObject, NSApplicationDelegate {
    public var coordinator: AppCoordinator?
    public var hudPanel: QuickPeekHUDPanel?
    public var statusItemController: StatusItemController?
    public var settingsWindowController: SettingsWindowController?
    public var shortcuts: AppShortcuts?
    public var appearance: AppAppearancePreferences?
    public private(set) var lastExternalApplication: NSRunningApplication?

    private var workspaceObserver: NSObjectProtocol?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        recordFrontmostExternalApp(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            guard let activatedPID else { return }
            Task { @MainActor [weak self] in
                guard let app = NSRunningApplication(processIdentifier: activatedPID) else { return }
                self?.recordFrontmostExternalApp(app)
            }
        }

        do {
            let paths = try StoragePaths.resolve()
            let appearance = AppAppearancePreferences(defaults: AppShortcuts.preferences(
                environment: ProcessInfo.processInfo.environment, dataDirectory: paths.dataDirectoryURL
            ))
            self.appearance = appearance
            appearance.apply()
            let capturer = MacOSAccessibilitySelectionCapturer { [weak self] in
                self?.lastExternalApplication
            }
            let coord = try AppCoordinator(paths: paths, capturer: capturer)
            coord.onOpenURL = { url in
                NSWorkspace.shared.open(url)
            }
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

            AppShortcuts.configurePreferences(environment: coord.environment, dataDirectory: paths.dataDirectoryURL)
            let shortcuts = AppShortcuts { [weak self] command in self?.perform(command) }
            self.shortcuts = shortcuts

            NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts) { [weak self] command in
                self?.perform(command)
            }

            let panel = QuickPeekHUDPanel(
                coordinator: coord,
                shortcuts: shortcuts,
                onInstallPlugin: { [weak self] in self?.perform(.installOrRepairPlugin) },
                onOpenSettings: { [weak self] in self?.perform(.openSettings) }
            )
            self.hudPanel = panel

            let settings = SettingsWindowController(
                coordinator: coord,
                appearance: appearance,
                shortcuts: shortcuts,
                onInstallPlugin: { [weak self] in self?.perform(.installOrRepairPlugin) },
                onRequestAccessibility: { [weak self] in self?.perform(.requestAccessibility) }
            )
            self.settingsWindowController = settings

            let statusController = StatusItemController(
                shortcuts: shortcuts,
                snapshotProvider: { [weak self] in
                    guard let self, let coord = self.coordinator else {
                        return MenuStatusSnapshot(
                            isHUDVisible: false,
                            hotCardCount: 0,
                            checkedCardCount: 0,
                            pendingOutboxCount: 0,
                            connection: .unconfigured,
                            isPluginReady: false,
                            pluginSummary: "",
                            isAccessibilityTrusted: false,
                            recentCards: []
                        )
                    }
                    return coord.menuStatusSnapshot(
                        isHUDVisible: self.hudPanel?.isVisible ?? false,
                        isAccessibilityTrusted: MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: false)
                    )
                },
                onCommand: { [weak self] command in
                    self?.perform(command)
                }
            )
            self.statusItemController = statusController

            observeCoordinatorChanges()

            if !CommandLine.arguments.contains("--background") {
                perform(.presentHUDAndFocus)
            }

            Task { @MainActor [weak self] in
                await coord.refresh()
                self?.statusItemController?.refreshIcon()
            }
        } catch {
            NSLog("CodingRewind startup failed: \(error.localizedDescription)")
        }
    }

    public func applicationWillTerminate(_ notification: Notification) { shortcuts?.stop() }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        perform(.presentHUDAndFocus)
        return true
    }

    public func perform(_ command: AppCommand) {
        switch command {
        case .toggleHUD:
            hudPanel?.toggle(anchorFrame: statusItemController?.anchorFrame)
        case .presentHUDAndFocus:
            hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
        case .captureSelectionHotkey, .captureSelectionFromMenu:
            guard let coord = coordinator else { return }
            Task { @MainActor [weak self] in
                await coord.captureSelection()
                guard let self else { return }
                self.statusItemController?.refreshIcon()
                self.hudPanel?.presentNonActivating(anchorFrame: self.statusItemController?.anchorFrame)
            }
        case .launchInAntigravity:
            guard let coord = coordinator else { return }
            if coord.cards.isEmpty {
                hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
            }
            Task { @MainActor [weak self] in
                let outcome = await coord.launchCheckedInAntigravity()
                guard let self else { return }
                self.statusItemController?.refreshIcon()
                if outcome == nil {
                    self.hudPanel?.presentNonActivating(anchorFrame: self.statusItemController?.anchorFrame)
                }
            }
        case .refreshHotStream:
            guard let coord = coordinator else { return }
            Task { @MainActor [weak self] in
                await coord.refresh()
                self?.statusItemController?.refreshIcon()
            }
        case .openMemosWeb:
            guard let coord = coordinator else { return }
            if let baseURL = coord.paths.resolveMemosBaseURL(environment: coord.environment) {
                NSWorkspace.shared.open(baseURL)
            } else {
                perform(.openSettings)
            }
        case .installOrRepairPlugin:
            installPlugin()
            statusItemController?.refreshIcon()
            hudPanel?.presentNonActivating(anchorFrame: statusItemController?.anchorFrame)
        case .requestAccessibility:
            let trusted = MacOSAccessibilitySelectionCapturer.isAccessibilityTrusted(prompt: true)
            if !trusted,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .openSettings:
            settingsWindowController?.show()
        case .selectRecentCard(let cardID):
            coordinator?.focusAndCheckCard(id: cardID)
            hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
        case .showAbout:
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.orderFrontStandardAboutPanel(options: [
                .applicationName: "Coding Rewind",
                .applicationVersion: "0.2.0"
            ])
        case .quit:
            NSApplication.shared.terminate(nil)
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
            sourceBridgeURL: dirs.map { $0.appendingPathComponent("memos-mcp-bridge.sh") }.first { fm.fileExists(atPath: $0.path) },
            sourceSidecarURL: dirs.map { $0.appendingPathComponent("coding-rewind-sidecar") }.first { fm.isExecutableFile(atPath: $0.path) }
        )
    }

    private func recordFrontmostExternalApp(_ app: NSRunningApplication?) {
        guard let app,
              !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != "dev.codingrewind.app" else {
            return
        }
        lastExternalApplication = app
    }

    private func observeCoordinatorChanges() {
        guard let coord = coordinator else { return }
        withObservationTracking {
            _ = coord.cards
            _ = coord.checkedCardIDs
            _ = coord.bannerMessage
            _ = coord.isErrorBanner
            _ = coord.pluginStatusText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusItemController?.refreshIcon()
                self.observeCoordinatorChanges()
            }
        }
    }
}

@main
public enum CodingRewindAppMain {
    @MainActor private static var retainedDelegate: CodingRewindAppDelegate?

    @MainActor
    public static func main() {
        let app = NSApplication.shared
        let delegate = CodingRewindAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

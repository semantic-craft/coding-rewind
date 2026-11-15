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
    public var selectionPopupController: SelectionPopupController?
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

        let configurationURL = Bundle.main.url(forResource: "DeveloperCredentials", withExtension: "plist")
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            do {
                let resolved = try await Task.detached {
                    try DeveloperCredentialsBootstrap.resolveEnvironment(
                        configurationURL: configurationURL, environment: environment
                    )
                }.value
                self?.start(environment: resolved)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Coding Rewind 未能启动"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func start(environment: [String: String]) {
        do {
            let paths = try StoragePaths.resolve(environment: environment)
            let appearance = AppAppearancePreferences(defaults: AppPreferences.userDefaults(
                environment: environment, dataDirectory: paths.dataDirectoryURL
            ))
            self.appearance = appearance
            appearance.apply()
            let capturer = MacOSAccessibilitySelectionCapturer { [weak self] in
                self?.lastExternalApplication
            }
            let coord = try AppCoordinator(paths: paths, environment: environment, capturer: capturer, codexDelivery: CodexAppIntegration.delivery(environment: environment))
            coord.onOpenURL = { url in
                NSWorkspace.shared.open(url)
            }
            coord.onWakeHost = { host in
                switch host {
                case .antigravity:
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.antigravity) {
                        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                case .codex:
                    break
                }
            }
            coord.onOpenConversation = { reference in
                guard reference.host == .codex,
                      let threadID = UUID(uuidString: reference.id),
                      let url = URL(string: "codex://threads/\(threadID.uuidString.lowercased())") else { return false }
                return NSWorkspace.shared.open(url)
            }
            self.coordinator = coord

            if CommandLine.arguments.contains("--install-plugin") {
                installPlugin()
                NSApplication.shared.terminate(nil)
                return
            }

            let dispatchCommand: @MainActor (AppCommand) -> Void = { [weak self] command in
                self?.perform(command)
            }

            AppShortcuts.configurePreferences(environment: coord.environment, dataDirectory: paths.dataDirectoryURL)
            let shortcuts = AppShortcuts(onCommand: dispatchCommand)
            self.shortcuts = shortcuts

            NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts, onCommand: dispatchCommand)

            let panel = QuickPeekHUDPanel(
                coordinator: coord,
                shortcuts: shortcuts,
                onCommand: dispatchCommand
            )
            self.hudPanel = panel

            let settings = SettingsWindowController(
                coordinator: coord,
                appearance: appearance,
                shortcuts: shortcuts,
                onCommand: dispatchCommand
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
                        isAccessibilityTrusted: AXSupport.isTrusted(prompt: false)
                    )
                },
                onCommand: dispatchCommand
            )
            self.statusItemController = statusController

            let selectionPopup = SelectionPopupController(
                appearance: appearance,
                shortcuts: shortcuts,
                onTriggerCapture: { [weak self] in
                    await self?.captureSelectionAndRefreshStatus() ?? .ignoredBusy
                },
                onPresentErrorHUD: { [weak self] in
                    self?.presentHUDNonActivating()
                }
            )
            selectionPopup.start()
            self.selectionPopupController = selectionPopup

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

    public func applicationWillTerminate(_ notification: Notification) {
        selectionPopupController?.stop()
        shortcuts?.stop()
    }

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
        case .captureSelectionHotkey:
            triggerCapture(preferInPlacePopup: true)
        case .captureSelection:
            triggerCapture(preferInPlacePopup: false)
        case .launchConversation, .launchIn:
            guard let coord = coordinator, !coord.isLaunchingConversation else { return }
            if coord.cards.isEmpty {
                hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
            }
            Task { @MainActor [weak self] in
                let host: ConversationHost?
                if case .launchIn(let target) = command { host = target } else { host = nil }
                let outcome = await coord.launchChecked(in: host)
                guard let self else { return }
                self.statusItemController?.refreshIcon()
                if outcome == nil || coord.isErrorBanner {
                    self.presentHUDNonActivating()
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
            if settingsWindowController?.window?.isVisible != true {
                presentHUDNonActivating()
            }
        case .requestAccessibility:
            let trusted = AXSupport.isTrusted(prompt: true)
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
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.3.2"
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.orderFrontStandardAboutPanel(options: [
                .applicationName: "Coding Rewind",
                .applicationVersion: version
            ])
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func triggerCapture(preferInPlacePopup: Bool) {
        guard coordinator != nil, selectionPopupController?.phase != .saving else { return }
        let useInPlacePopup = preferInPlacePopup && selectionPopupController?.isVisible == true
        if useInPlacePopup {
            selectionPopupController?.beginSavingInPlace()
        } else {
            selectionPopupController?.hideImmediately()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.captureSelectionAndRefreshStatus()
            if useInPlacePopup {
                self.selectionPopupController?.applyInPlaceCaptureOutcome(outcome)
            } else {
                self.presentHUDNonActivating()
            }
        }
    }

    private func captureSelectionAndRefreshStatus() async -> SelectionCaptureOutcome {
        guard let coord = coordinator else { return .ignoredBusy }
        let outcome = await coord.captureSelection()
        statusItemController?.refreshIcon()
        return outcome
    }

    private func presentHUDNonActivating() {
        hudPanel?.presentNonActivating(anchorFrame: statusItemController?.anchorFrame)
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
              !AppBundleID.isSelf(app.bundleIdentifier) else {
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

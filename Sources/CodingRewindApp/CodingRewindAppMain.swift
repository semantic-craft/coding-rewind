// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import KeyboardShortcuts
import Observation

@MainActor
public final class CodingRewindAppDelegate: NSObject, NSApplicationDelegate {
    public enum StartupBootstrapDisposition: Equatable, Sendable {
        case startDegraded(environment: [String: String], warningMessage: String)
        case terminateWithModalAlert(title: String, message: String)
    }

    public var coordinator: AppCoordinator?
    public var hudPanel: QuickPeekHUDPanel?
    public var statusItemController: StatusItemController?
    public var settingsWindowController: SettingsWindowController?
    public var selectionPopupController: SelectionPopupController?
    public var shortcuts: AppShortcuts?
    public var appearance: AppAppearancePreferences?
    public var loginItemController: LoginItemController?
    public var updater: AppUpdater?
    public var antigravityInstaller: AntigravityPluginInstaller?
    public var dshCaptureWatcher: DSHCaptureBridgeWatcher?
    public private(set) var lastExternalApplication: NSRunningApplication?

    private var workspaceObserver: NSObjectProtocol?
    private var isInstallingDSHPlugin = false

    public static func resolveBootstrapLanguage(
        environment: [String: String],
        preferredLanguagesProvider: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) -> AppLanguage {
        guard let paths = try? StoragePaths.resolve(environment: environment) else {
            return AppLanguagePreference.system.resolved(preferredLanguages: preferredLanguagesProvider())
        }
        let defaults = AppPreferences.userDefaults(environment: environment, dataDirectory: paths.dataDirectoryURL)
        return AppAppearancePreferences(
            defaults: defaults,
            applyPolicy: { _ in true },
            preferredLanguagesProvider: preferredLanguagesProvider
        ).effectiveLanguage
    }

    public static func evaluateBootstrapFailure(
        error: any Error,
        environment: [String: String],
        launchContext: LaunchContext,
        bundledConfigurationURL: URL?,
        language: AppLanguage? = nil,
        fileManager: FileManager = .default
    ) -> StartupBootstrapDisposition {
        let resolvedLanguage = language ?? resolveBootstrapLanguage(environment: environment)
        let localizedError: String
        if let bootstrapFailure = error as? DeveloperCredentialsResolver.Failure {
            localizedError = bootstrapFailure.localizedDescription(in: resolvedLanguage)
        } else {
            localizedError = error.localizedDescription
        }
        let hasBundledConfig = DeveloperCredentialsResolver.hasBundledConfiguration(
            at: bundledConfigurationURL,
            fileManager: fileManager
        )
        if !launchContext.shouldPresentHUDOnInitialLaunch || !hasBundledConfig {
            var degradedEnvironment = environment
            if degradedEnvironment[StoragePaths.qaEnvironmentKey] != "1" {
                degradedEnvironment[KeychainTokenStore.disableKeychainFallbackEnvironmentKey] = "1"
            }
            return .startDegraded(environment: degradedEnvironment, warningMessage: localizedError)
        }
        return .terminateWithModalAlert(
            title: AppStrings.startupFailedAlertTitle(in: resolvedLanguage),
            message: localizedError
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let launchContext = LaunchContext.captureCurrent(
            arguments: CommandLine.arguments,
            environment: environment
        )
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
        let externalConfigurationURL: URL? = if environment[StoragePaths.qaEnvironmentKey] == "1" {
            nil
        } else {
            (try? StoragePaths.resolve(environment: environment))?.developerCredentialsFileURL
        }
        Task { [weak self] in
            do {
                let resolved = try await Task.detached {
                    try DeveloperCredentialsResolver.resolveEnvironment(
                        configurationURL: configurationURL,
                        externalConfigurationURL: externalConfigurationURL,
                        environment: environment
                    )
                }.value
                self?.start(environment: resolved, launchContext: launchContext)
            } catch {
                let disposition = Self.evaluateBootstrapFailure(
                    error: error,
                    environment: environment,
                    launchContext: launchContext,
                    bundledConfigurationURL: configurationURL
                )
                switch disposition {
                case .startDegraded(let degradedEnv, let warningMessage):
                    self?.start(
                        environment: degradedEnv,
                        launchContext: launchContext,
                        startupWarning: warningMessage
                    )
                case .terminateWithModalAlert(let title, let message):
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    alert.runModal()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func start(
        environment: [String: String],
        launchContext: LaunchContext,
        startupWarning: String? = nil
    ) {
        do {
            let paths = try StoragePaths.resolve(environment: environment)
            let defaults = AppPreferences.userDefaults(
                environment: environment,
                dataDirectory: paths.dataDirectoryURL
            )
            let appearance = AppAppearancePreferences(defaults: defaults)
            self.appearance = appearance
            appearance.apply()

            let initialLanguage = appearance.effectiveLanguage
            KeyboardShortcuts.localizationLanguageCode = initialLanguage.rawValue

            let installer = AntigravityPluginInstaller(paths: paths)
            self.antigravityInstaller = installer
            Self.stageBundledCLIBinaryIfAvailable(paths: paths)
            try? installer.refreshLocalizedMetadataIfInstalled(language: initialLanguage)
            Self.refreshInstalledDSHPluginIfPresent(paths: paths)

            let loginItem = LoginItemController.live(
                environment: environment,
                bundleURL: Bundle.main.bundleURL,
                language: initialLanguage
            )
            self.loginItemController = loginItem

            let updater = AppUpdater.live(
                paths: paths,
                environment: environment,
                defaults: defaults,
                language: initialLanguage
            )
            self.updater = updater

            let capturer = MacOSAccessibilitySelectionCapturer { [weak self] in
                self?.lastExternalApplication
            }
            let dshAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.dsh)
            let coord = try AppCoordinator(
                paths: paths,
                environment: environment,
                capturer: capturer,
                language: initialLanguage,
                dshBinaryURLProvider: {
                    DSHIntegration.resolveDSHBinaryURL(
                        environment: environment,
                        applicationURL: dshAppURL
                    )
                }
            )
            coord.onOpenURL = { url in
                NSWorkspace.shared.open(url)
            }
            coord.onCopyText = { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            coord.onWakeHost = { host in
                switch host {
                case .antigravity:
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.antigravity) {
                        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                case .dsh:
                    DSHAppIntegration.wakeDSH()
                }
            }
            coord.onActivateHostApp = { [weak self] host in
                switch host {
                case .antigravity:
                    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppBundleID.antigravity) else {
                        return false
                    }
                    self?.hudPanel?.orderOut(nil)
                    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleID.antigravity)
                        .first(where: { !$0.isTerminated }) {
                        NSApplication.shared.yieldActivation(to: running)
                        _ = running.activate()
                    }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                    return true
                case .dsh:
                    return DSHAppIntegration.activateDSH { [weak self] in
                        self?.hudPanel?.orderOut(nil)
                    }
                }
            }
            coord.onOpenConversation = { [weak self] reference in
                self?.coordinator?.onActivateHostApp?(reference.host) ?? false
            }
            self.coordinator = coord
            if let startupWarning {
                coord.recordStartupWarning(startupWarning)
            }

            if CommandLine.arguments.contains("--install-plugin") {
                installPlugin()
                NSApplication.shared.terminate(nil)
                return
            }

            let dispatchCommand: @MainActor (AppCommand) -> Void = { [weak self] command in
                self?.perform(command)
            }

            AppShortcuts.configurePreferences(environment: coord.environment, dataDirectory: paths.dataDirectoryURL)
            let shortcuts = AppShortcuts(language: initialLanguage, onCommand: dispatchCommand)
            self.shortcuts = shortcuts

            NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(
                shortcuts: shortcuts,
                language: initialLanguage,
                onCommand: dispatchCommand
            )

            let panel = QuickPeekHUDPanel(
                coordinator: coord,
                shortcuts: shortcuts,
                updater: updater,
                onCommand: dispatchCommand
            )
            self.hudPanel = panel

            let settings = SettingsWindowController(
                coordinator: coord,
                appearance: appearance,
                shortcuts: shortcuts,
                loginItemController: loginItem,
                updater: updater,
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
                language: initialLanguage,
                onTriggerCapture: { [weak self] in
                    await self?.captureSelectionAndRefreshStatus() ?? .ignoredBusy
                },
                onPresentErrorHUD: { [weak self] in
                    self?.presentHUDNonActivating()
                }
            )
            selectionPopup.start()
            self.selectionPopupController = selectionPopup

            if let captureStore = try? DSHCaptureBridgeStore(dataDirectoryURL: paths.dataDirectoryURL) {
                let watcher = DSHCaptureBridgeWatcher(
                    store: captureStore,
                    handler: { [weak coord] request in
                        guard let coord else {
                            return DSHCaptureBridgeReceipt(
                                captureId: request.captureId,
                                state: .failed,
                                error: "app unavailable",
                                updatedAtMs: Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
                            )
                        }
                        return await coord.captureExternalDSHRequest(request)
                    },
                    onProcessed: { [weak self] in
                        self?.statusItemController?.refreshIcon()
                    }
                )
                watcher.start()
                self.dshCaptureWatcher = watcher
            }

            appearance.onEffectiveLanguageChange = { [weak self] lang in
                KeyboardShortcuts.localizationLanguageCode = lang.rawValue
                guard let self else { return }
                try? self.antigravityInstaller?.refreshLocalizedMetadataIfInstalled(language: lang)
                self.coordinator?.setLanguage(lang)
                self.loginItemController?.language = lang
                self.updater?.language = lang
                if let shortcuts = self.shortcuts {
                    shortcuts.language = lang
                    NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(
                        shortcuts: shortcuts,
                        language: lang,
                        onCommand: dispatchCommand
                    )
                }
                self.selectionPopupController?.language = lang
                self.settingsWindowController?.updateLanguage(lang)
            }

            observeCoordinatorChanges()
            updater.startBackgroundSchedule()

            if launchContext.shouldPresentHUDOnInitialLaunch {
                hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
            }

            refreshHotStreamInBackground()
        } catch {
            NSLog("CodingRewind startup failed: \(error.localizedDescription)")
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dshCaptureWatcher?.stop()
        dshCaptureWatcher = nil
        updater?.stop()
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
            let wasVisible = hudPanel?.isVisible == true
            hudPanel?.toggle(anchorFrame: statusItemController?.anchorFrame)
            if !wasVisible, hudPanel?.isVisible == true {
                refreshHotStreamInBackground()
            }
        case .presentHUDAndFocus:
            hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
            refreshHotStreamInBackground()
        case .captureSelectionHotkey:
            triggerCapture(preferInPlacePopup: true)
        case .captureSelection:
            triggerCapture(preferInPlacePopup: false)
        case .launchConversation:
            guard let coord = coordinator, !coord.isLaunchingConversation else { return }

            if coord.hasActiveHandoffConversation {
                Task { @MainActor [weak self] in
                    let outcome = await coord.launchChecked()
                    guard let self else { return }
                    self.statusItemController?.refreshIcon()
                    if outcome == nil || coord.isErrorBanner {
                        self.presentHUDNonActivating()
                    }
                }
                return
            }

            if coord.conversationDraft != nil {
                hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
                hudPanel?.focusDraftEditorIfPresent()
                statusItemController?.refreshIcon()
                return
            }

            if coord.openConversationDraft() {
                hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
                hudPanel?.focusDraftEditorIfPresent()
                statusItemController?.refreshIcon()
            } else {
                statusItemController?.refreshIcon()
                if coord.cards.isEmpty {
                    hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
                } else {
                    presentHUDNonActivating()
                }
            }
        case .copyDraftAndWakeHost:
            guard let coord = coordinator, !coord.isLaunchingConversation else { return }
            hudPanel?.commitDraftEditorIfPresent()
            let woke = coord.copyConversationDraftAndWakeHost()
            statusItemController?.refreshIcon()
            if woke {
                hudPanel?.orderOut(nil)
            } else {
                presentHUDNonActivating()
            }
        case .sendConversationDraft:
            guard let coord = coordinator, !coord.isLaunchingConversation else { return }
            hudPanel?.commitDraftEditorIfPresent()
            Task { @MainActor [weak self] in
                let outcome = await coord.sendConversationDraft()
                guard let self else { return }
                self.statusItemController?.refreshIcon()
                if outcome == nil || coord.isErrorBanner {
                    self.presentHUDNonActivating()
                } else if case .succeeded(let reference) = outcome, reference.host == .dsh {
                    _ = coord.onActivateHostApp?(.dsh)
                }
            }
        case .refreshHotStream:
            refreshHotStreamInBackground()
        case .openMemosWeb:
            guard let coord = coordinator else { return }
            if let baseURL = coord.paths.resolveMemosBaseURL(environment: coord.environment) {
                coord.openURL(baseURL)
            } else {
                perform(.openSettingsPage(.connection))
            }
        case .installOrRepairPlugin:
            installPlugin()
            statusItemController?.refreshIcon()
            if settingsWindowController?.window?.isVisible != true {
                presentHUDNonActivating()
            }
        case .installOrRepairDSHPlugin:
            installDSHPlugin()
        case .requestAccessibility:
            let trusted = AXSupport.isTrusted(prompt: true)
            if !trusted,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .resetAccessibility:
            _ = Self.resetAccessibilityApproval(bundleIdentifier: Bundle.main.bundleIdentifier)
            let trusted = AXSupport.isTrusted(prompt: true)
            if !trusted,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            settingsWindowController?.refreshPermissions()
            statusItemController?.refreshIcon()
        case .openSettings:
            settingsWindowController?.show()
        case .openSettingsPage(let page):
            settingsWindowController?.show(page: page)
        case .checkForUpdates:
            settingsWindowController?.show(page: .about)
            Task { @MainActor [weak self] in
                await self?.updater?.checkForUpdates(userInitiated: true)
            }
        case .selectRecentCard(let cardID):
            coordinator?.focusAndCheckCard(id: cardID)
            hudPanel?.presentAndFocus(anchorFrame: statusItemController?.anchorFrame)
            refreshHotStreamInBackground()
        case .showAbout:
            settingsWindowController?.show(page: .about)
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

    private func refreshHotStreamInBackground() {
        guard let coord = coordinator else { return }
        Task { @MainActor [weak self] in
            await coord.refresh()
            self?.statusItemController?.refreshIcon()
            await coord.refreshPlaceLibrary()
        }
    }

    public static func stageBundledCLIBinaryIfAvailable(
        paths: StoragePaths,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        guard bundleURL.pathExtension.lowercased() == "app" else { return }
        let fm = FileManager.default
        let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let bundledCLI = helpersDir.appendingPathComponent("coding-rewind", isDirectory: false)
        if fm.isExecutableFile(atPath: bundledCLI.path) {
            try? AntigravityIntegration.stageCLIBinary(
                sourceCLIBinaryURL: bundledCLI,
                in: paths.dataDirectoryURL
            )
        }
        let bundledSidecar = helpersDir.appendingPathComponent("coding-rewind-sidecar", isDirectory: false)
        if fm.isExecutableFile(atPath: bundledSidecar.path) {
            try? AntigravityIntegration.refreshSidecarBinaryIfInstalled(
                sourceSidecarBinaryURL: bundledSidecar,
                in: paths.dataDirectoryURL,
                configDirectoryURL: paths.antigravityConfigDirectoryURL
            )
        }
    }

    public static func refreshInstalledDSHPluginIfPresent(
        paths: StoragePaths,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        guard let sourceDir = DSHAppIntegration.bundledPluginDirectoryURL(bundleURL: bundleURL) else {
            return
        }
        try? DSHIntegration.refreshInstalledPluginIfPresent(
            sourcePluginDirectoryURL: sourceDir,
            dataDirectoryURL: paths.dataDirectoryURL,
            dshHomeURL: paths.dshHomeDirectoryURL
        )
    }

    public func installDSHPlugin() {
        guard !isInstallingDSHPlugin, let coord = coordinator else { return }
        isInstallingDSHPlugin = true
        let paths = coord.paths
        let environment = coord.environment
        let language = coord.language
        let sourceDir = DSHAppIntegration.bundledPluginDirectoryURL()
        let binaryURL = DSHAppIntegration.resolveDSHBinaryURL(environment: environment)

        Task { @MainActor [weak self, weak coord] in
            defer { self?.isInstallingDSHPlugin = false }
            do {
                _ = try await Task.detached {
                    try DSHIntegration.installOrRepair(
                        dataDirectoryURL: paths.dataDirectoryURL,
                        dshHomeURL: paths.dshHomeDirectoryURL,
                        sourcePluginDirectoryURL: sourceDir,
                        dshBinaryURL: binaryURL,
                        language: language,
                        baseEnvironment: environment
                    )
                }.value
                coord?.recordDSHPluginInstallResult(success: true)
            } catch {
                coord?.recordDSHPluginInstallFailure(error)
            }
            guard let self else { return }
            self.statusItemController?.refreshIcon()
            if self.settingsWindowController?.window?.isVisible != true {
                self.presentHUDNonActivating()
            }
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
            sourceCLIBinaryURL: dirs.map { $0.appendingPathComponent("coding-rewind") }.first { fm.isExecutableFile(atPath: $0.path) },
            sourceSidecarURL: dirs.map { $0.appendingPathComponent("coding-rewind-sidecar") }.first { fm.isExecutableFile(atPath: $0.path) }
        )
    }

    @discardableResult
    public static func resetAccessibilityApproval(
        bundleIdentifier: String?,
        runner: (String, [String]) -> Int32 = { executable, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }
    ) -> Bool {
        guard let bundleID = bundleIdentifier,
              bundleID == AppBundleID.selfApp || bundleID == AppBundleID.selfQAApp else {
            return false
        }
        let status = runner("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        return status == 0
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
            _ = coord.dshPluginStatusText
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

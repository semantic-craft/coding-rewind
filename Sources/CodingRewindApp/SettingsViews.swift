// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import KeyboardShortcuts
import Observation
import SwiftUI

@MainActor
@Observable
public final class AccessibilityPermissionState {
    public private(set) var isTrusted: Bool
    private let checkTrusted: @MainActor () -> Bool

    public init(checkTrusted: (@MainActor () -> Bool)? = nil) {
        let check = checkTrusted ?? { AXSupport.isTrusted(prompt: false) }
        self.checkTrusted = check
        self.isTrusted = check()
    }

    public func refresh() {
        isTrusted = checkTrusted()
    }
}

@MainActor
@Observable
public final class SettingsConnectionDraft {
    private enum SaveOutcome {
        case checked(ConnectionCheckOutcome)
        case rewindError(RewindError)
        case otherError(String)

        var isError: Bool {
            switch self {
            case .checked(.failed), .rewindError, .otherError:
                return true
            case .checked:
                return false
            }
        }

        func message(in language: AppLanguage) -> String {
            switch self {
            case .checked(let outcome):
                return AppStrings.connectionCheckMessage(outcome, in: language)
            case .rewindError(let rewindError):
                return rewindError.localizedDescription(in: language)
            case .otherError(let detail):
                return detail
            }
        }
    }

    public var urlDraft: String
    public var tokenDraft: String = ""
    public private(set) var saveMessage: String?
    public private(set) var saveFailed = false
    public private(set) var isVerifying = false
    private var lastOutcome: SaveOutcome?

    public init(memosURL: String) {
        self.urlDraft = memosURL
    }

    public func reset(memosURL: String) {
        urlDraft = memosURL
        tokenDraft = ""
        lastOutcome = nil
        saveMessage = nil
        saveFailed = false
    }

    public var consoleURL: URL? {
        StoragePaths.normalizedMemosBaseURL(from: urlDraft)
    }

    public func save(using coordinator: AppCoordinator) async {
        guard !isVerifying else { return }
        isVerifying = true
        saveMessage = nil
        saveFailed = false
        defer { isVerifying = false }
        let outcome: SaveOutcome
        do {
            let checked = try await coordinator.saveAndVerifyConnection(memosURL: urlDraft, token: tokenDraft)
            urlDraft = coordinator.connectionSettings.memosURL
            tokenDraft = ""
            outcome = .checked(checked)
        } catch {
            if let rewindError = error as? RewindError {
                outcome = .rewindError(rewindError)
            } else {
                outcome = .otherError(error.localizedDescription)
            }
        }
        lastOutcome = outcome
        saveFailed = outcome.isError
        saveMessage = outcome.message(in: coordinator.language)
    }

    public func updateLanguage(_ language: AppLanguage) {
        guard let lastOutcome else { return }
        saveFailed = lastOutcome.isError
        saveMessage = lastOutcome.message(in: language)
    }
}

public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general
    case connection
    case keyboard
    case integrations
    case about

    public var id: Self { self }

    public func title(in language: AppLanguage) -> String {
        AppStrings.settingsPageTitle(self, in: language)
    }

    public var title: String {
        title(in: .zhHans)
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .connection: "network"
        case .keyboard: "keyboard"
        case .integrations: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
public final class SettingsNavigationModel {
    public var selectedPage: SettingsPage

    public init(selectedPage: SettingsPage = .general) {
        self.selectedPage = selectedPage
    }
}

enum SettingsLayout {
    static let contentSize = NSSize(width: 720, height: 540)
    static let sidebarWidth: CGFloat = 168
}

@MainActor
public struct SettingsRootView: View {
    @Bindable public var coordinator: AppCoordinator
    @Bindable public var appearance: AppAppearancePreferences
    @Bindable public var shortcuts: AppShortcuts
    public var loginItemController: LoginItemController?
    public var updater: AppUpdater?
    @Bindable public var permissionState: AccessibilityPermissionState
    @Bindable public var connectionDraft: SettingsConnectionDraft
    @Bindable public var navigationModel: SettingsNavigationModel
    public var onCopyText: (@MainActor (String) -> Void)?
    public let onCommand: @MainActor (AppCommand) -> Void
    public let onClose: @MainActor () -> Void
    @State private var didCopyMCPConfig = false
    @State private var copyFeedbackResetTask: Task<Void, Never>?

    public init(
        coordinator: AppCoordinator,
        appearance: AppAppearancePreferences,
        shortcuts: AppShortcuts,
        loginItemController: LoginItemController? = nil,
        updater: AppUpdater? = nil,
        permissionState: AccessibilityPermissionState = AccessibilityPermissionState(),
        connectionDraft: SettingsConnectionDraft? = nil,
        navigationModel: SettingsNavigationModel = SettingsNavigationModel(),
        onCopyText: (@MainActor (String) -> Void)? = nil,
        onCommand: @escaping @MainActor (AppCommand) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.appearance = appearance
        self.shortcuts = shortcuts
        self.loginItemController = loginItemController
        self.updater = updater
        self.permissionState = permissionState
        self.connectionDraft = connectionDraft ?? SettingsConnectionDraft(memosURL: coordinator.connectionSettings.memosURL)
        self.navigationModel = navigationModel
        self.onCopyText = onCopyText
        self.onCommand = onCommand
        self.onClose = onClose
    }

    private var lang: AppLanguage {
        appearance.effectiveLanguage
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPage?>(
                get: { navigationModel.selectedPage },
                set: { if let page = $0 { navigationModel.selectedPage = page } }
            )) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title(in: lang), systemImage: page.systemImage)
                        .tag(page)
                        .accessibilityIdentifier("settings.navigation.\(page.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel(AppStrings.settingsCategoriesLabel(in: lang))
            .frame(width: SettingsLayout.sidebarWidth)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(navigationModel.selectedPage.title(in: lang))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch navigationModel.selectedPage {
                        case .general: general
                        case .connection: connection
                        case .keyboard: keyboard
                        case .integrations: integrations
                        case .about: about
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .environment(\.locale, lang.locale)
        .frame(width: SettingsLayout.contentSize.width, height: SettingsLayout.contentSize.height)
        .onDisappear {
            copyFeedbackResetTask?.cancel()
            copyFeedbackResetTask = nil
        }
        .onExitCommand(perform: onClose)
    }

    private var general: some View {
        Group {
            SettingsSection(AppStrings.languageSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.displayLanguageTitle(in: lang),
                    help: AppStrings.displayLanguageHelp(in: lang)
                ) {
                    Picker(
                        AppStrings.displayLanguageTitle(in: lang),
                        selection: Binding(
                            get: { appearance.languagePreference },
                            set: { appearance.setLanguagePreference($0) }
                        )
                    ) {
                        ForEach(AppLanguagePreference.allCases) { option in
                            Text(AppStrings.languagePreferenceTitle(option, in: lang))
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 136)
                    .accessibilityIdentifier("settings.language")
                }
            }

            if let loginItemController {
                SettingsSection(AppStrings.startupSectionTitle(in: lang)) {
                    let itemState = loginItemController.state
                    let isUnavailable: Bool = {
                        if case .unavailable = itemState { return true }
                        return false
                    }()
                    SettingsRow(
                        AppStrings.launchAtLoginTitle(in: lang),
                        help: AppStrings.launchAtLoginHelp(itemState, in: lang)
                    ) {
                        HStack(spacing: 8) {
                            if itemState == .requiresApproval {
                                Button(AppStrings.openLoginItemsSettingsButton(in: lang)) {
                                    loginItemController.openSystemSettings()
                                }
                                .rewindButtonRole(.secondary)
                                .accessibilityIdentifier("settings.openLoginItems")
                            }
                            Toggle(
                                AppStrings.launchAtLoginTitle(in: lang),
                                isOn: Binding(
                                    get: { itemState.isToggleOn },
                                    set: { loginItemController.setEnabled($0) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(isUnavailable)
                            .accessibilityIdentifier("settings.launchAtLogin")
                        }
                    }
                    if let error = loginItemController.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }

            SettingsSection(AppStrings.dockSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.showInDockTitle(in: lang),
                    help: AppStrings.showInDockHelp(in: lang)
                ) {
                    Toggle(AppStrings.showInDockTitle(in: lang), isOn: Binding(
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
            SettingsSection(AppStrings.menuBarSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.menuBarIconTitle(in: lang),
                    help: AppStrings.menuBarIconHelp(in: lang)
                ) {
                    Button(AppStrings.openMenuBarSettingsButton(in: lang)) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
                           !SystemURLOpener.open(url) {
                            NSSound.beep()
                        }
                    }
                    .rewindButtonRole(.secondary)
                }
            }
            SettingsSection(AppStrings.selectionPopupSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.showSelectionPopupTitle(in: lang),
                    help: AppStrings.showSelectionPopupHelp(in: lang)
                ) {
                    Toggle(AppStrings.showSelectionPopupTitle(in: lang), isOn: Binding(
                        get: { appearance.showsSelectionPopup },
                        set: { appearance.setShowsSelectionPopup($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.selectionPopup")
                }
            }
        }
    }

    private var connection: some View {
        let connectionState = coordinator.connectionSettings
        return Group {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppStrings.cloudSyncLocalOnlyIntro(in: lang))
                Text(AppStrings.cloudSyncServerIntro(in: lang))
                Button(AppStrings.deploymentGuideLink(in: lang)) {
                    coordinator.openURL(AppStrings.deploymentGuideURL)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("settings.deploymentGuide")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SettingsSection(AppStrings.memosServiceSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.serverURLTitle(in: lang),
                    layout: .field,
                    help: connectionState.isURLManaged
                        ? AppStrings.serverURLManagedHelp(in: lang) : nil
                ) {
                    HStack(spacing: 8) {
                        TextField(
                            AppStrings.serverURLTitle(in: lang),
                            text: $connectionDraft.urlDraft,
                            prompt: Text("https://memos.example.com")
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(connectionState.isURLManaged)
                        .accessibilityIdentifier("settings.memosURL")
                        Button(AppStrings.getTokenButton(in: lang)) {
                            if let url = connectionDraft.consoleURL {
                                coordinator.openURL(url)
                            }
                        }
                        .rewindButtonRole(.secondary)
                        .disabled(connectionDraft.consoleURL == nil)
                        .accessibilityIdentifier("settings.openMemosConsole")
                    }
                }
                Divider()
                SettingsRow(
                    AppStrings.accessTokenTitle(in: lang),
                    layout: .field,
                    help: AppStrings.accessTokenHelp(
                        isManaged: connectionState.isTokenManaged,
                        in: lang
                    )
                ) {
                    SecureField(
                        AppStrings.accessTokenTitle(in: lang),
                        text: $connectionDraft.tokenDraft,
                        prompt: Text(AppStrings.accessTokenPlaceholder(hasSavedToken: connectionState.hasSavedToken, in: lang))
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(connectionState.isTokenManaged)
                    .accessibilityIdentifier("settings.memosToken")
                }
                SettingsRow("", layout: .field) {
                    HStack(spacing: 8) {
                        Button(AppStrings.saveConnectionButton(in: lang)) {
                            Task { @MainActor in
                                await connectionDraft.save(using: coordinator)
                            }
                        }
                        .rewindButtonRole(.primary)
                        .disabled(
                            connectionDraft.isVerifying
                                || (connectionState.isURLManaged && connectionState.isTokenManaged)
                        )
                        .accessibilityIdentifier("settings.saveConnection")
                        if connectionDraft.isVerifying {
                            ProgressView().controlSize(.small)
                            Text(AppStrings.verifyingConnection(in: lang))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let saveMessage = connectionDraft.saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(connectionDraft.saveFailed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            SettingsSection(AppStrings.syncSectionTitle(in: lang)) {
                SettingsRow(AppStrings.syncClipsRowTitle(in: lang)) {
                    Button(AppStrings.syncNow(in: lang)) { onCommand(.refreshHotStream) }
                        .rewindButtonRole(.secondary)
                }
                Text(coordinator.bannerMessage ?? AppStrings.defaultSyncBannerHint(in: lang))
                    .font(.callout)
                    .foregroundStyle(coordinator.isErrorBanner ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var keyboard: some View {
        SettingsSection(AppStrings.globalShortcutsSectionTitle(in: lang)) {
            Text(AppStrings.shortcutsDescription(in: lang))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ShortcutAction.allCases) { action in
                Divider()
                SettingsRow(
                    action.title(in: lang),
                    help: shortcuts.validationMessages[action] ?? shortcuts.statusText(for: action)
                ) {
                    HStack(spacing: 8) {
                        KeyboardShortcuts.Recorder(for: action.name)
                            .shortcutValidation { shortcuts.validate($0, for: action) }
                            .keyboardShortcutsConflictPolicy(.init(systemShortcut: .block))
                            .id(lang)
                        Button(AppStrings.restoreDefaultButton(in: lang)) {
                            shortcuts.restoreDefault(for: action)
                        }
                        .rewindButtonRole(.secondary)
                        if case .failed = shortcuts.state(for: action) {
                            Button(AppStrings.retryButton(in: lang)) { shortcuts.retry(action) }
                                .rewindButtonRole(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func copyMCPConfiguration() {
        let json = coordinator.mcpClientConfigurationJSON()
        if let onCopyText {
            onCopyText(json)
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(json, forType: .string)
        }
        didCopyMCPConfig = true
        copyFeedbackResetTask?.cancel()
        copyFeedbackResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopyMCPConfig = false
        }
    }

    private var integrations: some View {
        Group {
            SettingsSection(AppStrings.antigravityPluginSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.pluginStatusRowTitle(in: lang),
                    help: coordinator.pluginStatusText
                ) {
                    Button(AppStrings.installOrRepairShortButton(in: lang)) {
                        onCommand(.installOrRepairPlugin)
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityIdentifier("settings.antigravityInstallOrRepair")
                }
            }
            SettingsSection(
                AppStrings.dshPluginSectionTitle(in: lang),
                subtitle: "DeepSeek Harness"
            ) {
                SettingsRow(
                    AppStrings.pluginStatusRowTitle(in: lang),
                    help: coordinator.dshPluginStatusText
                ) {
                    Button(AppStrings.installOrRepairShortButton(in: lang)) {
                        onCommand(.installOrRepairDSHPlugin)
                    }
                    .rewindButtonRole(.secondary)
                    .accessibilityIdentifier("settings.dshInstallOrRepair")
                }
            }
            SettingsSection(AppStrings.aiAccessSectionTitle(in: lang)) {
                SettingsRow(
                    AppStrings.mcpServiceRowTitle(in: lang),
                    help: coordinator.mcpServiceStatusText
                ) {
                    HStack(spacing: 8) {
                        if !coordinator.isMCPBinaryInstalled {
                            Button(AppStrings.installOrRepairShortButton(in: lang)) {
                                onCommand(.installOrRepairPlugin)
                            }
                            .rewindButtonRole(.secondary)
                            .accessibilityIdentifier("settings.mcpInstallOrRepair")
                        }
                        Button(
                            didCopyMCPConfig
                                ? AppStrings.copiedMCPConfigFeedback(in: lang)
                                : AppStrings.copyMCPConfigButton(in: lang)
                        ) {
                            copyMCPConfiguration()
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityIdentifier("settings.copyMCPConfig")
                    }
                }
                Text(AppStrings.mcpConfigCompatibilityCaption(in: lang))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                SettingsRow(
                    AppStrings.aiAccessPermissionRowTitle(in: lang),
                    help: AppStrings.aiAccessPermissionHelp(
                        isManaged: coordinator.isAIAccessManagedByEnvironment,
                        in: lang
                    )
                ) {
                    Picker(
                        AppStrings.aiAccessPermissionRowTitle(in: lang),
                        selection: Binding(
                            get: { coordinator.aiAccessMode },
                            set: { coordinator.setAIAccessMode($0) }
                        )
                    ) {
                        ForEach(AIAccessMode.allCases, id: \.self) { mode in
                            Text(AppStrings.aiAccessModeOptionTitle(mode, in: lang))
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .id(lang)
                    .disabled(coordinator.isAIAccessManagedByEnvironment)
                    .accessibilityIdentifier("settings.aiAccessMode")
                }
            }
            SettingsSection(AppStrings.accessibilitySectionTitle(in: lang)) {
                SettingsRow(AppStrings.readSelectedTextRowTitle(in: lang)) {
                    if permissionState.isTrusted {
                        Button(AppStrings.recheckPermissionButton(in: lang)) {
                            onCommand(.requestAccessibility)
                            permissionState.refresh()
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityLabel(AppStrings.recheckPermissionAccessibilityLabel(in: lang))
                    } else {
                        HStack(spacing: 8) {
                            Button(AppStrings.openSystemSettingsButton(in: lang)) {
                                onCommand(.requestAccessibility)
                                permissionState.refresh()
                            }
                            .rewindButtonRole(.secondary)
                            .accessibilityLabel(AppStrings.openSystemSettingsAccessibilityLabel(in: lang))

                            Button(AppStrings.resetStaleApprovalButton(in: lang)) {
                                onCommand(.resetAccessibility)
                                permissionState.refresh()
                            }
                            .rewindButtonRole(.secondary)
                            .accessibilityIdentifier("settings.resetAccessibility")
                        }
                    }
                }
                Text(AppStrings.accessibilityDescription(isTrusted: permissionState.isTrusted, in: lang))
                    .font(.callout)
                    .foregroundStyle(permissionState.isTrusted ? Color.secondary : Color.orange)
            }
        }
    }

    private var about: some View {
        Group {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: AppAboutMetadata.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Coding Rewind")
                            .font(.title3.weight(.semibold))
                        Text(
                            AppStrings.aboutVersionLine(
                                version: AppAboutMetadata.versionString(updater: updater),
                                build: AppAboutMetadata.buildNumber(),
                                in: lang
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.about.version")
                        Text(AppStrings.aboutSummary(in: lang))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(AppStrings.aboutGitHubRepoButton(in: lang)) {
                            AppAboutMetadata.openGitHubRepo(using: coordinator)
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityLabel(AppStrings.aboutGitHubRepoAccessibilityLabel(in: lang))
                        .accessibilityIdentifier("settings.about.github")

                        Button(AppStrings.aboutReleaseNotesButton(in: lang)) {
                            AppAboutMetadata.openReleaseNotes(using: coordinator)
                        }
                        .rewindButtonRole(.secondary)
                        .accessibilityLabel(AppStrings.aboutReleaseNotesAccessibilityLabel(in: lang))
                        .accessibilityIdentifier("settings.about.releases")
                    }
                }
            }

            if let updater {
                Divider()
                SettingsSection(AppStrings.updatesSectionTitle(in: lang)) {
                    let updateState = updater.state
                    let isBusy: Bool = {
                        switch updateState {
                        case .checking, .downloading, .verifying, .installing:
                            return true
                        default:
                            return false
                        }
                    }()
                    SettingsRow(
                        AppStrings.currentVersionTitle(version: updater.currentVersion, in: lang),
                        help: AppStrings.updaterStatusSummary(
                            state: updateState,
                            lastCheckedAt: updater.lastCheckedAt,
                            in: lang
                        )
                    ) {
                        HStack(spacing: 8) {
                            switch updateState {
                            case .readyToInstall(let staged):
                                Button(AppStrings.restartToUpdateButton(version: staged.candidate.version, in: lang)) {
                                    Task { @MainActor in
                                        await updater.installReadyUpdateAndRelaunch()
                                    }
                                }
                                .rewindButtonRole(.primary)
                                .accessibilityIdentifier("settings.restartToUpdate")
                            case .manualDownloadRequired(let candidate, _):
                                Button(AppStrings.viewReleaseOnGitHubButton(in: lang)) {
                                    updater.openReleasePage(candidate)
                                }
                                .rewindButtonRole(.secondary)
                                .accessibilityIdentifier("settings.viewReleaseOnGitHub")

                                Button(AppStrings.checkForUpdatesButton(isBusy: false, in: lang)) {
                                    Task { @MainActor in
                                        await updater.checkForUpdates(userInitiated: true)
                                    }
                                }
                                .rewindButtonRole(.secondary)
                                .accessibilityIdentifier("settings.checkForUpdates")
                            default:
                                Button(AppStrings.checkForUpdatesButton(isBusy: isBusy, in: lang)) {
                                    Task { @MainActor in
                                        await updater.checkForUpdates(userInitiated: true)
                                    }
                                }
                                .rewindButtonRole(.secondary)
                                .disabled(isBusy)
                                .accessibilityIdentifier("settings.checkForUpdates")
                            }
                        }
                    }
                    Divider()
                    SettingsRow(
                        AppStrings.autoCheckUpdatesTitle(in: lang),
                        help: AppStrings.autoCheckUpdatesHelp(in: lang)
                    ) {
                        Toggle(
                            AppStrings.autoCheckUpdatesTitle(in: lang),
                            isOn: Binding(
                                get: { updater.automaticallyChecksForUpdates },
                                set: { updater.setAutomaticallyChecksForUpdates($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.autoUpdate")
                    }
                }
            }
        }
    }
}

@MainActor
enum AppAboutMetadata {
    static let gitHubRepoURL = URL(string: "https://github.com/semantic-craft/coding-rewind")!
    static let releasesURL = URL(string: "https://github.com/semantic-craft/coding-rewind/releases")!

    static let appIcon: NSImage = {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSApplication.shared.applicationIconImage
    }()

    static var appBundleInfoDictionary: [String: Any]? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              bundleID == AppBundleID.selfApp || bundleID == AppBundleID.selfQAApp else {
            return nil
        }
        return Bundle.main.infoDictionary
    }

    static func versionString(
        updater: AppUpdater?,
        infoDictionary: [String: Any]? = AppAboutMetadata.appBundleInfoDictionary
    ) -> String? {
        if let raw = infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return updater?.currentVersion.description
    }

    static func buildNumber(
        infoDictionary: [String: Any]? = AppAboutMetadata.appBundleInfoDictionary
    ) -> String? {
        guard let raw = infoDictionary?["CFBundleVersion"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func openGitHubRepo(using coordinator: AppCoordinator) {
        coordinator.openURL(gitHubRepoURL)
    }

    static func openReleaseNotes(using coordinator: AppCoordinator) {
        coordinator.openURL(releasesURL)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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
                    .frame(width: 112, alignment: .leading)
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

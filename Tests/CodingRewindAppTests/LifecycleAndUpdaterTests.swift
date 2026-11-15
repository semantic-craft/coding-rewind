// SPDX-License-Identifier: MIT

import AppKit
import Carbon
import CodingRewindCore
import Darwin
import Foundation
import Testing
@testable import CodingRewindApp
@testable import KeyboardShortcuts

extension AppShortcutsTests {
    @Test func liveLanguageChangeRelocalizesMenusStatusItemSelectionPopupAndRecorder() throws {
        let appearanceSuite = "dev.codingrewind.qa.shortcuts.ui-l10n"
        func cleanAppearanceSuite() {
            UserDefaults(suiteName: appearanceSuite)?.removePersistentDomain(forName: appearanceSuite)
            _ = CFPreferencesAppSynchronize(appearanceSuite as CFString)
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(appearanceSuite).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        cleanAppearanceSuite()
        let defaults = try #require(UserDefaults(suiteName: appearanceSuite))
        defer {
            KeyboardShortcuts.localizationLanguageCode = nil
            NSApplication.shared.mainMenu = nil
            cleanAppearanceSuite()
        }

        let appearance = AppAppearancePreferences(
            defaults: defaults,
            applyPolicy: { _ in true },
            preferredLanguagesProvider: { ["zh-Hans-CN"] }
        )
        let shortcuts = AppShortcuts(language: appearance.effectiveLanguage) { _ in }
        defer { shortcuts.stop() }

        KeyboardShortcuts.localizationLanguageCode = appearance.effectiveLanguage.rawValue
        var currentLanguage = appearance.effectiveLanguage
        let statusController = StatusItemController(
            shortcuts: shortcuts,
            language: currentLanguage,
            snapshotProvider: {
                MenuStatusSnapshot(
                    isHUDVisible: false,
                    hotCardCount: 2,
                    checkedCardCount: 1,
                    pendingOutboxCount: 0,
                    connection: .unconfigured,
                    isPluginReady: true,
                    pluginSummary: L10n.pluginInstalledSummary(in: currentLanguage),
                    isAccessibilityTrusted: true,
                    recentCards: [],
                    language: currentLanguage
                )
            },
            onCommand: { _ in }
        )
        defer { NSStatusBar.system.removeStatusItem(statusController.statusItem) }

        let popup = SelectionPopupController(
            appearance: appearance,
            shortcuts: shortcuts,
            language: currentLanguage,
            onTriggerCapture: { .ignoredBusy },
            onPresentErrorHUD: {}
        )
        defer { popup.stop() }
        popup.showForTesting(anchorPID: getpid())

        NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(
            shortcuts: shortcuts,
            language: currentLanguage,
            onCommand: { _ in }
        )

        appearance.onEffectiveLanguageChange = { lang in
            currentLanguage = lang
            KeyboardShortcuts.localizationLanguageCode = lang.rawValue
            shortcuts.language = lang
            NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(
                shortcuts: shortcuts,
                language: lang,
                onCommand: { _ in }
            )
            statusController.updateLanguage(lang)
            popup.language = lang
        }

        let zhAppSubmenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
        #expect(zhAppSubmenu.items.contains { $0.title == "关于 Coding Rewind" })
        #expect(zhAppSubmenu.items.contains { $0.title == "检查更新…" })
        #expect(NSApplication.shared.mainMenu?.items.contains { $0.title == "操作" } == true)
        statusController.menuNeedsUpdate(statusController.menu)
        #expect(!statusController.menu.items.contains { $0.title == "检查更新…" })
        #expect(!statusController.menu.items.contains { $0.title == "关于 Coding Rewind" })
        #expect(statusController.menu.items.contains { $0.title == "设置…" })
        #expect(statusController.menu.items.contains { $0.title == "退出 Coding Rewind" })
        #expect(statusController.menu.items.contains { $0.title == "显示片段浮窗" })
        #expect(popup.phase.labelText(in: popup.language) == "暂存")
        #expect(KeyboardShortcuts.localizationLanguageCode == "zh-Hans")

        appearance.setLanguagePreference(.en)

        let enAppSubmenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
        #expect(enAppSubmenu.items.contains { $0.title == "About Coding Rewind" })
        #expect(enAppSubmenu.items.contains { $0.title == "Check for Updates…" })
        #expect(NSApplication.shared.mainMenu?.items.contains { $0.title == "Actions" } == true)
        statusController.menuNeedsUpdate(statusController.menu)
        #expect(!statusController.menu.items.contains { $0.title == "Check for Updates…" })
        #expect(!statusController.menu.items.contains { $0.title == "About Coding Rewind" })
        #expect(statusController.menu.items.contains { $0.title == "Settings…" })
        #expect(statusController.menu.items.contains { $0.title == "Quit Coding Rewind" })
        #expect(statusController.menu.items.contains { $0.title == "Show Clips HUD" })
        #expect(statusController.statusItem.button?.toolTip == AppStrings.statusItemTooltip(in: .en))
        #expect(popup.phase.labelText(in: popup.language) == "Stash")
        #expect(popup.isVisible)
        #expect(KeyboardShortcuts.localizationLanguageCode == "en")
        #expect(SettingsPage.allCases.last == .about)
        #expect(SettingsPage.about.title(in: .zhHans) == "关于")
        #expect(SettingsPage.about.title(in: .en) == "About")
    }

    @Suite(.serialized)
    @MainActor
    struct LifecycleAndUpdaterTests {
    nonisolated private static let updaterSuite = "dev.codingrewind.qa.shortcuts.updater"

    nonisolated private static func cleanUpdaterSuite() {
        UserDefaults(suiteName: updaterSuite)?.removePersistentDomain(forName: updaterSuite)
        _ = CFPreferencesAppSynchronize(updaterSuite as CFString)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(updaterSuite).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }

    init() {
        _ = AppShortcutsTests.defaults
        Self.cleanUpdaterSuite()
    }

    @Test func launchContextDistinguishesUpdateRestartBackgroundLoginItemAndInteractive() {
        let afterUpdate = LaunchContext.captureCurrent(
            arguments: ["/Applications/CodingRewind.app/Contents/MacOS/CodingRewindApp", "--restarted-after-update"],
            environment: [:],
            appleEventDescriptor: nil
        )
        #expect(afterUpdate.reason == .relaunchedAfterUpdate)
        #expect(!afterUpdate.shouldPresentHUDOnInitialLaunch)

        let background = LaunchContext.captureCurrent(
            arguments: ["/Applications/CodingRewind.app/Contents/MacOS/CodingRewindApp", "--background"],
            environment: [:],
            appleEventDescriptor: nil
        )
        #expect(background.reason == .commandLineBackground)
        #expect(!background.shouldPresentHUDOnInitialLaunch)

        let loginEvent = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        loginEvent.setParam(
            NSAppleEventDescriptor(enumCode: DescType(keyAELaunchedAsLogInItem)),
            forKeyword: AEKeyword(keyAEPropData)
        )
        let loginLaunch = LaunchContext.captureCurrent(
            arguments: ["/Applications/CodingRewind.app/Contents/MacOS/CodingRewindApp"],
            environment: [:],
            appleEventDescriptor: loginEvent
        )
        #expect(loginLaunch.reason == .systemLoginItem)
        #expect(!loginLaunch.shouldPresentHUDOnInitialLaunch)

        let interactive = LaunchContext.captureCurrent(
            arguments: ["/Applications/CodingRewind.app/Contents/MacOS/CodingRewindApp"],
            environment: [:],
            appleEventDescriptor: nil
        )
        #expect(interactive.reason == .interactive)
        #expect(interactive.shouldPresentHUDOnInitialLaunch)
    }

    @Test func loginItemControllerHandlesEnableDisableApprovalRelocalizationAndQAIsolation() {
        let backend = InMemoryLoginItemBackend(initialState: .disabled)
        let controller = LoginItemController(backend: backend, language: .zhHans)
        #expect(controller.state == .disabled)
        #expect(!controller.state.isToggleOn)

        controller.setEnabled(true)
        #expect(controller.state == .enabled)
        #expect(controller.state.isToggleOn)

        controller.setEnabled(false)
        #expect(controller.state == .disabled)

        backend.approvalRequiredOnEnable = true
        controller.setEnabled(true)
        #expect(controller.state == .requiresApproval)
        #expect(controller.state.isToggleOn)
        controller.openSystemSettings()
        #expect(backend.openSettingsCallCount == 1)

        struct RegistrationFailure: LocalizedError {
            var errorDescription: String? { "SMAppService denied" }
        }
        backend.simulatedError = RegistrationFailure()
        controller.setEnabled(false)
        #expect(controller.errorMessage == "无法更新开机自启动设置：SMAppService denied")
        controller.language = .en
        #expect(controller.errorMessage == "Could not update Launch at Login: SMAppService denied")

        let unbundled = LoginItemController.live(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/usr/bin/env"),
            language: .en
        )
        #expect(unbundled.state == .unavailable(.unbundledExecutable))

        let qaIsolated = LoginItemController.live(
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            bundleURL: URL(fileURLWithPath: "/Applications/CodingRewind.app"),
            language: .en
        )
        #expect(qaIsolated.state == .unavailable(.qaIsolated))

        for relocatedPath in [
            "/private/var/folders/xx/yy/T/AppTranslocation/ABCD/d/CodingRewind.app",
            "/Volumes/CodingRewindInstaller/CodingRewind.app",
            "/Users/tester/Projects/coding-rewind/.build/CodingRewind.app"
        ] {
            let relocated = LoginItemController.live(
                environment: [:],
                bundleURL: URL(fileURLWithPath: relocatedPath),
                language: .en
            )
            #expect(relocated.state == .unavailable(.relocatedBundle))
        }
        #expect(AppStrings.launchAtLoginHelp(.unavailable(.relocatedBundle), in: .zhHans).contains("应用程序"))
        #expect(AppStrings.launchAtLoginHelp(.unavailable(.relocatedBundle), in: .en).contains("Applications"))
    }

    @Test func updaterReportsUpToDateAndRejectsChecksumMismatchOrSignatureDowngradeWithoutLeakingStaging() async throws {
        let root = makeTestRoot()
        let installedURL = root.appendingPathComponent("Installed/CodingRewind.app", isDirectory: true)
        defer {
            AppUpdater.unregisterBundleFromLaunchServices(installedURL)
            try? FileManager.default.removeItem(at: root)
            Self.cleanUpdaterSuite()
        }

        try buildSignedDummyApp(at: installedURL, version: "0.3.2", bundleID: AppBundleID.selfQAApp)
        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.updaterSuite))

        let sameVersionJSON = makeReleaseJSON(version: "0.3.2")
        let upToDateUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            transport: MockReleaseTransport(releaseJSON: sameVersionJSON, checksumsText: "", archiveSourceURL: nil)
        )
        await upToDateUpdater.checkForUpdates(userInitiated: true)
        #expect(upToDateUpdater.state == .upToDate(SemanticVersion(major: 0, minor: 3, patch: 2)))
        #expect(upToDateUpdater.lastCheckedAt != nil)

        let stagedBuildURL = root.appendingPathComponent("Build/CodingRewind.app", isDirectory: true)
        defer { AppUpdater.unregisterBundleFromLaunchServices(stagedBuildURL) }
        try buildSignedDummyApp(at: stagedBuildURL, version: "0.4.0", bundleID: AppBundleID.selfQAApp)
        let archiveURL = root.appendingPathComponent("Artifacts/CodingRewind-v0.4.0-macos-arm64.zip")
        try zipAppBundle(at: stagedBuildURL, to: archiveURL)

        let wrongChecksums = "\(String(repeating: "00", count: 32))  CodingRewind-v0.4.0-macos-arm64.zip\n"
        let mismatchUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .zhHans,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.4.0"),
                checksumsText: wrongChecksums,
                archiveSourceURL: archiveURL
            )
        )
        await mismatchUpdater.checkForUpdates(userInitiated: true)
        #expect(mismatchUpdater.state == .failed("安装包 SHA-256 校验不匹配，已拒绝安装。"))
        mismatchUpdater.language = .en
        #expect(mismatchUpdater.state == .failed("Archive SHA-256 checksum mismatch; update was rejected."))
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        let validDigest = try SHA256Digest.compute(fileAt: archiveURL)
        let validChecksums = "\(validDigest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\n"
        let downgradeUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.4.0"),
                checksumsText: validChecksums,
                archiveSourceURL: archiveURL
            ),
            signatureInspector: StubSignatureInspector(
                installed: InspectedCodeSignature(
                    authority: .developerID(teamID: BundleSignatureAuthority.defaultReleaseTeamID),
                    bundleIdentifier: AppBundleID.selfQAApp
                ),
                staged: InspectedCodeSignature(
                    authority: .adhoc,
                    bundleIdentifier: AppBundleID.selfQAApp
                )
            )
        )
        await downgradeUpdater.checkForUpdates(userInitiated: true)
        if case .manualDownloadRequired(let candidate, let reason) = downgradeUpdater.state {
            #expect(candidate.version == SemanticVersion(major: 0, minor: 4, patch: 0))
            #expect(reason == .signatureDowngradeBlocked)
        } else {
            Issue.record("Expected manualDownloadRequired(.signatureDowngradeBlocked), got \(downgradeUpdater.state)")
        }
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)
    }

    @Test func secStaticCodeSignatureInspectorValidatesAdhocBundleAndRejectsTamperedExecutable() throws {
        let root = makeTestRoot()
        let appURL = root.appendingPathComponent("Signed/CodingRewind.app", isDirectory: true)
        defer {
            AppUpdater.unregisterBundleFromLaunchServices(appURL)
            try? FileManager.default.removeItem(at: root)
        }

        try buildSignedDummyApp(at: appURL, version: "0.3.2", bundleID: AppBundleID.selfQAApp)
        let inspector = SecStaticCodeSignatureInspector()
        let inspected = try inspector.inspect(bundleURL: appURL)
        #expect(inspected.authority == .adhoc)
        #expect(inspected.bundleIdentifier == AppBundleID.selfQAApp)

        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/CodingRewindApp", isDirectory: false)
        var tamperedBytes = try Data(contentsOf: binaryURL)
        let targetIndex = max(0, tamperedBytes.count / 2)
        tamperedBytes[targetIndex] ^= 0xFF
        try tamperedBytes.write(to: binaryURL)

        do {
            _ = try inspector.inspect(bundleURL: appURL)
            Issue.record("Expected tampered executable to fail SecStaticCode validation")
        } catch let error as CodeSignatureInspectionError {
            if case .invalidOrTamperedSignature = error {
            } else {
                Issue.record("Unexpected CodeSignatureInspectionError case: \(error)")
            }
        }

        let mismatchedIDApp = root.appendingPathComponent("MismatchedID/CodingRewind.app", isDirectory: true)
        defer { AppUpdater.unregisterBundleFromLaunchServices(mismatchedIDApp) }
        try buildSignedDummyApp(at: mismatchedIDApp, version: "0.3.2", bundleID: AppBundleID.selfQAApp)
        try runChecked(
            "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--identifier", "dev.other.signedid", mismatchedIDApp.path]
        )
        AppUpdater.unregisterBundleFromLaunchServices(mismatchedIDApp)
        #expect(throws: CodeSignatureInspectionError.bundleIdentifierMismatch(
            plist: AppBundleID.selfQAApp,
            signed: "dev.other.signedid"
        )) {
            try inspector.inspect(bundleURL: mismatchedIDApp)
        }

        let symlinkApp = root.appendingPathComponent("Symlinked/CodingRewind.app", isDirectory: true)
        defer { AppUpdater.unregisterBundleFromLaunchServices(symlinkApp) }
        try buildSignedDummyApp(at: symlinkApp, version: "0.3.2", bundleID: AppBundleID.selfQAApp)
        let outsideTarget = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideTarget)
        let resourcesDir = symlinkApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: resourcesDir.appendingPathComponent("escape.txt"),
            withDestinationURL: outsideTarget
        )
        do {
            _ = try inspector.inspect(bundleURL: symlinkApp)
            Issue.record("Expected symlink inside bundle to fail strict SecStaticCode validation")
        } catch is CodeSignatureInspectionError {
        }
    }

    @Test func updaterPerformsAtomicSwapRefreshesSidecarCapturesRelaunchArgsAndPrunesRollbacks() async throws {
        let root = makeTestRoot()
        let installedURL = root.appendingPathComponent("Installed/CodingRewind.app", isDirectory: true)
        let newBuildURL = root.appendingPathComponent("NewBuild/CodingRewind.app", isDirectory: true)
        defer {
            AppUpdater.unregisterBundleFromLaunchServices(installedURL)
            AppUpdater.unregisterBundleFromLaunchServices(newBuildURL)
            try? FileManager.default.removeItem(at: root)
            Self.cleanUpdaterSuite()
        }

        try buildSignedDummyApp(
            at: installedURL,
            version: "0.3.2",
            bundleID: AppBundleID.selfQAApp,
            sidecarMarker: "sidecar-v0.3.2",
            cliMarker: "cli-v0.3.2"
        )
        try buildSignedDummyApp(
            at: newBuildURL,
            version: "0.3.3",
            bundleID: AppBundleID.selfQAApp,
            sidecarMarker: "sidecar-v0.3.3",
            cliMarker: "cli-v0.3.3"
        )

        let archiveURL = root.appendingPathComponent("Artifacts/CodingRewind-v0.3.3-macos-arm64.zip")
        try zipAppBundle(at: newBuildURL, to: archiveURL)
        let digest = try SHA256Digest.compute(fileAt: archiveURL)
        let checksums = "\(digest.hexValue)  CodingRewind-v0.3.3-macos-arm64.zip\n"

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let installedSidecarURL = AntigravityIntegration.stableSidecarBinaryURL(in: paths.dataDirectoryURL)
        let installedCLIURL = AntigravityIntegration.stableCLIBinaryURL(in: paths.dataDirectoryURL)
        let staleBridgeURL = paths.dataDirectoryURL.appendingPathComponent("bin/memos-mcp-bridge.sh")
        try AtomicFile.writeUTF8("#!/bin/sh\n# sidecar-v0.3.2\nexit 0\n", to: installedSidecarURL, permissions: 0o755)
        try AtomicFile.writeUTF8("#!/bin/sh\n# legacy-bridge\nexit 0\n", to: staleBridgeURL, permissions: 0o755)

        let relaunchArgsFile = root.appendingPathComponent("relaunch-args.txt")
        let fakeOpenScript = root.appendingPathComponent("fake-open.sh")
        try AtomicFile.writeUTF8(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(relaunchArgsFile.path)"
            """,
            to: fakeOpenScript,
            permissions: 0o755
        )

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.05"]
        try sleeper.run()
        let waitPID = sleeper.processIdentifier

        let defaults = try #require(UserDefaults(suiteName: Self.updaterSuite))
        var terminated = false
        let updater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.3.3"),
                checksumsText: checksums,
                archiveSourceURL: archiveURL
            ),
            signatureInspector: SecStaticCodeSignatureInspector(),
            relaunchExecutablePath: fakeOpenScript.path,
            waitProcessIDProvider: { waitPID },
            onTerminate: { terminated = true }
        )

        await updater.checkForUpdates(userInitiated: true)
        guard case .readyToInstall(let staged) = updater.state else {
            Issue.record("Expected readyToInstall state, got \(updater.state)")
            return
        }
        #expect(staged.candidate.version == SemanticVersion(major: 0, minor: 3, patch: 3))

        let swapped = await updater.installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: true)
        sleeper.waitUntilExit()
        AppUpdater.unregisterBundleFromLaunchServices(installedURL)
        #expect(swapped)
        #expect(terminated)

        let plistData = try Data(contentsOf: installedURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == "0.3.3")

        let refreshedSidecar = try String(contentsOf: installedSidecarURL, encoding: .utf8)
        #expect(refreshedSidecar.contains("sidecar-v0.3.3"))
        let refreshedCLI = try String(contentsOf: installedCLIURL, encoding: .utf8)
        #expect(refreshedCLI.contains("cli-v0.3.3"))
        #expect(FileManager.default.isExecutableFile(atPath: installedCLIURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleBridgeURL.path))

        let recordedArgs = try String(contentsOf: relaunchArgsFile, encoding: .utf8)
        #expect(recordedArgs == "\(installedURL.path)/Contents/MacOS/CodingRewindApp\n--restarted-after-update\n")
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        let staleRollback = paths.updatesDirectoryURL.appendingPathComponent("rollback-CodingRewind.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRollback, withIntermediateDirectories: true)
        updater.pruneStaleStagingDirectories()
        #expect(!FileManager.default.fileExists(atPath: staleRollback.path))
    }

    @Test func updaterHardensStagedDiscoveryInstallTimeRecheckCrossVolumeCopyAndRollbackRelaunch() async throws {
        let root = makeTestRoot()
        let installedURL = root.appendingPathComponent("Installed/CodingRewind.app", isDirectory: true)
        let newBuildURL = root.appendingPathComponent("NewBuild/CodingRewind.app", isDirectory: true)
        defer {
            _ = chmod(installedURL.deletingLastPathComponent().path, 0o755)
            AppUpdater.unregisterBundleFromLaunchServices(installedURL)
            AppUpdater.unregisterBundleFromLaunchServices(newBuildURL)
            try? FileManager.default.removeItem(at: root)
            Self.cleanUpdaterSuite()
        }

        let unpackedProbe = root.appendingPathComponent("UnpackedProbe", isDirectory: true)
        let decoyReal = unpackedProbe.appendingPathComponent("AlphaHelper.app", isDirectory: true)
        let expectedReal = unpackedProbe.appendingPathComponent("CodingRewind.app", isDirectory: true)
        let symlinkBundle = unpackedProbe.appendingPathComponent("CodingRewindLink.app", isDirectory: false)
        try FileManager.default.createDirectory(at: decoyReal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expectedReal, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkBundle, withDestinationURL: decoyReal)
        #expect(AppUpdater.findStagedAppBundle(in: unpackedProbe, expectedName: "CodingRewind.app") == expectedReal.standardizedFileURL)
        #expect(AppUpdater.findStagedAppBundle(in: unpackedProbe, expectedName: "CodingRewindLink.app") == decoyReal.standardizedFileURL)

        try buildSignedDummyApp(at: installedURL, version: "0.3.2", bundleID: AppBundleID.selfQAApp)
        try buildSignedDummyApp(at: newBuildURL, version: "0.3.3", bundleID: AppBundleID.selfQAApp, sidecarMarker: "sidecar-xvol")
        let archiveURL = root.appendingPathComponent("Artifacts/CodingRewind-v0.3.3-macos-arm64.zip")
        try zipAppBundle(at: newBuildURL, to: archiveURL)
        let digest = try SHA256Digest.compute(fileAt: archiveURL)
        let checksums = "\(digest.hexValue)  CodingRewind-v0.3.3-macos-arm64.zip\n"

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.updaterSuite))

        var terminatedOnTamper = false
        let tamperUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .en,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.3.3"),
                checksumsText: checksums,
                archiveSourceURL: archiveURL
            ),
            signatureInspector: SecStaticCodeSignatureInspector(),
            onTerminate: { terminatedOnTamper = true }
        )
        await tamperUpdater.checkForUpdates(userInitiated: true)
        guard case .readyToInstall(let stagedForTamper) = tamperUpdater.state else {
            Issue.record("Expected readyToInstall before tamper test, got \(tamperUpdater.state)")
            return
        }
        let stagedBinary = stagedForTamper.stagedAppURL.appendingPathComponent("Contents/MacOS/CodingRewindApp")
        var bytes = try Data(contentsOf: stagedBinary)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: stagedBinary)
        let tamperInstalled = await tamperUpdater.installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: true)
        #expect(!tamperInstalled)
        #expect(!terminatedOnTamper)
        #expect(tamperUpdater.state == .failed("Code signature verification failed; update was rejected."))
        #expect(!FileManager.default.fileExists(atPath: stagedForTamper.stagingDirectoryURL.path))

        var terminatedOnReadOnly = false
        let readOnlyUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.3.3"),
                checksumsText: checksums,
                archiveSourceURL: archiveURL
            ),
            signatureInspector: SecStaticCodeSignatureInspector(),
            onTerminate: { terminatedOnReadOnly = true }
        )
        await readOnlyUpdater.checkForUpdates(userInitiated: true)
        _ = chmod(installedURL.deletingLastPathComponent().path, 0o555)
        let readOnlyInstalled = await readOnlyUpdater.installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: true)
        _ = chmod(installedURL.deletingLastPathComponent().path, 0o755)
        #expect(!readOnlyInstalled)
        #expect(!terminatedOnReadOnly)
        if case .manualDownloadRequired(_, let reason) = readOnlyUpdater.state {
            #expect(reason == .installLocationNotWritable)
        } else {
            Issue.record("Expected manualDownloadRequired(.installLocationNotWritable), got \(readOnlyUpdater.state)")
        }

        let relaunchArgsFile = root.appendingPathComponent("xvol-relaunch.txt")
        let fakeOpenScript = root.appendingPathComponent("xvol-open.sh")
        try AtomicFile.writeUTF8(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(relaunchArgsFile.path)\"\n",
            to: fakeOpenScript,
            permissions: 0o755
        )
        let installedSidecarURL = AntigravityIntegration.stableSidecarBinaryURL(in: paths.dataDirectoryURL)
        try AtomicFile.writeUTF8("#!/bin/sh\necho old\n", to: installedSidecarURL, permissions: 0o755)
        let crossVolumeUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.3.3"),
                checksumsText: checksums,
                archiveSourceURL: archiveURL
            ),
            signatureInspector: SecStaticCodeSignatureInspector(),
            sameVolumeCheck: { lhs, rhs in
                lhs.path.contains("/Installed") && rhs.path.contains("/Installed")
            },
            relaunchExecutablePath: fakeOpenScript.path,
            waitProcessIDProvider: { 999_999 },
            onTerminate: {}
        )
        await crossVolumeUpdater.checkForUpdates(userInitiated: true)
        let xvolSwapped = await crossVolumeUpdater.installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: true)
        AppUpdater.unregisterBundleFromLaunchServices(installedURL)
        #expect(xvolSwapped)
        #expect(try String(contentsOf: installedSidecarURL, encoding: .utf8).contains("sidecar-xvol"))

        let rescueSwapDir = installedURL.deletingLastPathComponent().appendingPathComponent(".CodingRewind-swap-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: rescueSwapDir, withIntermediateDirectories: true)
        let rollbackURL = rescueSwapDir.appendingPathComponent("rollback.app", isDirectory: true)
        try FileManager.default.moveItem(at: installedURL, to: rollbackURL)
        crossVolumeUpdater.pruneStaleStagingDirectories()
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
        #expect(!FileManager.default.fileExists(atPath: rescueSwapDir.path))

        let rollbackRelaunchFile = root.appendingPathComponent("rollback-relaunch.txt")
        let rollbackOpenScript = root.appendingPathComponent("rollback-open.sh")
        try AtomicFile.writeUTF8(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(rollbackRelaunchFile.path)\"\n",
            to: rollbackOpenScript,
            permissions: 0o755
        )
        let brokenSwapDir = installedURL.deletingLastPathComponent().appendingPathComponent(".CodingRewind-swap-broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenSwapDir, withIntermediateDirectories: true)
        let swapScriptURL = paths.updatesDirectoryURL.appendingPathComponent("apply-update.sh")
        let rollbackProc = Process()
        rollbackProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        rollbackProc.arguments = [
            swapScriptURL.path,
            "999999",
            installedURL.path,
            brokenSwapDir.path,
            paths.updatesDirectoryURL.appendingPathComponent("nonexistent-staging").path,
            installedSidecarURL.path,
            "",
            rollbackOpenScript.path
        ]
        try rollbackProc.run()
        rollbackProc.waitUntilExit()
        #expect(rollbackProc.terminationStatus != 0)
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
        #expect(!FileManager.default.fileExists(atPath: brokenSwapDir.path))
        let rollbackRelaunchArgs = try String(contentsOf: rollbackRelaunchFile, encoding: .utf8)
        #expect(rollbackRelaunchArgs == "\(installedURL.path)/Contents/MacOS/CodingRewindApp\n--restarted-after-update\n")
    }

    @Test func updaterErrorRelocalizationAvoidsMemosCopyAndSettingsConnectionDraftRelocalizesAllOutcomes() async throws {
        let root = makeTestRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            Self.cleanUpdaterSuite()
        }
        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.updaterSuite))

        struct FailingHTTPTransport: ReleaseTransport {
            func fetchLatestReleaseJSON() async throws -> Data {
                throw ReleaseTransportError.httpStatus(502, "Bad Gateway")
            }
            func fetchText(from url: URL) async throws -> String { "" }
            func downloadArchive(from url: URL, to destinationURL: URL) async throws {}
        }

        let updater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: root.appendingPathComponent("CodingRewind.app", isDirectory: true),
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .zhHans,
            transport: FailingHTTPTransport()
        )
        await updater.checkForUpdates(userInitiated: true)
        if case .failed(let zhMsg) = updater.state {
            #expect(zhMsg.contains("GitHub Releases"))
            #expect(!zhMsg.contains("Memos"))
        } else {
            Issue.record("Expected failed state, got \(updater.state)")
        }

        updater.language = .en
        if case .failed(let enMsg) = updater.state {
            #expect(enMsg.contains("GitHub Releases"))
            #expect(enMsg.contains("HTTP 502"))
            #expect(!enMsg.contains("Memos"))
        } else {
            Issue.record("Expected failed state in English, got \(updater.state)")
        }

        struct NoopCapturer: SelectionCapturing {
            func captureFrontmostSelection() async throws -> CapturedSelection {
                throw RewindError.emptySelection
            }
        }
        let qaEnv = [
            StoragePaths.qaEnvironmentKey: "1",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1",
            StoragePaths.dataDirEnvironmentKey: paths.dataDirectoryURL.path,
            StoragePaths.antigravityConfigEnvironmentKey: paths.antigravityConfigDirectoryURL.path
        ]
        let coord = try AppCoordinator(paths: paths, environment: qaEnv, capturer: NoopCapturer(), language: .zhHans)
        let draft = SettingsConnectionDraft(memosURL: "not-a-valid-url")
        await draft.save(using: coord)
        #expect(draft.saveFailed)
        #expect(draft.saveMessage == RewindError.invalidMemosURL("not-a-valid-url").localizedDescription(in: .zhHans))
        draft.updateLanguage(.en)
        #expect(draft.saveFailed)
        #expect(draft.saveMessage == RewindError.invalidMemosURL("not-a-valid-url").localizedDescription(in: .en))

        draft.urlDraft = "https://memos.example.com"
        draft.tokenDraft = ""
        await draft.save(using: coord)
        #expect(!draft.saveFailed)
        #expect(draft.saveMessage == AppStrings.connectionCheckMessage(.missingToken, in: .zhHans))
        draft.updateLanguage(.en)
        #expect(!draft.saveFailed)
        #expect(draft.saveMessage == AppStrings.connectionCheckMessage(.missingToken, in: .en))
    }

    @Test func cloudSyncPageUsesPlainTitlesAndIntroLines() {
        #expect(SettingsPage.connection.title(in: .zhHans) == "云端同步")
        #expect(SettingsPage.connection.title(in: .en) == "Cloud Sync")
        #expect(SettingsPage.connection.title == "云端同步")
        for language in AppLanguage.allCases {
            let strings = [
                AppStrings.cloudSyncLocalOnlyIntro(in: language),
                AppStrings.cloudSyncServerIntro(in: language),
                AppStrings.deploymentGuideLink(in: language),
                AppStrings.getTokenButton(in: language),
                AppStrings.verifyingConnection(in: language),
                AppStrings.memosServiceSectionTitle(in: language),
                AppStrings.connectionCheckMessage(.verified, in: language),
                AppStrings.connectionCheckMessage(.localOnly, in: language),
                AppStrings.connectionCheckMessage(.missingToken, in: language),
                AppStrings.connectionCheckMessage(.failed(.invalidServerResponse), in: language),
                AppStrings.connectionCheckMessage(.failed(.httpError(statusCode: 403, body: "")), in: language)
            ]
            for text in strings {
                #expect(!text.isEmpty)
                #expect(!text.contains("—"))
            }
        }
        #expect(AppStrings.cloudSyncLocalOnlyIntro(in: .zhHans).contains("Antigravity"))
        #expect(AppStrings.cloudSyncLocalOnlyIntro(in: .zhHans).contains("Codex"))
        #expect(AppStrings.cloudSyncServerIntro(in: .zhHans).contains("跨设备"))
        #expect(AppStrings.cloudSyncServerIntro(in: .en).contains("across devices"))
        #expect(AppStrings.deploymentGuideURL.absoluteString == "https://github.com/semantic-craft/coding-rewind/tree/main/deploy/vps")
    }

    @Test func accessTokenPlaceholderFollowsSavedTokenState() {
        #expect(AppStrings.accessTokenPlaceholder(hasSavedToken: false, in: .zhHans) == "请输入访问令牌")
        #expect(AppStrings.accessTokenPlaceholder(hasSavedToken: true, in: .zhHans) == "已保存，留空则保留现有令牌")
        #expect(AppStrings.accessTokenPlaceholder(hasSavedToken: false, in: .en) == "Enter access token")
        #expect(AppStrings.accessTokenPlaceholder(hasSavedToken: true, in: .en) == "Saved; leave blank to keep existing token")
    }

    @Test func connectionCheckMessagesDistinguishAuthFromOtherFailures() {
        let auth401 = AppStrings.connectionCheckMessage(.failed(.httpError(statusCode: 401, body: "x")), in: .zhHans)
        let auth403 = AppStrings.connectionCheckMessage(.failed(.httpError(statusCode: 403, body: "x")), in: .zhHans)
        let server = AppStrings.connectionCheckMessage(.failed(.httpError(statusCode: 502, body: "Bad Gateway")), in: .zhHans)
        let html = AppStrings.connectionCheckMessage(.failed(.invalidServerResponse), in: .en)
        let network = AppStrings.connectionCheckMessage(.failed(.networkFailure("offline")), in: .en)
        #expect(auth401 == auth403)
        #expect(auth401.contains("访问令牌"))
        #expect(server.contains("HTTP 502"))
        #expect(html.contains("Memos instance"))
        #expect(network.contains("offline"))
        #expect(!AppStrings.connectionCheckMessage(.verified, in: .zhHans).contains("已配置"))
    }

    @Test func connectionDraftEnablesConsoleButtonOnlyForUsableURLs() {
        let draft = SettingsConnectionDraft(memosURL: "")
        #expect(draft.consoleURL == nil)
        draft.urlDraft = "memos.example.com"
        #expect(draft.consoleURL == nil)
        draft.urlDraft = "ftp://memos.example.com"
        #expect(draft.consoleURL == nil)
        draft.urlDraft = " https://memos.example.com/api/memos/ "
        #expect(draft.consoleURL?.absoluteString == "https://memos.example.com")
        draft.urlDraft = "http://127.0.0.1:5230"
        #expect(draft.consoleURL?.absoluteString == "http://127.0.0.1:5230")
    }

    @Test func coordinatorOpensLinksThroughTheSharedOpener() throws {
        struct NoopCapturer: SelectionCapturing {
            func captureFrontmostSelection() async throws -> CapturedSelection { throw RewindError.emptySelection }
        }
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let coord = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: NoopCapturer())
        var opened: [URL] = []
        coord.onOpenURL = { opened.append($0) }
        let draft = SettingsConnectionDraft(memosURL: "https://memos.example.com/api/memos")
        coord.openURL(AppStrings.deploymentGuideURL)
        if let consoleURL = draft.consoleURL { coord.openURL(consoleURL) }
        #expect(opened.map(\.absoluteString) == [
            "https://github.com/semantic-craft/coding-rewind/tree/main/deploy/vps",
            "https://memos.example.com"
        ])
    }

    @Test func connectionDraftReportsLocalOnlyAndNetworkFailureInline() async throws {
        struct NoopCapturer: SelectionCapturing {
            func captureFrontmostSelection() async throws -> CapturedSelection { throw RewindError.emptySelection }
        }
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let environment = [
            StoragePaths.qaEnvironmentKey: "1",
            StoragePaths.memosTokenEnvironmentKey: "fixture-token"
        ]
        let coord = try AppCoordinator(paths: paths, environment: environment, capturer: NoopCapturer(), language: .zhHans)
        #expect(coord.connectionSettings.hasSavedToken)

        let draft = SettingsConnectionDraft(memosURL: "")
        await draft.save(using: coord)
        #expect(!draft.saveFailed)
        #expect(!draft.isVerifying)
        #expect(draft.saveMessage == AppStrings.connectionCheckMessage(.localOnly, in: .zhHans))

        draft.urlDraft = "http://127.0.0.1:1"
        await draft.save(using: coord)
        #expect(draft.saveFailed)
        #expect(!draft.isVerifying)
        #expect(draft.saveMessage?.hasPrefix("设置已保存，但连接失败。") == true)
        #expect(coord.connectionSettings.memosURL == "http://127.0.0.1:1")
        draft.updateLanguage(.en)
        #expect(draft.saveMessage?.hasPrefix("Settings saved, but the connection failed.") == true)
    }

    @Test func aboutSettingsPageOwnsUpdateCheckAndMenuRouting() async throws {
        let root = makeTestRoot()
        let defaults = try #require(UserDefaults(suiteName: Self.updaterSuite))
        defer {
            try? FileManager.default.removeItem(at: root)
            Self.cleanUpdaterSuite()
        }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        struct NoopCapturer: SelectionCapturing {
            func captureFrontmostSelection() async throws -> CapturedSelection {
                throw RewindError.emptySelection
            }
        }
        let qaEnv = [
            StoragePaths.qaEnvironmentKey: "1",
            StoragePaths.dataDirEnvironmentKey: paths.dataDirectoryURL.path,
            StoragePaths.antigravityConfigEnvironmentKey: paths.antigravityConfigDirectoryURL.path
        ]
        let coord = try AppCoordinator(paths: paths, environment: qaEnv, capturer: NoopCapturer(), language: .zhHans)
        let appearance = AppAppearancePreferences(
            defaults: defaults,
            applyPolicy: { _ in true },
            preferredLanguagesProvider: { ["zh-Hans-CN"] }
        )
        let delegate = CodingRewindAppDelegate()
        let shortcuts = AppShortcuts(language: appearance.effectiveLanguage) { delegate.perform($0) }
        defer { shortcuts.stop() }
        let updater = AppUpdater(
            paths: paths,
            environment: qaEnv,
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: root.appendingPathComponent("CodingRewind.app", isDirectory: true),
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .zhHans,
            transport: MockReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.3.2"),
                checksumsText: "",
                archiveSourceURL: nil
            )
        )
        let settings = SettingsWindowController(
            coordinator: coord,
            appearance: appearance,
            shortcuts: shortcuts,
            updater: updater,
            onCommand: { delegate.perform($0) }
        )
        defer { settings.window?.close() }
        let statusController = StatusItemController(
            shortcuts: shortcuts,
            language: .zhHans,
            snapshotProvider: {
                coord.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: true)
            },
            onCommand: { delegate.perform($0) }
        )
        defer { NSStatusBar.system.removeStatusItem(statusController.statusItem) }

        delegate.coordinator = coord
        delegate.appearance = appearance
        delegate.shortcuts = shortcuts
        delegate.updater = updater
        delegate.settingsWindowController = settings
        delegate.statusItemController = statusController

        delegate.perform(.showAbout)
        #expect(settings.window?.isVisible == true)
        #expect(settings.navigationModel.selectedPage == .about)

        settings.navigationModel.selectedPage = .general
        settings.window?.close()
        #expect(settings.window?.isVisible != true)

        delegate.perform(.checkForUpdates)
        #expect(settings.window?.isVisible == true)
        #expect(settings.navigationModel.selectedPage == .about)

        let expectedVersion = SemanticVersion(major: 0, minor: 3, patch: 2)
        let deadline = ContinuousClock.now + .milliseconds(500)
        while updater.state != .upToDate(expectedVersion) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(updater.state == .upToDate(expectedVersion))

        statusController.menuNeedsUpdate(statusController.menu)
        let items = statusController.menu.items
        #expect(!items.contains { $0.title == AppStrings.checkForUpdatesMenu(in: .zhHans) })
        #expect(!items.contains { $0.title == AppStrings.aboutApp(in: .zhHans) })
        let settingsIndex = try #require(items.firstIndex { $0.title == AppStrings.settingsEllipsis(in: .zhHans) })
        let quitIndex = try #require(items.firstIndex { $0.title == AppStrings.quitApp(in: .zhHans) })
        #expect(quitIndex == settingsIndex + 2)
        #expect(items[settingsIndex + 1].isSeparatorItem)
        #expect(items.first?.isSeparatorItem == false)
        #expect(items.last?.isSeparatorItem == false)
        #expect(!zip(items, items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })

        let mainMenu = MainMenuBuilder.buildMainMenu(shortcuts: shortcuts, language: .zhHans) {
            delegate.perform($0)
        }
        let appSubmenu = try #require(mainMenu.items.first?.submenu)
        let aboutMenuItem = try #require(appSubmenu.items.first { $0.title == AppStrings.aboutApp(in: .zhHans) })
        #expect(appSubmenu.items.contains { $0.title == AppStrings.checkForUpdatesMenu(in: .zhHans) })

        settings.navigationModel.selectedPage = .general
        settings.window?.close()
        #expect(settings.window?.isVisible != true)

        let aboutAction = try #require(aboutMenuItem.action)
        _ = aboutMenuItem.target?.perform(aboutAction, with: aboutMenuItem)
        #expect(settings.window?.isVisible == true)
        #expect(settings.navigationModel.selectedPage == .about)

        #expect(AppAboutMetadata.appIcon === AppAboutMetadata.appIcon)
        #expect(AppAboutMetadata.appBundleInfoDictionary == nil)
        #expect(AppAboutMetadata.buildNumber() == nil)
        #expect(
            AppAboutMetadata.versionString(
                updater: updater,
                infoDictionary: ["CFBundleShortVersionString": " 1.2.3 "]
            ) == "1.2.3"
        )
        #expect(AppAboutMetadata.buildNumber(infoDictionary: ["CFBundleVersion": " 42 "]) == "42")
        #expect(AppAboutMetadata.buildNumber(infoDictionary: ["CFBundleVersion": "   "]) == nil)
        #expect(AppAboutMetadata.versionString(updater: updater, infoDictionary: nil) == "0.3.2")
        #expect(AppAboutMetadata.versionString(updater: nil, infoDictionary: nil) == nil)

        var openedURLs: [URL] = []
        coord.onOpenURL = { url in
            openedURLs.append(url)
        }
        AppAboutMetadata.openGitHubRepo(using: coord)
        AppAboutMetadata.openReleaseNotes(using: coord)
        #expect(openedURLs == [AppAboutMetadata.gitHubRepoURL, AppAboutMetadata.releasesURL])

        #expect(
            AppStrings.aboutVersionLine(version: "0.3.2", build: "42", in: .zhHans)
                == "版本 0.3.2（Build 42） · MIT 许可证"
        )
        #expect(
            AppStrings.aboutVersionLine(version: "0.3.2", build: "42", in: .en)
                == "Version 0.3.2 (Build 42) · MIT License"
        )
        #expect(
            AppStrings.aboutVersionLine(version: " 0.3.2 ", build: "   ", in: .zhHans)
                == "版本 0.3.2 · MIT 许可证"
        )
        #expect(
            AppStrings.aboutVersionLine(version: "0.3.2", build: nil, in: .en)
                == "Version 0.3.2 · MIT License"
        )
        #expect(AppStrings.aboutVersionLine(version: nil, build: "42", in: .zhHans) == "MIT 许可证")
        #expect(AppStrings.aboutVersionLine(version: "   ", build: nil, in: .en) == "MIT License")

        #expect(AppStrings.checkForUpdatesButton(isBusy: false, in: .zhHans) == "检查更新")
        #expect(AppStrings.checkForUpdatesButton(isBusy: true, in: .zhHans) == "检查中…")
        #expect(AppStrings.checkForUpdatesButton(isBusy: false, in: .en) == "Check for Updates")
        #expect(AppStrings.checkForUpdatesButton(isBusy: true, in: .en) == "Checking…")

        #expect(
            AppStrings.aboutSummary(in: .zhHans)
                == "跨 AI 对话与网页顺手暂存灵感片段，保留提问脉络并一键接聊。"
        )
        #expect(
            AppStrings.aboutSummary(in: .en)
                == "Stash highlights across AI chats and the web with conversation context intact."
        )
        #expect(AppStrings.aboutGitHubRepoButton(in: .zhHans) == "GitHub 仓库 ↗")
        #expect(AppStrings.aboutGitHubRepoButton(in: .en) == "GitHub Repository ↗")
        #expect(AppStrings.aboutReleaseNotesButton(in: .zhHans) == "发布版本与更新日志 ↗")
        #expect(AppStrings.aboutReleaseNotesButton(in: .en) == "Releases & Changelog ↗")
        #expect(AppStrings.aboutGitHubRepoAccessibilityLabel(in: .zhHans) == "GitHub 仓库")
        #expect(AppStrings.aboutGitHubRepoAccessibilityLabel(in: .en) == "GitHub Repository")
        #expect(AppStrings.aboutReleaseNotesAccessibilityLabel(in: .zhHans) == "发布版本与更新日志")
        #expect(AppStrings.aboutReleaseNotesAccessibilityLabel(in: .en) == "Releases & Changelog")
    }

    private func makeTestRoot() -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-updater-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stagingDirectories(in updatesURL: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: updatesURL, includingPropertiesForKeys: nil)) ?? []
        return children.filter {
            $0.lastPathComponent.hasPrefix("staging-") || $0.lastPathComponent.hasPrefix("rollback-")
        }
    }

    private func makeReleaseJSON(version: String) -> Data {
        Data("""
        {
          "tag_name": "v\(version)",
          "html_url": "https://github.com/semantic-craft/coding-rewind/releases/tag/v\(version)",
          "body": "Release v\(version)",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "CodingRewind-v\(version)-macos-arm64.zip",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v\(version)/CodingRewind-v\(version)-macos-arm64.zip"
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v\(version)/SHA256SUMS.txt"
            }
          ]
        }
        """.utf8)
    }

    private func buildSignedDummyApp(
        at bundleURL: URL,
        version: String,
        bundleID: String,
        sidecarMarker: String = "sidecar-fixture",
        cliMarker: String = "cli-fixture"
    ) throws {
        let fm = FileManager.default
        let candidates = Bundle.allBundles.map {
            $0.bundleURL.deletingLastPathComponent().appendingPathComponent("ShortcutConflictFixture")
        } + [URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/ShortcutConflictFixture")]
        let machOFixture = try #require(candidates.first { fm.isExecutableFile(atPath: $0.path) })

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try fm.createDirectory(at: macosURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let appBinaryURL = macosURL.appendingPathComponent("CodingRewindApp", isDirectory: false)
        try fm.copyItem(at: machOFixture, to: appBinaryURL)
        _ = chmod(appBinaryURL.path, 0o755)

        let sidecarURL = helpersURL.appendingPathComponent("coding-rewind-sidecar", isDirectory: false)
        try AtomicFile.writeUTF8("#!/bin/sh\n# \(sidecarMarker)\nexit 0\n", to: sidecarURL, permissions: 0o755)
        let cliURL = helpersURL.appendingPathComponent("coding-rewind", isDirectory: false)
        try AtomicFile.writeUTF8("#!/bin/sh\n# \(cliMarker)\nexit 0\n", to: cliURL, permissions: 0o755)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "CodingRewind",
            "CFBundleExecutable": "CodingRewindApp",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        try runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", sidecarURL.path])
        try runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", cliURL.path])
        try runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", bundleURL.path])
        AppUpdater.unregisterBundleFromLaunchServices(bundleURL)
    }

    private func zipAppBundle(at appURL: URL, to zipURL: URL) throws {
        try FileManager.default.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runChecked("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", appURL.path, zipURL.path])
    }

    private func runChecked(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RewindError.ioError("\(executable) exited \(process.terminationStatus): \(errText)")
        }
    }
    }
}

private struct MockReleaseTransport: ReleaseTransport {
    let releaseJSON: Data
    let checksumsText: String
    let archiveSourceURL: URL?

    func fetchLatestReleaseJSON() async throws -> Data {
        releaseJSON
    }

    func fetchText(from url: URL) async throws -> String {
        checksumsText
    }

    func downloadArchive(from url: URL, to destinationURL: URL) async throws {
        guard let archiveSourceURL else {
            throw RewindError.httpError(statusCode: 404, body: "missing archive")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: archiveSourceURL, to: destinationURL)
    }
}

private struct StubSignatureInspector: CodeSignatureInspecting {
    let installed: InspectedCodeSignature
    let staged: InspectedCodeSignature

    func inspect(bundleURL: URL) throws -> InspectedCodeSignature {
        if bundleURL.path.contains("/staging-") || bundleURL.path.contains("/.CodingRewind-swap-") {
            return staged
        }
        return installed
    }
}

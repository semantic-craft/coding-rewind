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
        #expect(zhAppSubmenu.items.contains { $0.title == "检查更新…" })
        #expect(NSApplication.shared.mainMenu?.items.contains { $0.title == "操作" } == true)
        statusController.menuNeedsUpdate(statusController.menu)
        #expect(statusController.menu.items.contains { $0.title == "检查更新…" })
        #expect(statusController.menu.items.contains { $0.title == "显示片段浮窗" })
        #expect(popup.phase.labelText(in: popup.language) == "暂存")
        #expect(KeyboardShortcuts.localizationLanguageCode == "zh-Hans")

        appearance.setLanguagePreference(.en)

        let enAppSubmenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
        #expect(enAppSubmenu.items.contains { $0.title == "Check for Updates…" })
        #expect(NSApplication.shared.mainMenu?.items.contains { $0.title == "Actions" } == true)
        statusController.menuNeedsUpdate(statusController.menu)
        #expect(statusController.menu.items.contains { $0.title == "Check for Updates…" })
        #expect(statusController.menu.items.contains { $0.title == "Show Clips HUD" })
        #expect(statusController.statusItem.button?.toolTip == AppStrings.statusItemTooltip(in: .en))
        #expect(popup.phase.labelText(in: popup.language) == "Stash")
        #expect(popup.isVisible)
        #expect(KeyboardShortcuts.localizationLanguageCode == "en")
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
        #expect(qaIsolated.state == .disabled)
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
            sidecarMarker: "sidecar-v0.3.2"
        )
        try buildSignedDummyApp(
            at: newBuildURL,
            version: "0.3.3",
            bundleID: AppBundleID.selfQAApp,
            sidecarMarker: "sidecar-v0.3.3"
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
        try AtomicFile.writeUTF8("#!/bin/sh\n# sidecar-v0.3.2\nexit 0\n", to: installedSidecarURL, permissions: 0o755)

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

        let recordedArgs = try String(contentsOf: relaunchArgsFile, encoding: .utf8)
        #expect(recordedArgs == "\(installedURL.path)\n--args\n--restarted-after-update\n")
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        let staleRollback = paths.updatesDirectoryURL.appendingPathComponent("rollback-CodingRewind.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRollback, withIntermediateDirectories: true)
        updater.pruneStaleStagingDirectories()
        #expect(!FileManager.default.fileExists(atPath: staleRollback.path))
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
        sidecarMarker: String = "sidecar-fixture"
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
        if bundleURL.path.contains("/staging-") {
            return staged
        }
        return installed
    }
}

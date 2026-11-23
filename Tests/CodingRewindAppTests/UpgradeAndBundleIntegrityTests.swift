// SPDX-License-Identifier: MIT

import CodingRewindCore
@testable import CodingRewindApp
import Darwin
import Foundation
import Testing

extension AppShortcutsTests {
    @Suite(.serialized)
    @MainActor
    struct UpgradeAndBundleIntegrityTests {
    nonisolated private static let suiteName = "dev.codingrewind.qa.upgrade-integrity"

    private func makeTestRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data/test-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func cleanSuite() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        _ = CFPreferencesAppSynchronize(suiteName as CFString)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }

    @Test func updaterRejectsCandidateWithMismatchedOrInvalidBundleShortVersion() async throws {
        let root = try makeTestRoot()
        let installedURL = root.appendingPathComponent("Installed/CodingRewind.app", isDirectory: true)
        let mismatchedBuildURL = root.appendingPathComponent("Mismatched/CodingRewind.app", isDirectory: true)
        let malformedBuildURL = root.appendingPathComponent("Malformed/CodingRewind.app", isDirectory: true)
        Self.cleanSuite()
        defer {
            for url in [installedURL, mismatchedBuildURL, malformedBuildURL] {
                AppUpdater.unregisterBundleFromLaunchServices(url)
            }
            try? FileManager.default.removeItem(at: root)
            Self.cleanSuite()
        }

        try buildSignedApp(at: installedURL, shortVersion: "0.3.2", bundleID: AppBundleID.selfQAApp)
        try buildSignedApp(at: mismatchedBuildURL, shortVersion: "0.3.2", bundleID: AppBundleID.selfQAApp)
        let mismatchZip = root.appendingPathComponent("Artifacts/CodingRewind-v0.4.0-macos-arm64.zip")
        try zipAppBundle(at: mismatchedBuildURL, to: mismatchZip)
        let mismatchDigest = try SHA256Digest.compute(fileAt: mismatchZip)

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))

        let mismatchUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.4.0"),
                checksumsText: "\(mismatchDigest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\n",
                archiveSourceURL: mismatchZip
            )
        )
        await mismatchUpdater.checkForUpdates(userInitiated: true)
        #expect(mismatchUpdater.state == .failed("Code signature verification failed; update was rejected."))
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        try buildSignedApp(at: malformedBuildURL, shortVersion: "not-a-semver", bundleID: AppBundleID.selfQAApp)
        let malformedZip = root.appendingPathComponent("Artifacts-Malformed/CodingRewind-v0.4.0-macos-arm64.zip")
        try zipAppBundle(at: malformedBuildURL, to: malformedZip)
        let malformedDigest = try SHA256Digest.compute(fileAt: malformedZip)

        let malformedUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.4.0"),
                checksumsText: "\(malformedDigest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\n",
                archiveSourceURL: malformedZip
            )
        )
        await malformedUpdater.checkForUpdates(userInitiated: true)
        #expect(malformedUpdater.state == .failed("Code signature verification failed; update was rejected."))
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)
    }

    @Test func updaterRequiresBothHelpersToExistAsRegularExecutableFiles() async throws {
        let root = try makeTestRoot()
        let installedURL = root.appendingPathComponent("Installed/CodingRewind.app", isDirectory: true)
        let missingCLIURL = root.appendingPathComponent("MissingCLI/CodingRewind.app", isDirectory: true)
        let missingSidecarURL = root.appendingPathComponent("MissingSidecar/CodingRewind.app", isDirectory: true)
        let validCandidateURL = root.appendingPathComponent("ValidCandidate/CodingRewind.app", isDirectory: true)
        Self.cleanSuite()
        defer {
            for url in [installedURL, missingCLIURL, missingSidecarURL, validCandidateURL] {
                AppUpdater.unregisterBundleFromLaunchServices(url)
            }
            try? FileManager.default.removeItem(at: root)
            Self.cleanSuite()
        }

        try buildSignedApp(at: installedURL, shortVersion: "0.3.2", bundleID: AppBundleID.selfQAApp)
        try buildSignedApp(
            at: missingCLIURL,
            shortVersion: "0.4.0",
            bundleID: AppBundleID.selfQAApp,
            includeSidecar: true,
            includeCLI: false
        )
        try buildSignedApp(
            at: missingSidecarURL,
            shortVersion: "0.4.0",
            bundleID: AppBundleID.selfQAApp,
            includeSidecar: false,
            includeCLI: true
        )

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))

        for (label, brokenBundleURL) in [("missing-cli", missingCLIURL), ("missing-sidecar", missingSidecarURL)] {
            let zipURL = root.appendingPathComponent("Artifacts-\(label)/CodingRewind-v0.4.0-macos-arm64.zip")
            try zipAppBundle(at: brokenBundleURL, to: zipURL)
            let digest = try SHA256Digest.compute(fileAt: zipURL)
            let updater = AppUpdater(
                paths: paths,
                environment: [StoragePaths.qaEnvironmentKey: "1"],
                defaults: defaults,
                currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
                installedBundleURL: installedURL,
                installedBundleIdentifier: AppBundleID.selfQAApp,
                language: .en,
                transport: StaticReleaseTransport(
                    releaseJSON: makeReleaseJSON(version: "0.4.0"),
                    checksumsText: "\(digest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\n",
                    archiveSourceURL: zipURL
                )
            )
            await updater.checkForUpdates(userInitiated: true)
            #expect(updater.state == .failed("Code signature verification failed; update was rejected."))
            #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)
        }

        try buildSignedApp(at: validCandidateURL, shortVersion: "0.4.0", bundleID: AppBundleID.selfQAApp)
        let validZip = root.appendingPathComponent("Artifacts-valid/CodingRewind-v0.4.0-macos-arm64.zip")
        try zipAppBundle(at: validCandidateURL, to: validZip)
        let validDigest = try SHA256Digest.compute(fileAt: validZip)
        let postStageUpdater = AppUpdater(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 3, patch: 2),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfQAApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.4.0"),
                checksumsText: "\(validDigest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\n",
                archiveSourceURL: validZip
            ),
            signatureInspector: AlwaysValidSignatureInspector(bundleIdentifier: AppBundleID.selfQAApp)
        )
        await postStageUpdater.checkForUpdates(userInitiated: true)
        guard case .readyToInstall(let staged) = postStageUpdater.state else {
            Issue.record("Expected readyToInstall, got \(postStageUpdater.state)")
            return
        }
        let cliHelper = staged.stagedAppURL.appendingPathComponent("Contents/Helpers/coding-rewind")
        _ = chmod(cliHelper.path, 0o644)
        let installed = await postStageUpdater.installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: true)
        #expect(!installed)
        #expect(postStageUpdater.state == .failed("Code signature verification failed; update was rejected."))
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)
    }

    @Test func appLaunchRefreshesHelpersAndMigratesV032PluginManifestAndSkillToV040() throws {
        let root = try makeTestRoot()
        let v040BundleURL = root.appendingPathComponent("Bundle/CodingRewind.app", isDirectory: true)
        defer {
            AppUpdater.unregisterBundleFromLaunchServices(v040BundleURL)
            try? FileManager.default.removeItem(at: root)
        }

        try buildSignedApp(
            at: v040BundleURL,
            shortVersion: "0.4.0",
            bundleID: AppBundleID.selfQAApp,
            sidecarMarker: "sidecar-v0.4.0",
            cliMarker: "cli-v0.4.0"
        )

        let freshPaths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("FreshData", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("FreshConfig", isDirectory: true)
        )
        CodingRewindAppDelegate.stageBundledCLIBinaryIfAvailable(paths: freshPaths, bundleURL: v040BundleURL)
        #expect(FileManager.default.isExecutableFile(atPath: AntigravityIntegration.stableCLIBinaryURL(in: freshPaths.dataDirectoryURL).path))
        #expect(!FileManager.default.fileExists(atPath: AntigravityIntegration.stableSidecarBinaryURL(in: freshPaths.dataDirectoryURL).path))
        try AntigravityPluginInstaller(paths: freshPaths).refreshLocalizedMetadataIfInstalled(language: .en)
        #expect(!FileManager.default.fileExists(atPath: freshPaths.antigravityConfigDirectoryURL.appendingPathComponent("plugins/coding-rewind").path))

        let upgradePaths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("UpgradeData", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("UpgradeConfig", isDirectory: true)
        )
        let oldSidecarSrc = root.appendingPathComponent("old-sidecar")
        let oldCLISrc = root.appendingPathComponent("old-cli")
        try AtomicFile.writeUTF8("#!/bin/sh\n# sidecar-v0.3.2\nexit 0\n", to: oldSidecarSrc, permissions: 0o755)
        try AtomicFile.writeUTF8("#!/bin/sh\n# cli-v0.3.2\nexit 0\n", to: oldCLISrc, permissions: 0o755)

        let pluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: upgradePaths.dataDirectoryURL,
            configDirectoryURL: upgradePaths.antigravityConfigDirectoryURL,
            sourceCLIBinaryURL: oldCLISrc,
            sourceSidecarBinaryURL: oldSidecarSrc,
            language: .zhHans
        )
        try FileManager.default.removeItem(at: AntigravityIntegration.stableCLIBinaryURL(in: upgradePaths.dataDirectoryURL))

        let legacyManifest: [String: Any] = [
            "name": "coding-rewind",
            "version": "0.2.0",
            "description": "Legacy v0.3.2 manifest",
            "suggestedPrompts": []
        ]
        try AtomicFile.writeData(
            JSONSerialization.data(withJSONObject: legacyManifest, options: [.prettyPrinted, .sortedKeys]),
            to: pluginDir.appendingPathComponent("plugin.json"),
            permissions: 0o644
        )
        try AtomicFile.writeUTF8(
            "# Legacy Skill\nUse memo_list_memos to read Memos.\n",
            to: pluginDir.appendingPathComponent("skills/rewind/SKILL.md"),
            permissions: 0o644
        )

        let installer = AntigravityPluginInstaller(paths: upgradePaths)
        if case .needsInstallOrRepair(let preReasons) = installer.inspectStatus() {
            #expect(Set(preReasons) == [
                .manifestVersionMismatch,
                .invalidSuggestedPrompts,
                .skillMissingMemosGuidance,
                .missingCLIBinary
            ])
        } else {
            Issue.record("Expected v0.3.2 fixture to require repair before launch staging")
        }

        CodingRewindAppDelegate.stageBundledCLIBinaryIfAvailable(paths: upgradePaths, bundleURL: v040BundleURL)
        try installer.refreshLocalizedMetadataIfInstalled(language: .en)

        #expect(installer.inspectStatus() == .installed)
        let stagedSidecarText = try String(
            contentsOf: AntigravityIntegration.stableSidecarBinaryURL(in: upgradePaths.dataDirectoryURL),
            encoding: .utf8
        )
        let stagedCLIText = try String(
            contentsOf: AntigravityIntegration.stableCLIBinaryURL(in: upgradePaths.dataDirectoryURL),
            encoding: .utf8
        )
        #expect(stagedSidecarText.contains("sidecar-v0.4.0"))
        #expect(stagedCLIText.contains("cli-v0.4.0"))

        let migratedManifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))) as? [String: Any]
        )
        #expect(migratedManifest["version"] as? String == "0.8.0")
        let migratedPrompts = try #require(migratedManifest["suggestedPrompts"] as? [String])
        #expect(migratedPrompts == AntigravityIntegration.suggestedPrompts(in: .en))

        let migratedSkill = try String(contentsOf: pluginDir.appendingPathComponent("skills/rewind/SKILL.md"), encoding: .utf8)
        #expect(migratedSkill.contains("list_snippets"))
        #expect(migratedSkill.contains("get_snippet"))
        #expect(migratedSkill.contains("archive_snippet"))
        #expect(!migratedSkill.contains("memo_list_memos"))
    }

    @Test func productionUpdaterBlocksAdhocReplacementAndRequiresNotarizedGatekeeperAssessmentForDeveloperID() async throws {
        let root = try makeTestRoot()
        let installedURL = root.appendingPathComponent("InstalledProd/CodingRewind.app", isDirectory: true)
        let candidateBuildURL = root.appendingPathComponent("CandidateProd/CodingRewind.app", isDirectory: true)
        Self.cleanSuite()
        defer {
            for url in [installedURL, candidateBuildURL] {
                AppUpdater.unregisterBundleFromLaunchServices(url)
            }
            try? FileManager.default.removeItem(at: root)
            Self.cleanSuite()
        }

        try buildSignedApp(at: installedURL, shortVersion: "0.5.0", bundleID: AppBundleID.selfApp)
        try buildSignedApp(at: candidateBuildURL, shortVersion: "0.6.0", bundleID: AppBundleID.selfApp)
        let zipURL = root.appendingPathComponent("Artifacts-prod/CodingRewind-v0.6.0-macos-arm64.zip")
        try zipAppBundle(at: candidateBuildURL, to: zipURL)
        let digest = try SHA256Digest.compute(fileAt: zipURL)
        let checksums = "\(digest.hexValue)  CodingRewind-v0.6.0-macos-arm64.zip\n"

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("ProdData", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("ProdConfig", isDirectory: true)
        )
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))

        let adhocProdUpdater = AppUpdater(
            paths: paths,
            environment: [:],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 5, patch: 0),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.6.0"),
                checksumsText: checksums,
                archiveSourceURL: zipURL
            ),
            signatureInspector: SecStaticCodeSignatureInspector()
        )
        await adhocProdUpdater.checkForUpdates(userInitiated: true)
        if case .manualDownloadRequired(_, let reason) = adhocProdUpdater.state {
            #expect(reason == .signatureDowngradeBlocked)
        } else {
            Issue.record("Expected production .adhoc candidate to be blocked with .signatureDowngradeBlocked, got \(adhocProdUpdater.state)")
        }
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        let team = BundleSignatureAuthority.defaultReleaseTeamID
        let devIDInspector = FixedAuthoritySignatureInspector(
            authority: .developerID(teamID: team),
            bundleIdentifier: AppBundleID.selfApp
        )
        let unnotarizedUpdater = AppUpdater(
            paths: paths,
            environment: [:],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 5, patch: 0),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.6.0"),
                checksumsText: checksums,
                archiveSourceURL: zipURL
            ),
            signatureInspector: devIDInspector,
            candidateGatekeeperAssessor: { _ in false }
        )
        await unnotarizedUpdater.checkForUpdates(userInitiated: true)
        #expect(unnotarizedUpdater.state == .failed("Code signature verification failed; update was rejected."))
        #expect(stagingDirectories(in: paths.updatesDirectoryURL).isEmpty)

        let notarizedUpdater = AppUpdater(
            paths: paths,
            environment: [:],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 5, patch: 0),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.6.0"),
                checksumsText: checksums,
                archiveSourceURL: zipURL
            ),
            signatureInspector: devIDInspector,
            candidateGatekeeperAssessor: { _ in true }
        )
        await notarizedUpdater.checkForUpdates(userInitiated: true)
        if case .readyToInstall(let staged) = notarizedUpdater.state {
            #expect(staged.candidate.version == SemanticVersion(major: 0, minor: 6, patch: 0))
            AppUpdater.unregisterBundleFromLaunchServices(staged.stagedAppURL)
            try? FileManager.default.removeItem(at: staged.stagingDirectoryURL)
        } else {
            Issue.record("Expected notarized .developerID candidate to stage cleanly, got \(notarizedUpdater.state)")
        }

        let symlinkDataRoot = root.appendingPathComponent("SymlinkUpdatesData", isDirectory: true)
        let symlinkPaths = try StoragePaths(
            dataDirectoryURL: symlinkDataRoot,
            antigravityConfigDirectoryURL: root.appendingPathComponent("SymlinkConfig", isDirectory: true)
        )
        let outsideTarget = root.appendingPathComponent("OutsideRedirectDir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkPaths.updatesDirectoryURL, withDestinationURL: outsideTarget)
        let symlinkUpdater = AppUpdater(
            paths: symlinkPaths,
            environment: [:],
            defaults: defaults,
            currentVersion: SemanticVersion(major: 0, minor: 5, patch: 0),
            installedBundleURL: installedURL,
            installedBundleIdentifier: AppBundleID.selfApp,
            language: .en,
            transport: StaticReleaseTransport(
                releaseJSON: makeReleaseJSON(version: "0.6.0"),
                checksumsText: checksums,
                archiveSourceURL: zipURL
            ),
            signatureInspector: devIDInspector,
            candidateGatekeeperAssessor: { _ in true }
        )
        await symlinkUpdater.checkForUpdates(userInitiated: true)
        if case .failed = symlinkUpdater.state {
            let leaked = (try? FileManager.default.contentsOfDirectory(atPath: outsideTarget.path)) ?? []
            #expect(leaked.isEmpty)
        } else {
            Issue.record("Expected symlinked updates directory to be rejected, got \(symlinkUpdater.state)")
        }

        let spoofDir = root.appendingPathComponent("source=Notarized Developer ID", isDirectory: true)
        let spoofAppURL = spoofDir.appendingPathComponent("CodingRewind.app", isDirectory: true)
        defer { AppUpdater.unregisterBundleFromLaunchServices(spoofAppURL) }
        try buildSignedApp(at: spoofAppURL, shortVersion: "0.6.0", bundleID: AppBundleID.selfApp)
        let spoofAccepted = await Task.detached(priority: .userInitiated) {
            AppUpdater.defaultAssessNotarizedDeveloperID(spoofAppURL)
        }.value
        #expect(!spoofAccepted, "spctl assessor must reject ad-hoc bundle regardless of path string")

        let pluginDataDir = root.appendingPathComponent("PluginMigData", isDirectory: true)
        let pluginConfigDir = root.appendingPathComponent("PluginMigConfig", isDirectory: true)
        let migPaths = try StoragePaths(dataDirectoryURL: pluginDataDir, antigravityConfigDirectoryURL: pluginConfigDir)
        let dummyBin = root.appendingPathComponent("dummy-helper")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: dummyBin, permissions: 0o755)
        let installedPluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: pluginDataDir,
            configDirectoryURL: pluginConfigDir,
            sourceCLIBinaryURL: dummyBin,
            sourceSidecarBinaryURL: dummyBin,
            language: .en
        )
        let skillURL = installedPluginDir.appendingPathComponent("skills/rewind/SKILL.md")
        let legacySkill = try String(contentsOf: skillURL, encoding: .utf8)
            .replacingOccurrences(of: " and CLI write/delete subcommands (`create`, `update`, `note`, `archive`, `delete`)", with: "")
        try AtomicFile.writeUTF8(legacySkill, to: skillURL, permissions: 0o644)
        let migInstaller = AntigravityPluginInstaller(paths: migPaths)
        #expect(migInstaller.inspectStatus() == .needsInstallOrRepair([.skillMissingMemosGuidance]))
        try migInstaller.refreshLocalizedMetadataIfInstalled(language: .en)
        #expect(migInstaller.inspectStatus() == .installed)
        #expect(try String(contentsOf: skillURL, encoding: .utf8).contains("CLI write/delete subcommands"))
    }

    private func stagingDirectories(in updatesDir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.filter { $0.lastPathComponent.hasPrefix("staging-") }
    }

    private func makeReleaseJSON(version: String) -> Data {
        Data("""
        {
          "tag_name": "v\(version)",
          "html_url": "https://github.com/semantic-craft/coding-rewind/releases/tag/v\(version)",
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

    private func buildSignedApp(
        at bundleURL: URL,
        shortVersion: String,
        bundleID: String,
        includeSidecar: Bool = true,
        includeCLI: Bool = true,
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

        if includeSidecar {
            let sidecarURL = helpersURL.appendingPathComponent("coding-rewind-sidecar", isDirectory: false)
            try AtomicFile.writeUTF8("#!/bin/sh\n# \(sidecarMarker)\nexit 0\n", to: sidecarURL, permissions: 0o755)
            try runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", sidecarURL.path])
        }
        if includeCLI {
            let cliURL = helpersURL.appendingPathComponent("coding-rewind", isDirectory: false)
            try AtomicFile.writeUTF8("#!/bin/sh\n# \(cliMarker)\nexit 0\n", to: cliURL, permissions: 0o755)
            try runChecked("/usr/bin/codesign", arguments: ["--force", "--sign", "-", cliURL.path])
        }

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "CodingRewind",
            "CFBundleExecutable": "CodingRewindApp",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": "7"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

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
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpgradeAndBundleIntegrityTests", code: Int(process.terminationStatus))
        }
    }
    }
}

private struct StaticReleaseTransport: ReleaseTransport {
    let releaseJSON: Data
    let checksumsText: String
    let archiveSourceURL: URL?

    func fetchLatestReleaseJSON() async throws -> Data { releaseJSON }
    func fetchText(from url: URL) async throws -> String { checksumsText }
    func downloadArchive(from url: URL, to destinationURL: URL) async throws {
        guard let src = archiveSourceURL else {
            throw ReleaseTransportError.httpStatus(404, "missing archive")
        }
        try FileManager.default.copyItem(at: src, to: destinationURL)
    }
}

private struct AlwaysValidSignatureInspector: CodeSignatureInspecting {
    let bundleIdentifier: String

    func inspect(bundleURL: URL) throws -> InspectedCodeSignature {
        InspectedCodeSignature(authority: .adhoc, bundleIdentifier: bundleIdentifier)
    }
}

private struct FixedAuthoritySignatureInspector: CodeSignatureInspecting {
    let authority: BundleSignatureAuthority
    let bundleIdentifier: String

    func inspect(bundleURL: URL) throws -> InspectedCodeSignature {
        InspectedCodeSignature(authority: authority, bundleIdentifier: bundleIdentifier)
    }
}

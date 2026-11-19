// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import Testing

private struct StubSelectionCapturer: SelectionCapturing {
    let result: Result<CapturedSelection, RewindError>

    func captureFrontmostSelection() async throws -> CapturedSelection {
        try result.get()
    }
}

private actor PromptRecorder {
    private(set) var prompt: String = ""

    func record(_ value: String) {
        prompt = value
    }
}

@Suite("Localization catalog, coordinator language switching & update models")
struct LocalizationAndUpdateModelsTests {
    @Test func appLanguagePreferenceResolvesSystemAndExplicitChoices() {
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans)
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["zh-Hant-HK", "en-US"]) == .zhHans)
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["en-US", "zh-Hans-CN"]) == .en)
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["ja-JP", "fr-FR"]) == .en)
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: []) == .zhHans)
        #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["   "]) == .zhHans)
        #expect(AppLanguagePreference.zhHans.resolved(preferredLanguages: ["en-US"]) == .zhHans)
        #expect(AppLanguagePreference.en.resolved(preferredLanguages: ["zh-Hans-CN"]) == .en)
    }

    @Test func bilingualCatalogMaintainsNonEmptyDistinctParity() throws {
        for filter in StatusFilter.allCases {
            let zh = filter.label(in: .zhHans)
            let en = filter.label(in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
            #expect(filter.label == zh)
        }

        for status in [CardStatus.pending, .ready] {
            let zh = status.badgeText(in: .zhHans)
            let en = status.badgeText(in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
            #expect(status.badgeText == zh)
        }

        let sampleErrors: [RewindError] = [
            .emptySelection,
            .accessibilityPermissionDenied,
            .noFrontmostApplication,
            .invalidClipID("bad id"),
            .snippetNotFound("rw-missing"),
            .invalidMemosURL("ftp://invalid"),
            .missingCredentials,
            .httpError(statusCode: 502, body: "Bad Gateway"),
            .ioError("disk full"),
            .keychainError(-25300)
        ]
        for err in sampleErrors {
            let zh = err.localizedDescription(in: .zhHans)
            let en = err.localizedDescription(in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
        }

        let allRepairReasons: [PluginRepairReason] = [
            .notInstalled,
            .unsupportedManifestKeys,
            .manifestNameMismatch,
            .manifestVersionMismatch,
            .invalidSuggestedPrompts,
            .missingOrInvalidManifest,
            .legacyCaptureHooksPresent,
            .skillMissingMemosGuidance,
            .missingSkillFile,
            .missingCLIBinary,
            .missingSidecarBinary,
            .invalidSidecarConfig,
            .sidecarLauncherDisabled
        ]
        for reason in allRepairReasons {
            let zh = L10n.pluginRepairReason(reason, in: .zhHans)
            let en = L10n.pluginRepairReason(reason, in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
        }

        let allDSHRepairReasons: [DSHPluginRepairReason] = [
            .notInstalled,
            .missingBundledPlugin,
            .missingCLIBinary,
            .missingProfilePackage,
            .pluginNotRegisteredInProfile,
            .stagedPluginMissingOrOutdated,
            .invalidRuntimeConfig
        ]
        for reason in allDSHRepairReasons {
            let zh = L10n.dshPluginRepairReason(reason, in: .zhHans)
            let en = L10n.dshPluginRepairReason(reason, in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
        }

        let notices: [BannerNotice] = [
            .savedOfflineNeedsConfig,
            .savedClip(sourceTitle: "Antigravity"),
            .savedOfflineTemporaryFailure,
            .syncFailedShowingLocal,
            .selectAtLeastOneCard,
            .needsAntigravityPlugin,
            .needsDSHPlugin,
            .waitingForHostConfirmation(.antigravity),
            .waitingForHostConfirmation(.dsh),
            .sentArchiveBlockedUnconfigured,
            .sentPartialArchiveFailure,
            .sentToNewConversation(count: 2, host: .dsh),
            .sentOpenConversationFailed(.dsh),
            .requestExpired(.antigravity),
            .requestExpired(.dsh),
            .hostRejected(.dsh),
            .deliveryUnconfirmed(.antigravity),
            .deliveryUnconfirmed(.dsh),
            .stillWaitingForReceipt,
            .clearedUnconfirmedRequest,
            .retainedUnarchivedCards,
            .reopenConversationFailed,
            .openedConversation(.dsh),
            .openedDSHConversation,
            .copiedDSHSessionFallback("sess-123"),
            .resumeUnarchivedStartup,
            .resumePendingStartup,
            .archiveCardBlockedOfflineOrUnconfigured,
            .archivedClips(count: 1),
            .archivedClips(count: 3),
            .partialArchiveClipsFailure(succeeded: 1, failed: 2),
            .deletedClips(count: 1),
            .deletedClips(count: 2),
            .partialDeleteClipsFailure(succeeded: 1, failed: 1),
            .deleteCardBlockedOfflineOrUnconfigured,
            .cardsLockedByActiveConversation,
            .savedConnectionSettings,
            .pluginInstalled,
            .pluginNeedsRepair(.missingSidecarBinary),
            .pluginInstallFailedRewind(.missingCredentials),
            .pluginInstallFailedMessage("permission denied"),
            .dshPluginInstalled,
            .dshPluginNeedsRepair(.missingCLIBinary),
            .dshPluginInstallFailedRewind(.missingCredentials),
            .dshPluginInstallFailedMessage("pnpm failed"),
            .openURLFailed("https://example.com"),
            .copiedSessionID("6eb720d3-188b-4783-a0c6-9592c554f3fc"),
            .copiedClipText,
            .rewindError(.emptySelection)
        ]
        for notice in notices {
            let zh = L10n.banner(notice, in: .zhHans)
            let en = L10n.banner(notice, in: .en)
            #expect(!zh.isEmpty)
            #expect(!en.isEmpty)
            #expect(zh != en)
        }

        #expect(L10n.banner(.archivedClips(count: 1), in: .zhHans) == "已归档 1 条片段，原文仍保留在 Memos 中")
        #expect(L10n.banner(.archivedClips(count: 1), in: .en).contains("1 clip"))
        #expect(!L10n.banner(.archivedClips(count: 1), in: .en).contains("1 clips"))
        #expect(L10n.banner(.archivedClips(count: 3), in: .en).contains("3 clips"))
        #expect(L10n.banner(.deletedClips(count: 1), in: .zhHans).contains("1 条片段"))
        #expect(L10n.banner(.deletedClips(count: 1), in: .en).contains("1 clip"))
        #expect(!L10n.banner(.deletedClips(count: 1), in: .en).contains("1 clips"))
        #expect(L10n.banner(.deletedClips(count: 2), in: .en).contains("2 clips"))
        #expect(L10n.banner(.partialArchiveClipsFailure(succeeded: 1, failed: 2), in: .en).contains("1 clip"))
        #expect(L10n.banner(.partialArchiveClipsFailure(succeeded: 1, failed: 2), in: .en).contains("2 clips"))
        #expect(L10n.banner(.partialDeleteClipsFailure(succeeded: 2, failed: 1), in: .en).contains("2 clips"))
        #expect(L10n.banner(.partialDeleteClipsFailure(succeeded: 2, failed: 1), in: .en).contains("1 clip"))

        let zhPrompts = L10n.suggestedPrompts(in: .zhHans)
        let enPrompts = L10n.suggestedPrompts(in: .en)
        #expect(zhPrompts.count == 3)
        #expect(enPrompts.count == 3)
        #expect(zhPrompts != enPrompts)
        #expect(zhPrompts.allSatisfy { $0.hasPrefix("/rewind ") })
        #expect(enPrompts.allSatisfy { $0.hasPrefix("/rewind ") })

        let card = RewindCard(
            id: "rw-100",
            rawContent: "#rewind/ready #source/antigravity\n\nVerbatim evidence line",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "Concurrency Contract",
            sessionTopic: "Updater Design",
            contextSummary: "Discussed signature checks",
            keywords: ["codesign", "sha256"],
            sourceTitle: "Antigravity",
            sourceURL: "conversation://abc-123",
            verbatimText: "Verbatim evidence line",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let zhHandoff = ConversationPrompt.buildPrompt(for: [card], language: .zhHans)
        let enHandoff = ConversationPrompt.buildPrompt(for: [card], language: .en)
        #expect(zhHandoff.contains("### 卡片 1：Concurrency Contract"))
        #expect(enHandoff.contains("### Clip 1: Concurrency Contract"))
        #expect(zhHandoff.contains("> Verbatim evidence line"))
        #expect(enHandoff.contains("> Verbatim evidence line"))
        #expect(zhHandoff.contains("conversation://abc-123"))
        #expect(enHandoff.contains("conversation://abc-123"))

        let baseURL = try #require(URL(string: "https://memos.local"))
        let zhSnapshot = MenuStatusSnapshot(
            isHUDVisible: true,
            hotCardCount: 1,
            checkedCardCount: 1,
            pendingOutboxCount: 2,
            connection: .configured(hostSummary: "memos.local", baseURL: baseURL),
            isPluginReady: true,
            pluginSummary: L10n.pluginInstalledSummary(in: .zhHans),
            isAccessibilityTrusted: true,
            recentCards: [],
            language: .zhHans
        )
        let enSnapshot = MenuStatusSnapshot(
            isHUDVisible: true,
            hotCardCount: 1,
            checkedCardCount: 1,
            pendingOutboxCount: 2,
            connection: .configured(hostSummary: "memos.local", baseURL: baseURL),
            isPluginReady: true,
            pluginSummary: L10n.pluginInstalledSummary(in: .en),
            isAccessibilityTrusted: true,
            recentCards: [],
            language: .en
        )
        #expect(zhSnapshot.headerTitle != enSnapshot.headerTitle)
        #expect(enSnapshot.headerTitle.contains("1 clip (2 pending sync)"))
        #expect(zhSnapshot.headerSubtitle == "Memos 已配置（memos.local）")
        #expect(enSnapshot.headerSubtitle == "Memos configured (memos.local)")
        #expect(!zhSnapshot.headerSubtitle.contains("已连接"))
        #expect(!enSnapshot.headerSubtitle.contains("Connected"))
        #expect(L10n.menuHeaderSubtitle(connection: .unconfigured, in: .zhHans) == "仅保存在本机（未配置 Memos）")
        #expect(L10n.menuHeaderSubtitle(connection: .unconfigured, in: .en) == "Local only (Memos not configured)")
        #expect(zhSnapshot.toggleHUDTitle == "隐藏片段浮窗")
        #expect(enSnapshot.toggleHUDTitle == "Hide Clips HUD")
        #expect(zhSnapshot.attentionIssues.isEmpty)
        #expect(zhSnapshot.attentionTitle == nil)
        #expect(enSnapshot.attentionIssues.isEmpty)
        #expect(enSnapshot.attentionTitle == nil)

        #expect(L10n.menuAttentionTitle(issues: [], in: .zhHans) == nil)
        #expect(L10n.menuAttentionTitle(issues: [], in: .en) == nil)
        #expect(L10n.menuAttentionTitle(issues: [.accessibilityPermission], in: .zhHans) == "需要处理：辅助功能权限未授权…")
        #expect(L10n.menuAttentionTitle(issues: [.accessibilityPermission], in: .en) == "Needs Attention: Accessibility Permission…")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.antigravity)], in: .zhHans) == "需要处理：Antigravity 插件待安装或修复…")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.antigravity)], in: .en) == "Needs Attention: Antigravity Plugin…")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.dsh)], in: .zhHans) == "需要处理：DSH 插件待安装或修复…")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.dsh)], in: .en) == "Needs Attention: DSH Plugin…")
        #expect(
            L10n.menuAttentionTitle(issues: [.accessibilityPermission, .activeHostPlugin(.antigravity)], in: .zhHans)
                == "需要处理：辅助功能权限与 Antigravity 插件…"
        )
        #expect(
            L10n.menuAttentionTitle(issues: [.accessibilityPermission, .activeHostPlugin(.antigravity)], in: .en)
                == "Needs Attention: Accessibility & Antigravity Plugin…"
        )
        #expect(
            L10n.menuAttentionTitle(issues: [.accessibilityPermission, .activeHostPlugin(.dsh)], in: .zhHans)
                == "需要处理：辅助功能权限与 DSH 插件…"
        )
        #expect(
            L10n.menuAttentionTitle(issues: [.accessibilityPermission, .activeHostPlugin(.dsh)], in: .en)
                == "Needs Attention: Accessibility & DSH Plugin…"
        )
    }

    @Test @MainActor func coordinatorLiveRelocalizesBannerPluginSnapshotAndHandoffPrompt() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/core-l10n-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let selection = CapturedSelection(
            text: "Exact captured body",
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            capturedAt: Date()
        )
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: StubSelectionCapturer(result: .success(selection)),
            dshReadinessCheck: { true }
        )
        #expect(coordinator.language == .zhHans)
        #expect(coordinator.pluginStatusText.contains("插件需要安装或修复"))

        let outcome = await coordinator.captureSelection()
        guard case .queuedOffline = outcome else {
            Issue.record("Expected offline queue outcome when Memos is unconfigured")
            return
        }
        #expect(coordinator.bannerMessage == L10n.banner(.savedOfflineNeedsConfig, in: .zhHans))

        coordinator.setLanguage(.en)
        #expect(coordinator.language == .en)
        #expect(coordinator.bannerMessage == L10n.banner(.savedOfflineNeedsConfig, in: .en))
        #expect(coordinator.pluginStatusText.contains("Plugin needs install or repair"))

        let snapshot = coordinator.menuStatusSnapshot(isHUDVisible: false, isAccessibilityTrusted: false)
        #expect(snapshot.language == .en)
        #expect(snapshot.toggleHUDTitle == "Show Clips HUD")
        #expect(snapshot.pluginSummary.contains("Plugin needs install or repair"))

        let recorder = PromptRecorder()
        let englishCoord = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: StubSelectionCapturer(result: .success(selection)),
            language: .en,
            dshReadinessCheck: { true }
        )
        englishCoord.onWakeHost = { host in
            guard host == .dsh else { return }
            let dshStore = englishCoord.handoffStore(for: .dsh)
            Task.detached {
                if let worker = try? ConversationSidecarWorker.acquireIfUnlocked(store: dshStore) {
                    try? await worker.processPending { request in
                        await recorder.record(request.prompt)
                        return (.succeeded, UUID().uuidString.lowercased())
                    }
                }
            }
        }
        englishCoord.checkedCardIDs = Set(englishCoord.cards.map(\.id))
        let launchResult = await englishCoord.launchChecked(in: .dsh, waitSeconds: 2)
        #expect(launchResult != nil)
        let capturedPrompt = await recorder.prompt
        #expect(capturedPrompt.contains("Analyze and synthesize the following highlights"))
        #expect(capturedPrompt.contains("### Clip 1:"))
        #expect(capturedPrompt.contains("> Exact captured body"))
    }

    @Test func semanticVersionParsesStrictTripletsAndOrdersCorrectly() {
        let v032 = SemanticVersion(parsing: "0.3.2")
        let vPrefixed = SemanticVersion(parsing: "v0.3.2")
        let upperPrefixed = SemanticVersion(parsing: "V1.2.0")
        #expect(v032 == SemanticVersion(major: 0, minor: 3, patch: 2))
        #expect(v032 == vPrefixed)
        #expect(upperPrefixed == SemanticVersion(major: 1, minor: 2, patch: 0))

        #expect(SemanticVersion(major: 0, minor: 3, patch: 2) < SemanticVersion(major: 0, minor: 3, patch: 10))
        #expect(SemanticVersion(major: 0, minor: 3, patch: 10) < SemanticVersion(major: 0, minor: 4, patch: 0))
        #expect(SemanticVersion(major: 0, minor: 9, patch: 9) < SemanticVersion(major: 1, minor: 0, patch: 0))

        for invalid in ["", "0.3", "0.3.2.1", "0.3.0-rc.3", "v0.3.2+build1", "0.a.1", "-1.0.0"] {
            #expect(SemanticVersion(parsing: invalid) == nil)
        }
    }

    @Test func sha256DigestComputesAndParsesChecksumsManifests() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/core-sha256-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let payload = Data("coding-rewind-release-payload".utf8)
        let fileURL = root.appendingPathComponent("payload.bin")
        try payload.write(to: fileURL)

        let memoryDigest = SHA256Digest.compute(for: payload)
        let fileDigest = try SHA256Digest.compute(fileAt: fileURL)
        #expect(memoryDigest == fileDigest)
        #expect(SHA256Digest(hexString: memoryDigest.hexValue.uppercased()) == memoryDigest)
        #expect(SHA256Digest(hexString: "abc") == nil)
        #expect(SHA256Digest(hexString: String(repeating: "z", count: 64)) == nil)

        let otherHex = String(repeating: "a1", count: 32)
        let singleSpaceHex = String(repeating: "c3", count: 32)
        let tabHex = String(repeating: "d4", count: 32)
        let multiSpaceHex = String(repeating: "e5", count: 32)
        let manifest = """
        \(memoryDigest.hexValue)  CodingRewind-v0.4.0-macos-arm64.zip\r
        \(otherHex) *./CodingRewind-WebClipper-v0.4.0.zip
        \(singleSpaceHex) SingleSpace.zip
        \(tabHex)\t*\tTabbedArchive.zip
        \(multiSpaceHex)     MultiSpaceArchive.zip
        """
        #expect(SHA256Digest.lookup(archiveName: "CodingRewind-v0.4.0-macos-arm64.zip", inChecksumsText: manifest) == memoryDigest)
        #expect(SHA256Digest.lookup(archiveName: "CodingRewind-WebClipper-v0.4.0.zip", inChecksumsText: manifest)?.hexValue == otherHex)
        #expect(SHA256Digest.lookup(archiveName: "SingleSpace.zip", inChecksumsText: manifest)?.hexValue == singleSpaceHex)
        #expect(SHA256Digest.lookup(archiveName: "TabbedArchive.zip", inChecksumsText: manifest)?.hexValue == tabHex)
        #expect(SHA256Digest.lookup(archiveName: "MultiSpaceArchive.zip", inChecksumsText: manifest)?.hexValue == multiSpaceHex)
        #expect(SHA256Digest.lookup(archiveName: "Missing.zip", inChecksumsText: manifest) == nil)
    }

    @Test func releaseCandidateSelectsMacOSZipIgnoresWebClipperAndRejectsUnsafeInputs() throws {
        let expectedHex = String(repeating: "b2", count: 32)
        let validJSON = Data("""
        {
          "tag_name": "v0.4.0",
          "html_url": "https://github.com/semantic-craft/coding-rewind/releases/tag/v0.4.0",
          "body": "### Highlights\\n- Signed updater",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "CodingRewind-WebClipper-v0.4.0.zip",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/CodingRewind-WebClipper-v0.4.0.zip"
            },
            {
              "name": "CodingRewind-v0.4.0-macos-arm64.zip",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/CodingRewind-v0.4.0-macos-arm64.zip"
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/SHA256SUMS.txt"
            }
          ]
        }
        """.utf8)
        let checksums = "\(expectedHex)  CodingRewind-v0.4.0-macos-arm64.zip\n"
        let parsed = try GitHubReleaseCandidate.parseLatestRelease(jsonData: validJSON, checksumsText: checksums)
        #expect(parsed.version == SemanticVersion(major: 0, minor: 4, patch: 0))
        #expect(parsed.macosArchiveName == "CodingRewind-v0.4.0-macos-arm64.zip")
        #expect(parsed.checksumsURL?.absoluteString.hasSuffix("/SHA256SUMS.txt") == true)
        #expect(parsed.expectedSHA256?.hexValue == expectedHex)

        let draftJSON = Data("""
        {"tag_name":"v0.4.0","html_url":"https://github.com/x/y/releases/tag/v0.4.0","draft":true,"prerelease":false,"assets":[]}
        """.utf8)
        #expect(throws: UpdateParseError.draftOrPrerelease) {
            try GitHubReleaseCandidate.parseLatestRelease(jsonData: draftJSON)
        }

        let prereleaseJSON = Data("""
        {"tag_name":"v0.4.0","html_url":"https://github.com/x/y/releases/tag/v0.4.0","draft":false,"prerelease":true,"assets":[]}
        """.utf8)
        #expect(throws: UpdateParseError.draftOrPrerelease) {
            try GitHubReleaseCandidate.parseLatestRelease(jsonData: prereleaseJSON)
        }

        let insecureAssetJSON = Data("""
        {
          "tag_name": "v0.4.0",
          "html_url": "https://github.com/semantic-craft/coding-rewind/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "CodingRewind-v0.4.0-macos-arm64.zip",
              "browser_download_url": "http://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/CodingRewind-v0.4.0-macos-arm64.zip"
            }
          ]
        }
        """.utf8)
        #expect(throws: UpdateParseError.invalidReleaseURL("http://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/CodingRewind-v0.4.0-macos-arm64.zip")) {
            try GitHubReleaseCandidate.parseLatestRelease(jsonData: insecureAssetJSON)
        }

        let clipperOnlyJSON = Data("""
        {
          "tag_name": "v0.4.0",
          "html_url": "https://github.com/semantic-craft/coding-rewind/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "CodingRewind-WebClipper-v0.4.0.zip",
              "browser_download_url": "https://github.com/semantic-craft/coding-rewind/releases/download/v0.4.0/CodingRewind-WebClipper-v0.4.0.zip"
            }
          ]
        }
        """.utf8)
        #expect(throws: UpdateParseError.missingMacOSArchiveAsset) {
            try GitHubReleaseCandidate.parseLatestRelease(jsonData: clipperOnlyJSON)
        }
    }

    @Test func bundleSignatureAuthorityBlocksDowngradesAndTeamMismatches() {
        let team = BundleSignatureAuthority.defaultReleaseTeamID
        let devID = BundleSignatureAuthority.developerID(teamID: team)
        let otherDevID = BundleSignatureAuthority.developerID(teamID: "OTHER99999")
        let appleDev = BundleSignatureAuthority.appleDevelopment(teamID: team)
        let otherAppleDev = BundleSignatureAuthority.appleDevelopment(teamID: "OTHER99999")

        #expect(BundleSignatureAuthority.canReplace(installed: devID, with: devID))
        #expect(!BundleSignatureAuthority.canReplace(installed: devID, with: .adhoc))
        #expect(!BundleSignatureAuthority.canReplace(installed: devID, with: .unsigned))
        #expect(!BundleSignatureAuthority.canReplace(installed: devID, with: appleDev))
        #expect(!BundleSignatureAuthority.canReplace(installed: devID, with: otherDevID))

        #expect(BundleSignatureAuthority.canReplace(installed: appleDev, with: devID))
        #expect(BundleSignatureAuthority.canReplace(installed: appleDev, with: appleDev))
        #expect(!BundleSignatureAuthority.canReplace(installed: appleDev, with: .adhoc))
        #expect(!BundleSignatureAuthority.canReplace(installed: appleDev, with: .unsigned))
        #expect(!BundleSignatureAuthority.canReplace(installed: appleDev, with: otherAppleDev))
        #expect(!BundleSignatureAuthority.canReplace(installed: appleDev, with: otherDevID))

        #expect(BundleSignatureAuthority.canReplace(installed: .adhoc, with: devID))
        #expect(!BundleSignatureAuthority.canReplace(installed: .adhoc, with: .adhoc))
        #expect(!BundleSignatureAuthority.canReplace(installed: .unsigned, with: .adhoc))
        #expect(BundleSignatureAuthority.canReplace(installed: .adhoc, with: .adhoc, allowAdhocCandidateForQA: true))
        #expect(BundleSignatureAuthority.canReplace(installed: .unsigned, with: .adhoc, allowAdhocCandidateForQA: true))
        #expect(!BundleSignatureAuthority.canReplace(installed: .adhoc, with: .unsigned))
        #expect(!BundleSignatureAuthority.canReplace(installed: .adhoc, with: otherDevID))

        let emptyAppleDev = BundleSignatureAuthority.appleDevelopment(teamID: "")
        let otherSignedTeam = BundleSignatureAuthority.otherSigned(teamID: team)
        let otherSignedEmpty = BundleSignatureAuthority.otherSigned(teamID: "")
        #expect(otherSignedTeam.displayDescription == "Signed (\(team))")
        #expect(otherSignedEmpty.displayDescription == "Signed")
        #expect(!BundleSignatureAuthority.canReplace(installed: otherAppleDev, with: devID, expectedReleaseTeamID: team))
        #expect(!BundleSignatureAuthority.canReplace(installed: emptyAppleDev, with: devID, expectedReleaseTeamID: team))
        #expect(!BundleSignatureAuthority.canReplace(installed: devID, with: otherSignedTeam))
        #expect(!BundleSignatureAuthority.canReplace(installed: appleDev, with: otherSignedTeam))
        #expect(!BundleSignatureAuthority.canReplace(installed: otherSignedTeam, with: devID))
        #expect(!BundleSignatureAuthority.canReplace(installed: otherSignedTeam, with: appleDev))
        #expect(!BundleSignatureAuthority.canReplace(installed: otherSignedTeam, with: otherSignedTeam))
    }

    @Test func antigravityPluginInstallerRefreshesLocalizedPromptsOnlyWhenInstalled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data", isDirectory: true)
            .appendingPathComponent("core-plugin-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("AntigravityConfig", isDirectory: true)
        )
        let installer = AntigravityPluginInstaller(paths: paths)
        try installer.refreshLocalizedMetadataIfInstalled(language: .en)
        #expect(!FileManager.default.fileExists(atPath: paths.antigravityConfigDirectoryURL.path))

        let dummySidecar = root.appendingPathComponent("src-sidecar")
        let dummyCLI = root.appendingPathComponent("src-coding-rewind")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: dummySidecar, permissions: 0o755)
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: dummyCLI, permissions: 0o755)

        let pluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: paths.dataDirectoryURL,
            configDirectoryURL: paths.antigravityConfigDirectoryURL,
            sourceCLIBinaryURL: dummyCLI,
            sourceSidecarBinaryURL: dummySidecar,
            language: .zhHans
        )
        #expect(installer.inspectStatus() == .installed)

        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        let zhData = try Data(contentsOf: manifestURL)
        let zhJSON = try #require(JSONSerialization.jsonObject(with: zhData) as? [String: Any])
        #expect(zhJSON["suggestedPrompts"] as? [String] == AntigravityIntegration.suggestedPrompts(in: .zhHans))

        try installer.refreshLocalizedMetadataIfInstalled(language: .en)
        let enData = try Data(contentsOf: manifestURL)
        let enJSON = try #require(JSONSerialization.jsonObject(with: enData) as? [String: Any])
        #expect(enJSON["suggestedPrompts"] as? [String] == AntigravityIntegration.suggestedPrompts(in: .en))

        try installer.refreshLocalizedMetadataIfInstalled(language: .zhHans)
        let revertedData = try Data(contentsOf: manifestURL)
        let revertedJSON = try #require(JSONSerialization.jsonObject(with: revertedData) as? [String: Any])
        #expect(revertedJSON["suggestedPrompts"] as? [String] == AntigravityIntegration.suggestedPrompts(in: .zhHans))
    }
}

// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Darwin
import Foundation
import Observation

@MainActor
@Observable
public final class AppUpdater {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(SemanticVersion)
        case updateAvailable(GitHubReleaseCandidate)
        case downloading(GitHubReleaseCandidate)
        case verifying(GitHubReleaseCandidate)
        case readyToInstall(StagedUpdate)
        case manualDownloadRequired(candidate: GitHubReleaseCandidate, reason: ManualUpdateReason)
        case installing(SemanticVersion)
        case failed(String)
    }

    enum FailureNotice: Equatable, Sendable {
        case sha256Mismatch
        case missingAppInArchive
        case tamperedSignature
        case httpStatus(Int, String)
        case parse(UpdateParseError)
        case rewind(RewindError)
        case other(String)

        func message(in language: AppLanguage) -> String {
            AppStrings.updaterFailureMessage(self, in: language)
        }
    }

    public typealias CandidateGatekeeperAssessor = @Sendable (URL) -> Bool

    public static let automaticChecksDefaultsKey = "automaticallyChecksForUpdates"
    public static let lastCheckedTimestampDefaultsKey = "lastUpdateCheckTimestamp"
    public static let backgroundCheckIntervalSeconds: TimeInterval = 12 * 3600
    private nonisolated static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private nonisolated static let spctlPath = "/usr/sbin/spctl"
    private nonisolated static let swapDirectoryPrefix = ".CodingRewind-swap-"

    public let currentVersion: SemanticVersion
    public let installedBundleURL: URL
    public let installedBundleIdentifier: String
    public let expectedReleaseTeamID: String
    public private(set) var state: State = .idle
    public private(set) var automaticallyChecksForUpdates: Bool
    public private(set) var lastCheckedAt: Date?
    public var language: AppLanguage {
        didSet {
            if let activeFailureNotice, case .failed = state {
                state = .failed(activeFailureNotice.message(in: language))
            }
        }
    }

    private let paths: StoragePaths
    private let environment: [String: String]
    private let defaults: UserDefaults
    private let transport: any ReleaseTransport
    private let signatureInspector: any CodeSignatureInspecting
    private let candidateGatekeeperAssessor: CandidateGatekeeperAssessor
    private let isInstallLocationWritable: @Sendable (URL) -> Bool
    private let sameVolumeCheck: @Sendable (URL, URL) -> Bool
    private let nowProvider: @Sendable () -> Date
    private let relaunchExecutablePath: String
    private let waitProcessIDProvider: @Sendable () -> pid_t
    private let onOpenURL: @MainActor (URL) -> Bool
    private let onTerminate: @MainActor () -> Void
    private var backgroundTask: Task<Void, Never>?
    private var isCheckingOrInstalling = false
    private var activeFailureNotice: FailureNotice?

    public init(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults,
        currentVersion: SemanticVersion,
        installedBundleURL: URL = Bundle.main.bundleURL,
        installedBundleIdentifier: String = Bundle.main.bundleIdentifier ?? AppBundleID.selfApp,
        expectedReleaseTeamID: String = BundleSignatureAuthority.defaultReleaseTeamID,
        language: AppLanguage = .zhHans,
        transport: any ReleaseTransport = URLSessionReleaseTransport(),
        signatureInspector: any CodeSignatureInspecting = SecStaticCodeSignatureInspector(),
        candidateGatekeeperAssessor: @escaping CandidateGatekeeperAssessor = AppUpdater.defaultAssessNotarizedDeveloperID,
        isInstallLocationWritable: @escaping @Sendable (URL) -> Bool = AppUpdater.defaultIsInstallLocationWritable,
        sameVolumeCheck: @escaping @Sendable (URL, URL) -> Bool = AppUpdater.defaultSameFilesystemVolume,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        relaunchExecutablePath: String = "",
        waitProcessIDProvider: @escaping @Sendable () -> pid_t = { getpid() },
        onOpenURL: @escaping @MainActor (URL) -> Bool = { SystemURLOpener.open($0) },
        onTerminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.paths = paths
        self.environment = environment
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.installedBundleURL = installedBundleURL.standardizedFileURL
        self.installedBundleIdentifier = installedBundleIdentifier
        self.expectedReleaseTeamID = expectedReleaseTeamID
        self.language = language
        self.transport = transport
        self.signatureInspector = signatureInspector
        self.candidateGatekeeperAssessor = candidateGatekeeperAssessor
        self.isInstallLocationWritable = isInstallLocationWritable
        self.sameVolumeCheck = sameVolumeCheck
        self.nowProvider = nowProvider
        self.relaunchExecutablePath = relaunchExecutablePath
        self.waitProcessIDProvider = waitProcessIDProvider
        self.onOpenURL = onOpenURL
        self.onTerminate = onTerminate

        if defaults.object(forKey: Self.automaticChecksDefaultsKey) == nil {
            self.automaticallyChecksForUpdates = true
        } else {
            self.automaticallyChecksForUpdates = defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        }
        if let ts = defaults.object(forKey: Self.lastCheckedTimestampDefaultsKey) as? Double, ts > 0 {
            self.lastCheckedAt = Date(timeIntervalSince1970: ts)
        } else {
            self.lastCheckedAt = nil
        }

        pruneStaleStagingDirectories()
    }

    public static func live(
        paths: StoragePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults,
        language: AppLanguage = .zhHans
    ) -> AppUpdater {
        let rawVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.7.0"
        let version = SemanticVersion(parsing: rawVersion) ?? SemanticVersion(major: 0, minor: 7, patch: 0)
        return AppUpdater(
            paths: paths,
            environment: environment,
            defaults: defaults,
            currentVersion: version,
            installedBundleURL: Bundle.main.bundleURL,
            installedBundleIdentifier: Bundle.main.bundleIdentifier ?? AppBundleID.selfApp,
            language: language
        )
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        defaults.set(enabled, forKey: Self.automaticChecksDefaultsKey)
        if enabled {
            startBackgroundSchedule()
        } else {
            stop()
        }
    }

    public func startBackgroundSchedule() {
        guard environment[StoragePaths.qaEnvironmentKey] != "1",
              automaticallyChecksForUpdates else {
            return
        }
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticallyChecksForUpdates {
                    let shouldCheck: Bool
                    if let last = self.lastCheckedAt {
                        shouldCheck = self.nowProvider().timeIntervalSince(last) >= Self.backgroundCheckIntervalSeconds
                    } else {
                        shouldCheck = true
                    }
                    if shouldCheck {
                        await self.checkForUpdates(userInitiated: false)
                    }
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    public func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    @discardableResult
    public func openReleasePage(_ candidate: GitHubReleaseCandidate) -> Bool {
        let opened = onOpenURL(candidate.htmlURL)
        if !opened {
            NSSound.beep()
        }
        return opened
    }

    public func pruneStaleStagingDirectories() {
        let fm = FileManager.default
        let updatesDir = paths.updatesDirectoryURL
        if fm.fileExists(atPath: updatesDir.path),
           let children = try? fm.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil) {
            let activeStagingURL: URL?
            if case .readyToInstall(let staged) = state {
                activeStagingURL = staged.stagingDirectoryURL.standardizedFileURL
            } else {
                activeStagingURL = nil
            }
            let installedExists = fm.fileExists(atPath: installedBundleURL.path)
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix("staging-") {
                    if child.standardizedFileURL == activeStagingURL { continue }
                    Self.unregisterAppsRecursively(under: child)
                    try? fm.removeItem(at: child)
                } else if installedExists && name.hasPrefix("rollback-") {
                    Self.unregisterAppsRecursively(under: child)
                    try? fm.removeItem(at: child)
                }
            }
        }

        let installParent = installedBundleURL.deletingLastPathComponent()
        if Darwin.access(installParent.path, W_OK) == 0,
           let siblings = try? fm.contentsOfDirectory(at: installParent, includingPropertiesForKeys: nil) {
            for sibling in siblings where sibling.lastPathComponent.hasPrefix(Self.swapDirectoryPrefix) {
                let rollbackApp = sibling.appendingPathComponent("rollback.app", isDirectory: true)
                if !fm.fileExists(atPath: installedBundleURL.path), Self.isRealDirectory(at: rollbackApp) {
                    try? fm.moveItem(at: rollbackApp, to: installedBundleURL)
                }
                Self.unregisterAppsRecursively(under: sibling)
                try? fm.removeItem(at: sibling)
            }
        }
    }

    public func checkForUpdates(userInitiated: Bool = false) async {
        _ = userInitiated
        guard !isCheckingOrInstalling else { return }
        isCheckingOrInstalling = true
        defer { isCheckingOrInstalling = false }

        if case .readyToInstall(let previousStaged) = state {
            Self.cleanupDirectory(previousStaged.stagingDirectoryURL)
        }
        activeFailureNotice = nil
        state = .checking

        do {
            let releaseData = try await transport.fetchLatestReleaseJSON()
            let checkedAt = nowProvider()
            lastCheckedAt = checkedAt
            defaults.set(checkedAt.timeIntervalSince1970, forKey: Self.lastCheckedTimestampDefaultsKey)

            var candidate = try GitHubReleaseCandidate.parseLatestRelease(jsonData: releaseData)
            guard candidate.version > currentVersion else {
                state = .upToDate(currentVersion)
                return
            }

            state = .updateAvailable(candidate)

            guard installedBundleURL.pathExtension.lowercased() == "app" else {
                state = .manualDownloadRequired(candidate: candidate, reason: .nonAppBundleInstall)
                return
            }

            guard let checksumsURL = candidate.checksumsURL else {
                state = .manualDownloadRequired(candidate: candidate, reason: .missingChecksum)
                return
            }
            let checksumsText = try await transport.fetchText(from: checksumsURL)
            candidate = candidate.withChecksumsText(checksumsText)
            guard let expectedDigest = candidate.expectedSHA256 else {
                state = .manualDownloadRequired(candidate: candidate, reason: .missingChecksum)
                return
            }

            let updatesDir = try ensurePrivateUpdatesDirectory()
            let stagingDir = updatesDir.appendingPathComponent(
                "staging-\(candidate.version.description)-\(UUID().uuidString)",
                isDirectory: true
            )
            guard mkdir(stagingDir.path, 0o700) == 0 else {
                throw RewindError.ioError("mkdir staging errno=\(errno)")
            }
            _ = chmod(stagingDir.path, 0o700)

            let archiveURL = stagingDir.appendingPathComponent(candidate.macosArchiveName, isDirectory: false)
            state = .downloading(candidate)
            do {
                try await transport.downloadArchive(from: candidate.macosArchiveURL, to: archiveURL)
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                throw error
            }

            state = .verifying(candidate)
            let actualDigest = try SHA256Digest.compute(fileAt: archiveURL)
            guard actualDigest == expectedDigest else {
                try? FileManager.default.removeItem(at: stagingDir)
                setFailure(.sha256Mismatch)
                return
            }

            let unpackedDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpackedDir, withIntermediateDirectories: true)
            let unpackOK = await Self.runProcess(
                executablePath: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, unpackedDir.path]
            )
            guard unpackOK,
                  let stagedAppURL = Self.findStagedAppBundle(
                      in: unpackedDir,
                      expectedName: installedBundleURL.lastPathComponent
                  ) else {
                Self.cleanupDirectory(stagingDir)
                setFailure(.missingAppInArchive)
                return
            }

            Self.unregisterBundleFromLaunchServices(stagedAppURL)

            guard let (_, expectedBundleID) = await verifyBundleReplacement(
                candidate: candidate,
                candidateBundleURL: stagedAppURL,
                cleanupURLs: [stagingDir]
            ) else {
                return
            }
            _ = expectedBundleID

            guard isInstallLocationWritable(installedBundleURL) else {
                Self.cleanupDirectory(stagingDir)
                state = .manualDownloadRequired(candidate: candidate, reason: .installLocationNotWritable)
                return
            }

            try? FileManager.default.removeItem(at: archiveURL)
            state = .readyToInstall(
                StagedUpdate(
                    candidate: candidate,
                    stagingDirectoryURL: stagingDir,
                    stagedAppURL: stagedAppURL
                )
            )
        } catch {
            setFailure(Self.failureNotice(from: error))
        }
    }

    @discardableResult
    public func installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: Bool = false) async -> Bool {
        guard case .readyToInstall(let staged) = state, !isCheckingOrInstalling else {
            return false
        }
        guard installedBundleURL.pathExtension.lowercased() == "app" else {
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .nonAppBundleInstall)
            return false
        }

        isCheckingOrInstalling = true
        defer { isCheckingOrInstalling = false }

        guard Self.isRealDirectory(at: staged.stagedAppURL) else {
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            setFailure(.missingAppInArchive)
            return false
        }

        guard let (installedSig, expectedBundleID) = await verifyBundleReplacement(
            candidate: staged.candidate,
            candidateBundleURL: staged.stagedAppURL,
            cleanupURLs: [staged.stagingDirectoryURL]
        ) else {
            return false
        }

        guard isInstallLocationWritable(installedBundleURL) else {
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
            return false
        }

        let installParentURL = installedBundleURL.deletingLastPathComponent()
        let swapWorkDir = installParentURL.appendingPathComponent(
            "\(Self.swapDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(swapWorkDir.path, 0o700) == 0 else {
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
            return false
        }
        _ = chmod(swapWorkDir.path, 0o700)

        guard sameVolumeCheck(swapWorkDir, installParentURL) else {
            Self.cleanupDirectory(swapWorkDir)
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
            return false
        }

        let sameVolumeStagedApp = swapWorkDir.appendingPathComponent("staged.app", isDirectory: true)
        let movedOnSameVolume = sameVolumeCheck(staged.stagedAppURL, swapWorkDir)
        if movedOnSameVolume {
            do {
                try FileManager.default.moveItem(at: staged.stagedAppURL, to: sameVolumeStagedApp)
            } catch {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
                return false
            }
            Self.unregisterBundleFromLaunchServices(sameVolumeStagedApp)
        } else {
            let copied = await Self.runProcess(
                executablePath: "/usr/bin/ditto",
                arguments: [staged.stagedAppURL.path, sameVolumeStagedApp.path]
            )
            guard copied, Self.isRealDirectory(at: sameVolumeStagedApp) else {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
                return false
            }
            Self.unregisterBundleFromLaunchServices(sameVolumeStagedApp)

            let copiedSig: InspectedCodeSignature
            do {
                copiedSig = try signatureInspector.inspect(bundleURL: sameVolumeStagedApp)
            } catch CodeSignatureInspectionError.bundleIdentifierMismatch {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                state = .manualDownloadRequired(candidate: staged.candidate, reason: .bundleIdentifierMismatch)
                return false
            } catch {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                setFailure(.tamperedSignature)
                return false
            }
            guard copiedSig.bundleIdentifier == expectedBundleID else {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                state = .manualDownloadRequired(candidate: staged.candidate, reason: .bundleIdentifierMismatch)
                return false
            }
            guard installedSig.authority.canReplace(
                with: copiedSig.authority,
                expectedReleaseTeamID: expectedReleaseTeamID,
                allowAdhocCandidateForQA: allowsAdhocCandidate(expectedBundleID: expectedBundleID)
            ) else {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                state = .manualDownloadRequired(candidate: staged.candidate, reason: .signatureDowngradeBlocked)
                return false
            }
            if case .developerID = copiedSig.authority,
               !(await evaluateCandidateGatekeeper(at: sameVolumeStagedApp)) {
                Self.cleanupDirectory(swapWorkDir)
                Self.cleanupDirectory(staged.stagingDirectoryURL)
                setFailure(.tamperedSignature)
                return false
            }
        }

        guard Self.hasValidCandidatePayload(
            at: sameVolumeStagedApp,
            expectedVersion: staged.candidate.version
        ) else {
            Self.cleanupDirectory(swapWorkDir)
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            setFailure(.tamperedSignature)
            return false
        }

        state = .installing(staged.candidate.version)

        do {
            let updatesDir = try ensurePrivateUpdatesDirectory()
            let scriptURL = updatesDir.appendingPathComponent("apply-update.sh", isDirectory: false)
            try AtomicFile.writeUTF8(Self.swapScriptContents, to: scriptURL, permissions: 0o700)
            _ = chmod(scriptURL.path, 0o700)

            let destSidecar = AntigravityIntegration.stableSidecarBinaryURL(in: paths.dataDirectoryURL)
            let destCLI = AntigravityIntegration.stableCLIBinaryURL(in: paths.dataDirectoryURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                scriptURL.path,
                String(waitProcessIDProvider()),
                installedBundleURL.path,
                swapWorkDir.path,
                staged.stagingDirectoryURL.path,
                destSidecar.path,
                destCLI.path,
                relaunchExecutablePath
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            onTerminate()
            if waitForSwapCompletionInTests {
                await Self.waitUntilExit(process)
                return process.terminationStatus == 0
            }
            return true
        } catch {
            Self.cleanupDirectory(swapWorkDir)
            Self.cleanupDirectory(staged.stagingDirectoryURL)
            setFailure(Self.failureNotice(from: error))
            return false
        }
    }

    private func allowsAdhocCandidate(expectedBundleID: String) -> Bool {
        environment[StoragePaths.qaEnvironmentKey] == "1"
            && expectedBundleID == AppBundleID.selfQAApp
    }

    private func evaluateCandidateGatekeeper(at bundleURL: URL) async -> Bool {
        let assessor = candidateGatekeeperAssessor
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: assessor(bundleURL))
            }
        }
    }

    private func verifyBundleReplacement(
        candidate: GitHubReleaseCandidate,
        candidateBundleURL: URL,
        cleanupURLs: [URL]
    ) async -> (installed: InspectedCodeSignature, expectedBundleID: String)? {
        let installedSig: InspectedCodeSignature
        do {
            installedSig = try signatureInspector.inspect(bundleURL: installedBundleURL)
        } catch {
            cleanupURLs.forEach(Self.cleanupDirectory)
            setFailure(.tamperedSignature)
            return nil
        }

        let candidateSig: InspectedCodeSignature
        do {
            candidateSig = try signatureInspector.inspect(bundleURL: candidateBundleURL)
        } catch CodeSignatureInspectionError.bundleIdentifierMismatch {
            cleanupURLs.forEach(Self.cleanupDirectory)
            state = .manualDownloadRequired(candidate: candidate, reason: .bundleIdentifierMismatch)
            return nil
        } catch {
            cleanupURLs.forEach(Self.cleanupDirectory)
            setFailure(.tamperedSignature)
            return nil
        }

        let expectedBundleID = installedSig.bundleIdentifier ?? installedBundleIdentifier
        guard candidateSig.bundleIdentifier == expectedBundleID else {
            cleanupURLs.forEach(Self.cleanupDirectory)
            state = .manualDownloadRequired(candidate: candidate, reason: .bundleIdentifierMismatch)
            return nil
        }

        guard installedSig.authority.canReplace(
            with: candidateSig.authority,
            expectedReleaseTeamID: expectedReleaseTeamID,
            allowAdhocCandidateForQA: allowsAdhocCandidate(expectedBundleID: expectedBundleID)
        ) else {
            cleanupURLs.forEach(Self.cleanupDirectory)
            state = .manualDownloadRequired(candidate: candidate, reason: .signatureDowngradeBlocked)
            return nil
        }

        if case .developerID = candidateSig.authority,
           !(await evaluateCandidateGatekeeper(at: candidateBundleURL)) {
            cleanupURLs.forEach(Self.cleanupDirectory)
            setFailure(.tamperedSignature)
            return nil
        }

        guard Self.hasValidCandidatePayload(
            at: candidateBundleURL,
            expectedVersion: candidate.version
        ) else {
            cleanupURLs.forEach(Self.cleanupDirectory)
            setFailure(.tamperedSignature)
            return nil
        }

        return (installedSig, expectedBundleID)
    }

    private func ensurePrivateUpdatesDirectory() throws -> URL {
        let updatesDir = paths.updatesDirectoryURL
        if mkdir(updatesDir.path, 0o700) != 0 && errno != EEXIST {
            throw RewindError.ioError("mkdir updates errno=\(errno)")
        }
        let currentUID = getuid()
        var dirStat = stat()
        guard lstat(updatesDir.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == currentUID else {
            throw RewindError.ioError("updates directory is not a private user-owned directory")
        }
        _ = chmod(updatesDir.path, 0o700)
        guard lstat(updatesDir.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == currentUID,
              (dirStat.st_mode & 0o077) == 0 else {
            throw RewindError.ioError("updates directory failed 0700 verification")
        }
        return updatesDir
    }

    private func setFailure(_ notice: FailureNotice) {
        activeFailureNotice = notice
        state = .failed(notice.message(in: language))
    }

    private static func failureNotice(from error: any Error) -> FailureNotice {
        if let transportError = error as? ReleaseTransportError {
            switch transportError {
            case .httpStatus(let code, let detail):
                return .httpStatus(code, detail)
            }
        }
        if let parseError = error as? UpdateParseError {
            return .parse(parseError)
        }
        if let rewindError = error as? RewindError {
            return .rewind(rewindError)
        }
        return .other(error.localizedDescription)
    }

    public static nonisolated func defaultIsInstallLocationWritable(_ installedAppURL: URL) -> Bool {
        let parentPath = installedAppURL.deletingLastPathComponent().path
        guard Darwin.access(parentPath, W_OK) == 0 else { return false }
        if FileManager.default.fileExists(atPath: installedAppURL.path) {
            return Darwin.access(installedAppURL.path, W_OK) == 0
        }
        return true
    }

    public static nonisolated func defaultSameFilesystemVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        var leftStat = statfs()
        var rightStat = statfs()
        guard statfs(lhs.path, &leftStat) == 0,
              statfs(rhs.path, &rightStat) == 0 else {
            return false
        }
        return leftStat.f_fsid.val == rightStat.f_fsid.val
    }

    static nonisolated func findStagedAppBundle(
        in unpackedDir: URL,
        expectedName: String = "CodingRewind.app"
    ) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: unpackedDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let validApps = sortedEntries.filter { entry in
            entry.pathExtension.lowercased() == "app" && isRealDirectory(at: entry)
        }
        let chosen = validApps.first { $0.lastPathComponent == expectedName } ?? validApps.first
        return chosen?.standardizedFileURL
    }

    private static nonisolated func isRealDirectory(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static nonisolated func hasValidCandidatePayload(
        at bundleURL: URL,
        expectedVersion: SemanticVersion
    ) -> Bool {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard isRegularFile(at: infoPlistURL),
              let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
              let rawShortVersion = plist["CFBundleShortVersionString"] as? String,
              let bundleVersion = SemanticVersion(parsing: rawShortVersion),
              bundleVersion == expectedVersion else {
            return false
        }
        let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        return isRegularExecutableFile(at: helpersDir.appendingPathComponent("coding-rewind-sidecar", isDirectory: false))
            && isRegularExecutableFile(at: helpersDir.appendingPathComponent("coding-rewind", isDirectory: false))
    }

    private static nonisolated func isRegularFile(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static nonisolated func isRegularExecutableFile(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        let isExecutable = (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0
        return isRegular && isExecutable
    }

    private static nonisolated func cleanupDirectory(_ directoryURL: URL) {
        unregisterAppsRecursively(under: directoryURL)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static nonisolated func unregisterAppsRecursively(under directoryURL: URL) {
        if directoryURL.pathExtension.lowercased() == "app" {
            unregisterBundleFromLaunchServices(directoryURL)
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "app" {
            unregisterBundleFromLaunchServices(fileURL)
            enumerator.skipDescendants()
        }
    }

    public static nonisolated func defaultAssessNotarizedDeveloperID(_ bundleURL: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: spctlPath) else {
            return false
        }
        let process = Process()
        let outPipe = Pipe()
        let readHandle = outPipe.fileHandleForReading
        let exitSemaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            func set(_ data: Data) { lock.lock(); bytes = data; lock.unlock() }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let outputBox = OutputBox()

        var spctlEnv = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("DYLD_") }
        spctlEnv["LC_ALL"] = "C"
        process.executableURL = URL(fileURLWithPath: spctlPath)
        process.arguments = ["--assess", "--type", "execute", "--verbose=4", bundleURL.path]
        process.environment = spctlEnv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = outPipe
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let collected = (try? readHandle.readToEnd()) ?? Data()
            outputBox.set(collected)
            readGroup.leave()
        }

        do {
            try process.run()
            try? outPipe.fileHandleForWriting.close()
        } catch {
            try? readHandle.close()
            return false
        }

        if exitSemaphore.wait(timeout: .now() + 15.0) == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
            try? readHandle.close()
            process.waitUntilExit()
            _ = readGroup.wait(timeout: .now() + 0.5)
            return false
        }

        process.waitUntilExit()
        if readGroup.wait(timeout: .now() + 1.0) == .timedOut {
            try? readHandle.close()
            _ = readGroup.wait(timeout: .now() + 0.5)
        }
        guard process.terminationStatus == 0 else {
            return false
        }
        let outputText = String(decoding: outputBox.get(), as: UTF8.self)
        return outputText.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces) == "source=Notarized Developer ID"
        }
    }

    public static nonisolated func unregisterBundleFromLaunchServices(_ bundleURL: URL) {
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-u", bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static nonisolated func runProcess(executablePath: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static nonisolated func waitUntilExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private static let swapScriptContents = """
    #!/bin/sh
    trap '' HUP
    set -u
    WAIT_PID="$1"
    INSTALLED_APP="$2"
    SWAP_WORK_DIR="$3"
    STAGING_DIR="$4"
    DEST_SIDECAR="$5"
    DEST_CLI="$6"
    RELAUNCH_OVERRIDE="$7"

    STAGED_APP="$SWAP_WORK_DIR/staged.app"
    ROLLBACK_APP="$SWAP_WORK_DIR/rollback.app"

    relaunch_installed_app() {
      app_exec="$INSTALLED_APP/Contents/MacOS/CodingRewindApp"
      if [ -n "$RELAUNCH_OVERRIDE" ]; then
        "$RELAUNCH_OVERRIDE" "$app_exec" --restarted-after-update >/dev/null 2>&1 || true
      elif [ -x "$app_exec" ]; then
        "$app_exec" --restarted-after-update </dev/null >/dev/null 2>&1 &
      fi
    }

    refresh_helper() {
      src_file="$1"
      dest_file="$2"
      force_stage="${3:-0}"
      if [ -n "$dest_file" ] && { [ -e "$dest_file" ] || [ "$force_stage" = "1" ]; } && [ -f "$src_file" ] && [ ! -L "$src_file" ]; then
        /bin/mkdir -p "$(/usr/bin/dirname "$dest_file")"
        tmp_file="${dest_file}.tmp.$$"
        if /bin/cp "$src_file" "$tmp_file" && /bin/chmod 755 "$tmp_file"; then
          /bin/mv -f "$tmp_file" "$dest_file" || /bin/rm -f "$tmp_file"
        else
          /bin/rm -f "$tmp_file"
        fi
      fi
    }

    elapsed=0
    while kill -0 "$WAIT_PID" 2>/dev/null; do
      if [ "$elapsed" -ge 150 ]; then
        /bin/rm -rf "$SWAP_WORK_DIR" "$STAGING_DIR"
        exit 1
      fi
      /bin/sleep 0.1
      elapsed=$((elapsed + 1))
    done

    move_ok=1
    if [ -e "$INSTALLED_APP" ]; then
      if ! /bin/mv "$INSTALLED_APP" "$ROLLBACK_APP"; then
        move_ok=0
      fi
    fi

    if [ "$move_ok" -eq 1 ]; then
      if ! /bin/mv "$STAGED_APP" "$INSTALLED_APP"; then
        move_ok=0
      fi
    fi

    if [ "$move_ok" -eq 1 ]; then
      /usr/bin/xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
      legacy_bridge=""
      if [ -n "$DEST_CLI" ]; then
        legacy_bridge="$(/usr/bin/dirname "$DEST_CLI")/memos-mcp-bridge.sh"
      fi
      stage_cli=0
      if [ -n "$DEST_SIDECAR" ] && [ -e "$DEST_SIDECAR" ]; then
        stage_cli=1
      elif [ -n "$legacy_bridge" ] && [ -e "$legacy_bridge" ]; then
        stage_cli=1
      fi
      refresh_helper "$INSTALLED_APP/Contents/Helpers/coding-rewind-sidecar" "$DEST_SIDECAR" 0
      refresh_helper "$INSTALLED_APP/Contents/Helpers/coding-rewind" "$DEST_CLI" "$stage_cli"
      if [ -n "$legacy_bridge" ]; then
        /bin/rm -f "$legacy_bridge"
      fi
      /bin/rm -rf "$SWAP_WORK_DIR" "$STAGING_DIR"
      relaunch_installed_app
      exit 0
    fi

    if [ -e "$ROLLBACK_APP" ]; then
      /bin/rm -rf "$INSTALLED_APP"
      /bin/mv "$ROLLBACK_APP" "$INSTALLED_APP" || true
    fi
    if [ -e "$INSTALLED_APP" ]; then
      /bin/rm -rf "$SWAP_WORK_DIR" "$STAGING_DIR"
      relaunch_installed_app
    fi
    exit 1
    """
}

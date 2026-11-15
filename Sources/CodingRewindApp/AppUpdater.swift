// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Darwin
import Foundation
import Observation
import Security

public struct StagedUpdate: Equatable, Sendable {
    public let candidate: GitHubReleaseCandidate
    public let stagingDirectoryURL: URL
    public let stagedAppURL: URL

    public init(candidate: GitHubReleaseCandidate, stagingDirectoryURL: URL, stagedAppURL: URL) {
        self.candidate = candidate
        self.stagingDirectoryURL = stagingDirectoryURL
        self.stagedAppURL = stagedAppURL
    }
}

public enum ManualUpdateReason: Equatable, Sendable {
    case missingChecksum
    case signatureDowngradeBlocked
    case bundleIdentifierMismatch
    case installLocationNotWritable
    case nonAppBundleInstall
}

public struct InspectedCodeSignature: Equatable, Sendable {
    public let authority: BundleSignatureAuthority
    public let bundleIdentifier: String?

    public init(authority: BundleSignatureAuthority, bundleIdentifier: String?) {
        self.authority = authority
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum CodeSignatureInspectionError: Error, Equatable, Sendable {
    case invalidOrTamperedSignature(OSStatus)
    case bundleIdentifierMismatch(plist: String, signed: String)
}

public protocol ReleaseTransport: Sendable {
    func fetchLatestReleaseJSON() async throws -> Data
    func fetchText(from url: URL) async throws -> String
    func downloadArchive(from url: URL, to destinationURL: URL) async throws
}

public struct URLSessionReleaseTransport: ReleaseTransport {
    public static let defaultLatestReleaseURL = URL(
        string: "https://api.github.com/repos/semantic-craft/coding-rewind/releases/latest"
    )!

    private let latestReleaseURL: URL
    private let session: URLSession

    public init(
        latestReleaseURL: URL = defaultLatestReleaseURL,
        session: URLSession = .shared
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.session = session
    }

    public func fetchLatestReleaseJSON() async throws -> Data {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RewindError.httpError(
                statusCode: http.statusCode,
                body: String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        return data
    }

    public func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RewindError.httpError(
                statusCode: http.statusCode,
                body: String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func downloadArchive(from url: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("CodingRewind-macOS", forHTTPHeaderField: "User-Agent")
        let (downloadedURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw RewindError.httpError(statusCode: http.statusCode, body: "archive download failed")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: downloadedURL, to: destinationURL)
        _ = chmod(destinationURL.path, 0o600)
    }
}

public protocol CodeSignatureInspecting: Sendable {
    func inspect(bundleURL: URL) throws -> InspectedCodeSignature
}

public struct SecStaticCodeSignatureInspector: CodeSignatureInspecting {
    public init() {}

    public func inspect(bundleURL: URL) throws -> InspectedCodeSignature {
        let plistBundleID = Self.readPlistBundleIdentifier(at: bundleURL)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return InspectedCodeSignature(authority: .unsigned, bundleIdentifier: plistBundleID)
        }

        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let validStatus = SecStaticCodeCheckValidityWithErrors(code, checkFlags, nil, nil)
        if validStatus == errSecCSUnsigned {
            return InspectedCodeSignature(authority: .unsigned, bundleIdentifier: plistBundleID)
        }
        guard validStatus == errSecSuccess else {
            throw CodeSignatureInspectionError.invalidOrTamperedSignature(validStatus)
        }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            throw CodeSignatureInspectionError.invalidOrTamperedSignature(infoStatus)
        }

        let signedID = info[kSecCodeInfoIdentifier as String] as? String
        if let plistBundleID, let signedID, plistBundleID != signedID {
            throw CodeSignatureInspectionError.bundleIdentifierMismatch(plist: plistBundleID, signed: signedID)
        }

        let flags: UInt32
        if let rawFlags = info[kSecCodeInfoFlags as String] as? UInt32 {
            flags = rawFlags
        } else if let rawInt = info[kSecCodeInfoFlags as String] as? Int {
            flags = UInt32(truncatingIfNeeded: rawInt)
        } else {
            flags = 0
        }

        if (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0 {
            return InspectedCodeSignature(authority: .adhoc, bundleIdentifier: plistBundleID ?? signedID)
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let leafSummary = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""

        let authority: BundleSignatureAuthority
        if leafSummary.hasPrefix("Developer ID Application:") {
            authority = .developerID(teamID: teamID)
        } else if leafSummary.hasPrefix("Apple Development:") || leafSummary.hasPrefix("Mac Developer:") {
            authority = .appleDevelopment(teamID: teamID)
        } else if !teamID.isEmpty {
            authority = .appleDevelopment(teamID: teamID)
        } else {
            authority = .unsigned
        }

        return InspectedCodeSignature(authority: authority, bundleIdentifier: plistBundleID ?? signedID)
    }

    private static func readPlistBundleIdentifier(at bundleURL: URL) -> String? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String,
              !id.isEmpty else {
            return nil
        }
        return id
    }
}

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

    private enum FailureNotice {
        case sha256Mismatch
        case missingAppInArchive
        case tamperedSignature
        case generic(String)

        func message(in language: AppLanguage) -> String {
            switch language {
            case .zhHans:
                switch self {
                case .sha256Mismatch:
                    return "安装包 SHA-256 校验不匹配，已拒绝安装。"
                case .missingAppInArchive:
                    return "更新压缩包中未找到有效的应用包。"
                case .tamperedSignature:
                    return "更新包代码签名校验失败，已拒绝安装。"
                case .generic(let detail):
                    return "检查更新失败：\(detail)"
                }
            case .en:
                switch self {
                case .sha256Mismatch:
                    return "Archive SHA-256 checksum mismatch; update was rejected."
                case .missingAppInArchive:
                    return "No valid application bundle was found in the update archive."
                case .tamperedSignature:
                    return "Code signature verification failed; update was rejected."
                case .generic(let detail):
                    return "Update check failed: \(detail)"
                }
            }
        }
    }

    public static let automaticChecksDefaultsKey = "automaticallyChecksForUpdates"
    public static let lastCheckedTimestampDefaultsKey = "lastUpdateCheckTimestamp"
    public static let backgroundCheckIntervalSeconds: TimeInterval = 12 * 3600
    private nonisolated static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
    private let isInstallLocationWritable: @Sendable (URL) -> Bool
    private let nowProvider: @Sendable () -> Date
    private let relaunchExecutablePath: String
    private let waitProcessIDProvider: @Sendable () -> pid_t
    private let onOpenURL: @MainActor (URL) -> Void
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
        isInstallLocationWritable: @escaping @Sendable (URL) -> Bool = AppUpdater.defaultIsInstallLocationWritable,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        relaunchExecutablePath: String = "/usr/bin/open",
        waitProcessIDProvider: @escaping @Sendable () -> pid_t = { getpid() },
        onOpenURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
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
        self.isInstallLocationWritable = isInstallLocationWritable
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
        let rawVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.3.2"
        let version = SemanticVersion(parsing: rawVersion) ?? SemanticVersion(major: 0, minor: 3, patch: 2)
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

    public func openReleasePage(_ candidate: GitHubReleaseCandidate) {
        onOpenURL(candidate.htmlURL)
    }

    public func pruneStaleStagingDirectories() {
        let updatesDir = paths.updatesDirectoryURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: updatesDir.path),
              let children = try? fm.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil) else {
            return
        }
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

    public func checkForUpdates(userInitiated: Bool = false) async {
        _ = userInitiated
        guard !isCheckingOrInstalling else { return }
        isCheckingOrInstalling = true
        defer { isCheckingOrInstalling = false }

        if case .readyToInstall(let previousStaged) = state {
            Self.unregisterBundleFromLaunchServices(previousStaged.stagedAppURL)
            try? FileManager.default.removeItem(at: previousStaged.stagingDirectoryURL)
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
            if mkdir(stagingDir.path, 0o700) != 0 && errno != EEXIST {
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
            guard unpackOK, let stagedAppURL = Self.findStagedAppBundle(in: unpackedDir) else {
                Self.unregisterAppsRecursively(under: stagingDir)
                try? FileManager.default.removeItem(at: stagingDir)
                setFailure(.missingAppInArchive)
                return
            }

            // Unregister immediately so LaunchServices never routes URL schemes or Login Items to staging.
            Self.unregisterBundleFromLaunchServices(stagedAppURL)

            let installedSig: InspectedCodeSignature
            let stagedSig: InspectedCodeSignature
            do {
                installedSig = try signatureInspector.inspect(bundleURL: installedBundleURL)
                stagedSig = try signatureInspector.inspect(bundleURL: stagedAppURL)
            } catch {
                Self.unregisterBundleFromLaunchServices(stagedAppURL)
                try? FileManager.default.removeItem(at: stagingDir)
                setFailure(.tamperedSignature)
                return
            }

            let expectedBundleID = installedSig.bundleIdentifier ?? installedBundleIdentifier
            guard stagedSig.bundleIdentifier == expectedBundleID else {
                Self.unregisterBundleFromLaunchServices(stagedAppURL)
                try? FileManager.default.removeItem(at: stagingDir)
                state = .manualDownloadRequired(candidate: candidate, reason: .bundleIdentifierMismatch)
                return
            }

            guard BundleSignatureAuthority.canReplace(
                installed: installedSig.authority,
                with: stagedSig.authority,
                expectedReleaseTeamID: expectedReleaseTeamID
            ) else {
                Self.unregisterBundleFromLaunchServices(stagedAppURL)
                try? FileManager.default.removeItem(at: stagingDir)
                state = .manualDownloadRequired(candidate: candidate, reason: .signatureDowngradeBlocked)
                return
            }

            guard isInstallLocationWritable(installedBundleURL) else {
                Self.unregisterBundleFromLaunchServices(stagedAppURL)
                try? FileManager.default.removeItem(at: stagingDir)
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
            if let rewindError = error as? RewindError {
                setFailure(.generic(rewindError.localizedDescription(in: language)))
            } else {
                setFailure(.generic(error.localizedDescription))
            }
        }
    }

    @discardableResult
    public func installReadyUpdateAndRelaunch(waitForSwapCompletionInTests: Bool = false) async -> Bool {
        guard case .readyToInstall(let staged) = state, !isCheckingOrInstalling else {
            return false
        }
        guard installedBundleURL.pathExtension.lowercased() == "app" else {
            Self.unregisterBundleFromLaunchServices(staged.stagedAppURL)
            try? FileManager.default.removeItem(at: staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .nonAppBundleInstall)
            return false
        }
        guard isInstallLocationWritable(installedBundleURL) else {
            Self.unregisterBundleFromLaunchServices(staged.stagedAppURL)
            try? FileManager.default.removeItem(at: staged.stagingDirectoryURL)
            state = .manualDownloadRequired(candidate: staged.candidate, reason: .installLocationNotWritable)
            return false
        }

        isCheckingOrInstalling = true
        defer { isCheckingOrInstalling = false }
        state = .installing(staged.candidate.version)

        do {
            try refreshInstalledHelpersIfPresent(from: staged.stagedAppURL)
            let updatesDir = try ensurePrivateUpdatesDirectory()
            let scriptURL = updatesDir.appendingPathComponent("apply-update.sh", isDirectory: false)
            let rollbackURL = updatesDir.appendingPathComponent("rollback-CodingRewind.app", isDirectory: true)
            try AtomicFile.writeUTF8(Self.swapScriptContents, to: scriptURL, permissions: 0o700)
            _ = chmod(scriptURL.path, 0o700)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                scriptURL.path,
                String(waitProcessIDProvider()),
                installedBundleURL.path,
                staged.stagedAppURL.path,
                rollbackURL.path,
                staged.stagingDirectoryURL.path,
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
            setFailure(.generic(error.localizedDescription))
            return false
        }
    }

    private func refreshInstalledHelpersIfPresent(from stagedAppURL: URL) throws {
        let fm = FileManager.default
        let helpersDir = stagedAppURL.appendingPathComponent("Contents/Helpers", isDirectory: true)

        let destSidecar = AntigravityIntegration.stableSidecarBinaryURL(in: paths.dataDirectoryURL)
        let srcSidecar = helpersDir.appendingPathComponent("coding-rewind-sidecar", isDirectory: false)
        if fm.fileExists(atPath: destSidecar.path), fm.isExecutableFile(atPath: srcSidecar.path) {
            try AtomicFile.writeData(Data(contentsOf: srcSidecar), to: destSidecar, permissions: 0o755)
            _ = chmod(destSidecar.path, 0o755)
        }

        let destBridge = AntigravityIntegration.stableMCPBridgeURL(in: paths.dataDirectoryURL)
        let srcBridge = helpersDir.appendingPathComponent("memos-mcp-bridge.sh", isDirectory: false)
        if fm.fileExists(atPath: destBridge.path), fm.fileExists(atPath: srcBridge.path) {
            try AtomicFile.writeData(Data(contentsOf: srcBridge), to: destBridge, permissions: 0o755)
            _ = chmod(destBridge.path, 0o755)
        }
    }

    private func ensurePrivateUpdatesDirectory() throws -> URL {
        let updatesDir = paths.updatesDirectoryURL
        if mkdir(updatesDir.path, 0o700) != 0 && errno != EEXIST {
            throw RewindError.ioError("mkdir updates errno=\(errno)")
        }
        _ = chmod(updatesDir.path, 0o700)
        return updatesDir
    }

    private func setFailure(_ notice: FailureNotice) {
        activeFailureNotice = notice
        state = .failed(notice.message(in: language))
    }

    public static nonisolated func defaultIsInstallLocationWritable(_ installedAppURL: URL) -> Bool {
        let parentPath = installedAppURL.deletingLastPathComponent().path
        guard Darwin.access(parentPath, W_OK) == 0 else { return false }
        if FileManager.default.fileExists(atPath: installedAppURL.path) {
            return Darwin.access(installedAppURL.path, W_OK) == 0
        }
        return true
    }

    private static nonisolated func findStagedAppBundle(in unpackedDir: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: unpackedDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return nil
        }
        for entry in entries where entry.pathExtension.lowercased() == "app" {
            var st = stat()
            guard lstat(entry.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            return entry.standardizedFileURL
        }
        return nil
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
    set -eu
    WAIT_PID="$1"
    INSTALLED_APP="$2"
    STAGED_APP="$3"
    ROLLBACK_APP="$4"
    STAGING_DIR="$5"
    RELAUNCH_CMD="$6"

    elapsed=0
    while kill -0 "$WAIT_PID" 2>/dev/null; do
      if [ "$elapsed" -ge 150 ]; then
        exit 1
      fi
      /bin/sleep 0.1
      elapsed=$((elapsed + 1))
    done

    /bin/rm -rf "$ROLLBACK_APP"
    if [ -e "$INSTALLED_APP" ]; then
      /bin/mv "$INSTALLED_APP" "$ROLLBACK_APP"
    fi

    if /bin/mv "$STAGED_APP" "$INSTALLED_APP"; then
      /usr/bin/xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
      /bin/rm -rf "$ROLLBACK_APP" "$STAGING_DIR"
      if [ -n "$RELAUNCH_CMD" ]; then
        "$RELAUNCH_CMD" "$INSTALLED_APP" --args --restarted-after-update >/dev/null 2>&1 || true
      fi
    else
      if [ -e "$ROLLBACK_APP" ] && [ ! -e "$INSTALLED_APP" ]; then
        /bin/mv "$ROLLBACK_APP" "$INSTALLED_APP" || true
      fi
      exit 1
    fi
    """
}

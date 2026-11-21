// SPDX-License-Identifier: MIT

import CodingRewindCore
@testable import CodingRewindApp
import Foundation
import Testing

struct DeveloperCredentialsResolverTests {
    private static let allowFixtureExecutable: DeveloperCredentialsResolver.ExecutableValidator = { _ in true }

    @Test func ordinaryInstallationPreservesExistingCredentialResolution() throws {
        let environment = ["PATH": "/usr/bin:/bin"]
        #expect(try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: nil, environment: environment
        ) == environment)
    }

    @Test func explicitTokenTakesPriorityOverDeveloperConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment.merging([
            StoragePaths.memosTokenEnvironmentKey: "explicit-fixture-token"
        ]) { _, new in new }
        #expect(try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: fixture.root.appendingPathComponent("missing.plist"), environment: environment
        ) == environment)
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
    }

    @Test func qaInstallationDoesNotReadPersonalDeveloperCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment.merging([StoragePaths.qaEnvironmentKey: "1"]) { _, new in new }
        #expect(try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: fixture.configurationURL, environment: environment
        ) == environment)
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
    }

    @Test func developerTokenIsReadIntoOnlyTheReturnedEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try Data(contentsOf: fixture.configurationURL)
        let resolved = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: fixture.configurationURL,
            environment: fixture.environment,
            executableValidator: Self.allowFixtureExecutable
        )
        #expect(resolved[StoragePaths.memosTokenEnvironmentKey] == "fixture-token-only")
        #expect(resolved["FIXTURE_KEEP"] == "preserved")
        #expect(fixture.environment[StoragePaths.memosTokenEnvironmentKey] == nil)
        #expect(try Data(contentsOf: fixture.configurationURL) == configuration)
        #expect(try String(contentsOf: fixture.argumentsURL, encoding: .utf8) ==
            "read\n--no-newline\nop://fixture-vault/fixture-item/password\n")
    }

    @Test func failedAuthenticationCannotReturnAKeychainFallbackEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment["FAKE_OP_STATUS"] = "23"
        #expect(throws: DeveloperCredentialsResolver.Failure.credentialReadFailed) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: fixture.configurationURL,
                environment: environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }
    }

    @Test(arguments: ["", " \t\r\n ", "op://fixture-vault/fixture-item/password", " \nop://fixture-vault/fixture-item/password", "token with spaces"])
    func invalidDeveloperCredentialCannotReturnAKeychainFallbackEnvironment(token: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment["FAKE_OP_RESULT"] = token
        #expect(throws: DeveloperCredentialsResolver.Failure.credentialReadFailed) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: fixture.configurationURL,
                environment: environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }
    }

    @Test func invalidReferenceDoesNotInvokeCredentialTool() throws {
        let fixture = try Fixture(reference: "not-a-secret-reference")
        defer { fixture.remove() }
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: fixture.configurationURL,
                environment: fixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
    }

    @Test func bundledConfigurationMigratesToExternalFileWith0600PermissionsAndSupportsReleaseFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalURL = fixture.root.appendingPathComponent("AppSupport/DeveloperCredentials.plist")

        let resolved = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: fixture.configurationURL,
            externalConfigurationURL: externalURL,
            environment: fixture.environment,
            executableValidator: Self.allowFixtureExecutable
        )
        #expect(resolved[StoragePaths.memosTokenEnvironmentKey] == "fixture-token-only")
        #expect(FileManager.default.fileExists(atPath: externalURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: externalURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        try FileManager.default.removeItem(at: fixture.argumentsURL)
        let fallbackResolved = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: nil,
            externalConfigurationURL: externalURL,
            environment: fixture.environment,
            executableValidator: Self.allowFixtureExecutable
        )
        #expect(fallbackResolved[StoragePaths.memosTokenEnvironmentKey] == "fixture-token-only")
        #expect(try String(contentsOf: fixture.argumentsURL, encoding: .utf8) ==
            "read\n--no-newline\nop://fixture-vault/fixture-item/password\n")
    }

    @Test func rotatedBundledConfigurationRefreshesExternalConfigurationAndQABypassesBoth() throws {
        let initialFixture = try Fixture(reference: "op://fixture-vault/old-item/password")
        defer { initialFixture.remove() }
        let externalURL = initialFixture.root.appendingPathComponent("AppSupport/DeveloperCredentials.plist")

        _ = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: initialFixture.configurationURL,
            externalConfigurationURL: externalURL,
            environment: initialFixture.environment,
            executableValidator: Self.allowFixtureExecutable
        )

        let rotatedConfigURL = initialFixture.root.appendingPathComponent("RotatedDeveloperCredentials.plist")
        let executablePath = initialFixture.root.appendingPathComponent("fake op").path
        let rotatedData = try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://fixture-vault/rotated-item/password",
            "op_executable": executablePath
        ], format: .xml, options: 0)
        try rotatedData.write(to: rotatedConfigURL)

        var rotatedEnv = initialFixture.environment
        rotatedEnv["FAKE_OP_RESULT"] = "rotated-fixture-token"
        let refreshed = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: rotatedConfigURL,
            externalConfigurationURL: externalURL,
            environment: rotatedEnv,
            executableValidator: Self.allowFixtureExecutable
        )
        #expect(refreshed[StoragePaths.memosTokenEnvironmentKey] == "rotated-fixture-token")
        #expect(try String(contentsOf: initialFixture.argumentsURL, encoding: .utf8) ==
            "read\n--no-newline\nop://fixture-vault/rotated-item/password\n")
        #expect(try Data(contentsOf: externalURL) == rotatedData)

        try FileManager.default.removeItem(at: initialFixture.argumentsURL)
        let qaEnv = rotatedEnv.merging([StoragePaths.qaEnvironmentKey: "1"]) { _, new in new }
        #expect(try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: rotatedConfigURL,
            externalConfigurationURL: externalURL,
            environment: qaEnv,
            executableValidator: Self.allowFixtureExecutable
        ) == qaEnv)
        #expect(!FileManager.default.fileExists(atPath: initialFixture.argumentsURL.path))
    }

    @Test func malformedBundledConfigurationDoesNotOverwriteValidExternalConfiguration() throws {
        let validFixture = try Fixture(reference: "op://fixture-vault/valid-item/password")
        defer { validFixture.remove() }
        let externalURL = validFixture.root.appendingPathComponent("AppSupport/DeveloperCredentials.plist")

        _ = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: validFixture.configurationURL,
            externalConfigurationURL: externalURL,
            environment: validFixture.environment,
            executableValidator: Self.allowFixtureExecutable
        )
        let preservedExternalData = try Data(contentsOf: externalURL)

        let malformedBundledURL = validFixture.root.appendingPathComponent("MalformedBundled.plist")
        try Data("not-a-valid-plist".utf8).write(to: malformedBundledURL)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: malformedBundledURL,
                externalConfigurationURL: externalURL,
                environment: validFixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }
        #expect(try Data(contentsOf: externalURL) == preservedExternalData)

        let invalidRefBundledURL = validFixture.root.appendingPathComponent("InvalidRefBundled.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "invalid-ref",
            "op_executable": validFixture.root.appendingPathComponent("fake op").path
        ], format: .xml, options: 0).write(to: invalidRefBundledURL)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: invalidRefBundledURL,
                externalConfigurationURL: externalURL,
                environment: validFixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }
        #expect(try Data(contentsOf: externalURL) == preservedExternalData)
    }

    @Test func hungCredentialToolTimesOutAndTerminatesChildProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pidFileURL = fixture.root.appendingPathComponent("hung-op.pid")
        let hungOpURL = fixture.root.appendingPathComponent("hung-op")
        try """
        #!/bin/sh
        printf '%s' "$$" > "\(pidFileURL.path)"
        sleep 30
        """.write(to: hungOpURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hungOpURL.path)

        let hungConfigURL = fixture.root.appendingPathComponent("HungCredentials.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://fixture-vault/fixture-item/password",
            "op_executable": hungOpURL.path
        ], format: .xml, options: 0).write(to: hungConfigURL)

        #expect(throws: DeveloperCredentialsResolver.Failure.credentialReadTimedOut) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: hungConfigURL,
                environment: fixture.environment,
                timeoutSeconds: 0.15,
                executableValidator: Self.allowFixtureExecutable
            )
        }
        #expect(DeveloperCredentialsResolver.Failure.credentialReadTimedOut.localizedDescription(in: .en).contains("Timed out"))
        #expect(DeveloperCredentialsResolver.Failure.credentialReadTimedOut.localizedDescription(in: .zhHans).contains("超时"))

        if let pidString = try? String(contentsOf: pidFileURL, encoding: .utf8),
           let childPID = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            usleep(50_000)
            #expect(kill(childPID, 0) != 0)
        }
    }

    @MainActor
    @Test func bootstrapFailureDispositionStartsSilentlyForBackgroundOrExternalFallbackAndRespectsLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dataDir = fixture.root.appendingPathComponent("Data", isDirectory: true)
        let configDir = fixture.root.appendingPathComponent("Config", isDirectory: true)
        let externalURL = dataDir.appendingPathComponent("DeveloperCredentials.plist")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data(contentsOf: fixture.configurationURL).write(to: externalURL)

        let env = [
            StoragePaths.dataDirEnvironmentKey: dataDir.path,
            StoragePaths.antigravityConfigEnvironmentKey: configDir.path
        ]
        #expect(DeveloperCredentialsResolver.hasBundledConfiguration(at: fixture.configurationURL))
        #expect(!DeveloperCredentialsResolver.hasBundledConfiguration(at: nil))
        #expect(DeveloperCredentialsResolver.configurationSource(
            configurationURL: fixture.configurationURL,
            externalConfigurationURL: externalURL,
            environment: env
        ) == .bundled)
        #expect(DeveloperCredentialsResolver.configurationSource(
            configurationURL: nil,
            externalConfigurationURL: externalURL,
            environment: env
        ) == .externalFallback)
        #expect(DeveloperCredentialsResolver.configurationSource(
            configurationURL: fixture.root.appendingPathComponent("NonExistentBundled.plist"),
            externalConfigurationURL: externalURL,
            environment: env
        ) == .externalFallback)
        #expect(DeveloperCredentialsResolver.configurationSource(
            configurationURL: fixture.root.appendingPathComponent("NonExistentBundled.plist"),
            externalConfigurationURL: nil,
            environment: env
        ) == .none)

        let interactiveBundledEn = CodingRewindAppDelegate.evaluateBootstrapFailure(
            error: DeveloperCredentialsResolver.Failure.credentialReadFailed,
            environment: env,
            launchContext: LaunchContext(reason: .interactive),
            bundledConfigurationURL: fixture.configurationURL,
            language: .en
        )
        #expect(interactiveBundledEn == .terminateWithModalAlert(
            title: "Coding Rewind Could Not Start",
            message: "Could not read developer credentials from 1Password. Unlock 1Password and reopen Coding Rewind."
        ))

        for silentReason in [LaunchContext.Reason.systemLoginItem, .relaunchedAfterUpdate, .commandLineBackground] {
            let disposition = CodingRewindAppDelegate.evaluateBootstrapFailure(
                error: DeveloperCredentialsResolver.Failure.credentialReadFailed,
                environment: env,
                launchContext: LaunchContext(reason: silentReason),
                bundledConfigurationURL: fixture.configurationURL,
                language: .en
            )
            if case .startDegraded(let degradedEnv, let warning) = disposition {
                #expect(degradedEnv[KeychainTokenStore.disableKeychainFallbackEnvironmentKey] == "1")
                #expect(warning.contains("1Password"))
            } else {
                Issue.record("Expected silent degraded startup for \(silentReason), got \(disposition)")
            }
        }

        let interactiveExternalFallback = CodingRewindAppDelegate.evaluateBootstrapFailure(
            error: DeveloperCredentialsResolver.Failure.credentialReadTimedOut,
            environment: env,
            launchContext: LaunchContext(reason: .interactive),
            bundledConfigurationURL: nil,
            language: .zhHans
        )
        guard case .startDegraded(let degradedEnv, let warning) = interactiveExternalFallback else {
            Issue.record("Expected degraded startup when bundled plist is absent, got \(interactiveExternalFallback)")
            return
        }
        #expect(degradedEnv[KeychainTokenStore.disableKeychainFallbackEnvironmentKey] == "1")
        #expect(warning.contains("超时"))

        struct IdleCapturer: SelectionCapturing {
            func captureFrontmostSelection() async throws -> CapturedSelection {
                throw RewindError.emptySelection
            }
        }
        let paths = try StoragePaths.resolve(environment: degradedEnv)
        let coord = try AppCoordinator(paths: paths, environment: degradedEnv, capturer: IdleCapturer(), language: .zhHans)
        coord.recordStartupWarning(warning)
        #expect(coord.isErrorBanner)
        #expect(coord.bannerMessage == warning)
        #expect(KeychainTokenStore.resolveToken(environment: degradedEnv) == nil)
    }

    @Test func externalCredentialsEnforceNoFollowStrict0600SingleLinkDYLDStrippingAndSignedOpTrust() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: fixture.configurationURL,
                environment: fixture.environment
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path), "unsigned op_executable must not execute")
        #expect(!DeveloperCredentialsResolver.isTrustedOnePasswordCLI(URL(fileURLWithPath: "/bin/sh")))

        let hostOp = URL(fileURLWithPath: "/opt/homebrew/bin/op").resolvingSymlinksInPath()
        if FileManager.default.isExecutableFile(atPath: hostOp.path) {
            #expect(DeveloperCredentialsResolver.isTrustedOnePasswordCLI(hostOp), "AgileBits 1Password CLI signature must be accepted")
        }

        let appSupportDir = fixture.root.appendingPathComponent("StrictData", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let externalURL = appSupportDir.appendingPathComponent("DeveloperCredentials.plist")
        let plistBytes = try Data(contentsOf: fixture.configurationURL)

        try AtomicFile.writeData(plistBytes, to: externalURL, permissions: 0o644)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: nil,
                externalConfigurationURL: externalURL,
                environment: fixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }

        try FileManager.default.removeItem(at: externalURL)
        let realPrivateCopy = fixture.root.appendingPathComponent("RealPrivate.plist")
        try AtomicFile.writeData(plistBytes, to: realPrivateCopy, permissions: 0o600)
        try FileManager.default.createSymbolicLink(at: externalURL, withDestinationURL: realPrivateCopy)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: nil,
                externalConfigurationURL: externalURL,
                environment: fixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }

        try FileManager.default.removeItem(at: externalURL)
        try FileManager.default.linkItem(at: realPrivateCopy, to: externalURL)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: nil,
                externalConfigurationURL: externalURL,
                environment: fixture.environment,
                executableValidator: Self.allowFixtureExecutable
            )
        }

        try FileManager.default.removeItem(at: externalURL)
        #expect(mkfifo(externalURL.path, 0o600) == 0)
        #expect(throws: DeveloperCredentialsResolver.Failure.invalidConfiguration) {
            try DeveloperCredentialsResolver.resolveEnvironment(
                configurationURL: nil,
                externalConfigurationURL: externalURL,
                environment: fixture.environment,
                timeoutSeconds: 0.2,
                executableValidator: Self.allowFixtureExecutable
            )
        }
        try FileManager.default.removeItem(at: externalURL)

        let envDumpURL = fixture.root.appendingPathComponent("child-dyld.txt")
        let envProbeOp = fixture.root.appendingPathComponent("probe-op")
        try AtomicFile.writeUTF8(
            """
            #!/bin/sh
            printf '%s' "${DYLD_INSERT_LIBRARIES:-NONE}" > "\(envDumpURL.path)"
            printf 'clean-token'
            """,
            to: envProbeOp,
            permissions: 0o755
        )
        let probePlist = try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://fixture-vault/fixture-item/password",
            "op_executable": envProbeOp.path
        ], format: .xml, options: 0)
        try AtomicFile.writeData(probePlist, to: externalURL, permissions: 0o600)
        var pollutedEnv = fixture.environment
        pollutedEnv["DYLD_INSERT_LIBRARIES"] = fixture.root.appendingPathComponent("evil.dylib").path
        let cleanOut = try DeveloperCredentialsResolver.resolveEnvironment(
            configurationURL: nil,
            externalConfigurationURL: externalURL,
            environment: pollutedEnv,
            executableValidator: Self.allowFixtureExecutable
        )
        #expect(cleanOut[StoragePaths.memosTokenEnvironmentKey] == "clean-token")
        #expect(try String(contentsOf: envDumpURL, encoding: .utf8) == "NONE")
    }

    private struct Fixture {
        let root: URL
        let configurationURL: URL
        let argumentsURL: URL
        let environment: [String: String]

        init(reference: String = "op://fixture-vault/fixture-item/password") throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/developer-credentials-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            configurationURL = root.appendingPathComponent("DeveloperCredentials.plist")
            argumentsURL = root.appendingPathComponent("arguments.txt")
            let executableURL = root.appendingPathComponent("fake op")
            try """
            #!/bin/sh
            printf '%s\\n' "$@" > "$FAKE_OP_ARGUMENTS"
            printf '%s' "$FAKE_OP_RESULT"
            printf '%s' 'private-diagnostic-fixture' >&2
            exit "${FAKE_OP_STATUS:-0}"
            """.write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            try PropertyListSerialization.data(fromPropertyList: [
                "token_reference": reference,
                "op_executable": executableURL.path
            ], format: .xml, options: 0).write(to: configurationURL)
            environment = [
                "FIXTURE_KEEP": "preserved",
                "PATH": "/usr/bin:/bin",
                "FAKE_OP_ARGUMENTS": argumentsURL.path,
                "FAKE_OP_RESULT": "fixture-token-only"
            ]
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

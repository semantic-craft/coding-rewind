// SPDX-License-Identifier: MIT

import CodingRewindCore
@testable import CodingRewindApp
import Foundation
import Testing

struct DeveloperCredentialsBootstrapTests {
    @Test func ordinaryInstallationPreservesExistingCredentialResolution() throws {
        let environment = ["PATH": "/usr/bin:/bin"]
        #expect(try DeveloperCredentialsBootstrap.resolveEnvironment(
            configurationURL: nil, environment: environment
        ) == environment)
    }

    @Test func explicitTokenTakesPriorityOverDeveloperConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment.merging([
            StoragePaths.memosTokenEnvironmentKey: "explicit-fixture-token"
        ]) { _, new in new }
        #expect(try DeveloperCredentialsBootstrap.resolveEnvironment(
            configurationURL: fixture.root.appendingPathComponent("missing.plist"), environment: environment
        ) == environment)
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
    }

    @Test func qaInstallationDoesNotReadPersonalDeveloperCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment.merging([StoragePaths.qaEnvironmentKey: "1"]) { _, new in new }
        #expect(try DeveloperCredentialsBootstrap.resolveEnvironment(
            configurationURL: fixture.configurationURL, environment: environment
        ) == environment)
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
    }

    @Test func developerTokenIsReadIntoOnlyTheReturnedEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try Data(contentsOf: fixture.configurationURL)
        let resolved = try DeveloperCredentialsBootstrap.resolveEnvironment(
            configurationURL: fixture.configurationURL, environment: fixture.environment
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
        #expect(throws: DeveloperCredentialsBootstrap.Failure.credentialReadFailed) {
            try DeveloperCredentialsBootstrap.resolveEnvironment(
                configurationURL: fixture.configurationURL, environment: environment
            )
        }
    }

    @Test(arguments: ["", " \t\r\n ", "op://fixture-vault/fixture-item/password", " \nop://fixture-vault/fixture-item/password", "token with spaces"])
    func invalidDeveloperCredentialCannotReturnAKeychainFallbackEnvironment(token: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment["FAKE_OP_RESULT"] = token
        #expect(throws: DeveloperCredentialsBootstrap.Failure.credentialReadFailed) {
            try DeveloperCredentialsBootstrap.resolveEnvironment(
                configurationURL: fixture.configurationURL, environment: environment
            )
        }
    }

    @Test func invalidReferenceDoesNotInvokeCredentialTool() throws {
        let fixture = try Fixture(reference: "not-a-secret-reference")
        defer { fixture.remove() }
        #expect(throws: DeveloperCredentialsBootstrap.Failure.invalidConfiguration) {
            try DeveloperCredentialsBootstrap.resolveEnvironment(
                configurationURL: fixture.configurationURL, environment: fixture.environment
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
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

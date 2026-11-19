// SPDX-License-Identifier: MIT

import CodingRewindCore
import Darwin
import Foundation
import os
import Testing

@Suite("DSH plugin staging, discovery, and repair diagnostics")
struct DSHIntegrationTests {
    private func makeTestDir(_ prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSourcePlugin(at dir: URL, version: String = DSHIntegration.pluginVersion, extraLibMarker: String = "v1") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("lib", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("test", isDirectory: true), withIntermediateDirectories: true)
        let pkg = """
        {
          "name": "\(DSHIntegration.pluginName)",
          "version": "\(version)",
          "type": "module",
          "main": "lib/index.js"
        }
        """
        try AtomicFile.writeUTF8(pkg, to: dir.appendingPathComponent("package.json"), permissions: 0o644)
        try AtomicFile.writeUTF8("client: ./client.js\n", to: dir.appendingPathComponent("cordis.patch.yml"), permissions: 0o644)
        try AtomicFile.writeUTF8("export default function apply() {}\n", to: dir.appendingPathComponent("client.js"), permissions: 0o644)
        try AtomicFile.writeUTF8("export const marker = '\(extraLibMarker)';\n", to: dir.appendingPathComponent("lib/index.js"), permissions: 0o644)
        try AtomicFile.writeUTF8("export const handoff = true;\n", to: dir.appendingPathComponent("lib/handoff.js"), permissions: 0o644)
        try AtomicFile.writeUTF8("should-not-stage", to: dir.appendingPathComponent("test/plugin.test.mjs"), permissions: 0o644)
    }

    private func makeFakeDSHBinary(at url: URL) throws {
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: url, permissions: 0o755)
    }

    @Test("installOrRepair stages plugin atomically, writes explicit 0600 runtime-config.json, strips CODING_REWIND_* env, registers bundle, and converges repairReasons to empty")
    func installRepairStagesRegistersAndVerifies() throws {
        let root = try makeTestDir("dsh-install")
        defer { try? FileManager.default.removeItem(at: root) }

        let dataDir = root.appendingPathComponent("Data", isDirectory: true)
        let dshHome = root.appendingPathComponent("DSHHome", isDirectory: true)
        let sourcePlugin = root.appendingPathComponent("SourcePlugin", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin/dsh", isDirectory: false)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSourcePlugin(at: sourcePlugin)
        try makeFakeDSHBinary(at: fakeBin)

        #expect(DSHIntegration.repairReasons(
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome,
            dshBinaryURL: fakeBin
        ) == [.notInstalled])

        let capturedInvocation = OSAllocatedUnfairLock<(args: [String], env: [String: String])?>(initialState: nil)
        let profileDir = DSHIntegration.desktopProfileDirectoryURL(in: dshHome)

        let stagedDir = try DSHIntegration.installOrRepair(
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome,
            sourcePluginDirectoryURL: sourcePlugin,
            dshBinaryURL: fakeBin,
            language: .zhHans,
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": root.path,
                "CODING_REWIND_QA": "1",
                "CODING_REWIND_MEMOS_TOKEN": "secret-should-not-leak",
                "CODING_REWIND_DATA_DIR": dataDir.path
            ],
            commandRunner: { executableURL, arguments, environment in
                #expect(executableURL == fakeBin)
                capturedInvocation.withLock { $0 = (arguments, environment) }

                try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
                let initialProfile: [String: Any] = [
                    "name": "dsh-profile-desktop",
                    "private": true,
                    "dependencies": [
                        DSHIntegration.pluginName: arguments.last ?? ""
                    ],
                    "dsh": [
                        "profile": [
                            "bundles": ["@deepseek-ai/dsh-base"]
                        ]
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: initialProfile, options: [.prettyPrinted])
                try AtomicFile.writeData(data, to: profileDir.appendingPathComponent("package.json"), permissions: 0o600)

                let pnpmTarget = profileDir
                    .appendingPathComponent("node_modules/.pnpm/\(DSHIntegration.pluginName)@file/node_modules/\(DSHIntegration.pluginName)", isDirectory: true)
                let stagedPath = String((arguments.last ?? "").dropFirst("file:".count))
                try FileManager.default.createDirectory(at: pnpmTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: pnpmTarget)
                try? FileManager.default.removeItem(at: pnpmTarget.appendingPathComponent("runtime-config.json"))
                let installedLink = profileDir
                    .appendingPathComponent("node_modules", isDirectory: true)
                    .appendingPathComponent(DSHIntegration.pluginName, isDirectory: true)
                try FileManager.default.createSymbolicLink(at: installedLink, withDestinationURL: pnpmTarget)
                return DSHCommandResult(exitCode: 0, output: "installed")
            }
        )

        let invocation = try #require(capturedInvocation.withLock { $0 })
        #expect(invocation.args == [
            "plugin",
            "--profile",
            "desktop",
            "add",
            "--config.strict-dep-builds=false",
            "file:\(stagedDir.path)"
        ])
        #expect(invocation.env["DSH_HOME"] == dshHome.standardizedFileURL.path)
        #expect(!invocation.env.keys.contains { $0.hasPrefix("CODING_REWIND_") })

        #expect(stagedDir == DSHIntegration.stagedPluginDirectoryURL(in: dataDir))
        #expect(!FileManager.default.fileExists(atPath: stagedDir.appendingPathComponent("test/plugin.test.mjs").path))

        let runtimeConfigURL = stagedDir.appendingPathComponent("runtime-config.json")
        let runtimeConfigAttrs = try FileManager.default.attributesOfItem(atPath: runtimeConfigURL.path)
        #expect(runtimeConfigAttrs[.posixPermissions] as? Int == 0o600)
        let runtimeConfigObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: runtimeConfigURL)) as? [String: String]
        )
        #expect(runtimeConfigObj["dataDir"] == dataDir.standardizedFileURL.path)

        let installedRuntimeConfigURL = profileDir
            .appendingPathComponent("node_modules/\(DSHIntegration.pluginName)/runtime-config.json")
        let installedRuntimeConfigObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: installedRuntimeConfigURL)) as? [String: String]
        )
        #expect(installedRuntimeConfigObj["dataDir"] == dataDir.standardizedFileURL.path)

        let profileObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: profileDir.appendingPathComponent("package.json"))) as? [String: Any]
        )
        let dshObj = try #require(profileObj["dsh"] as? [String: Any])
        let profile = try #require(dshObj["profile"] as? [String: Any])
        let bundles = try #require(profile["bundles"] as? [String])
        #expect(bundles == ["@deepseek-ai/dsh-base", DSHIntegration.pluginName])

        #expect(DSHIntegration.repairReasons(
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome,
            dshBinaryURL: fakeBin
        ).isEmpty)

        try makeSourcePlugin(at: sourcePlugin, extraLibMarker: "v2")
        try DSHIntegration.refreshInstalledPluginIfPresent(
            sourcePluginDirectoryURL: sourcePlugin,
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome
        )
        let refreshedStaged = try String(contentsOf: stagedDir.appendingPathComponent("lib/index.js"), encoding: .utf8)
        let refreshedInstalled = try String(
            contentsOf: profileDir.appendingPathComponent("node_modules/\(DSHIntegration.pluginName)/lib/index.js"),
            encoding: .utf8
        )
        #expect(refreshedStaged.contains("v2"))
        #expect(refreshedInstalled.contains("v2"))
    }

    @Test("installOrRepair refuses transient .build/ and temporary system paths")
    func refusesTransientPaths() throws {
        let root = try makeTestDir("dsh-refuse")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourcePlugin = root.appendingPathComponent("SourcePlugin", isDirectory: true)
        let fakeBin = root.appendingPathComponent("dsh", isDirectory: false)
        try makeSourcePlugin(at: sourcePlugin)
        try makeFakeDSHBinary(at: fakeBin)

        let buildData = root.appendingPathComponent(".build/transient-data", isDirectory: true)
        let validDSHHome = root.appendingPathComponent("DSHHome", isDirectory: true)
        #expect(DSHIntegration.isDisallowedInstallPath(buildData))
        #expect(throws: RewindError.self) {
            _ = try DSHIntegration.installOrRepair(
                dataDirectoryURL: buildData,
                dshHomeURL: validDSHHome,
                sourcePluginDirectoryURL: sourcePlugin,
                dshBinaryURL: fakeBin,
                commandRunner: { _, _, _ in
                    Issue.record("Runner must not execute for disallowed .build/ path")
                    return DSHCommandResult(exitCode: 0, output: "")
                }
            )
        }

        let tmpCandidate = URL(fileURLWithPath: "/").appendingPathComponent("tmp").appendingPathComponent("dsh-blocked")
        #expect(DSHIntegration.isDisallowedInstallPath(tmpCandidate))
        #expect(throws: RewindError.self) {
            _ = try DSHIntegration.installOrRepair(
                dataDirectoryURL: tmpCandidate,
                dshHomeURL: validDSHHome,
                sourcePluginDirectoryURL: sourcePlugin,
                dshBinaryURL: fakeBin,
                commandRunner: { _, _, _ in
                    Issue.record("Runner must not execute for disallowed temp path")
                    return DSHCommandResult(exitCode: 0, output: "")
                }
            )
        }
    }

    @Test("repairReasons diagnoses missing binary, outdated version, mismatched dataDir, and unregistered desktop profile")
    func repairReasonDiagnostics() throws {
        let root = try makeTestDir("dsh-reasons")
        defer { try? FileManager.default.removeItem(at: root) }

        let dataDir = root.appendingPathComponent("Data", isDirectory: true)
        let dshHome = root.appendingPathComponent("DSHHome", isDirectory: true)
        let stagedDir = DSHIntegration.stagedPluginDirectoryURL(in: dataDir)
        let profileDir = DSHIntegration.desktopProfileDirectoryURL(in: dshHome)
        let installedDir = profileDir.appendingPathComponent("node_modules/\(DSHIntegration.pluginName)", isDirectory: true)
        let fakeBin = root.appendingPathComponent("dsh", isDirectory: false)
        try makeFakeDSHBinary(at: fakeBin)

        try makeSourcePlugin(at: stagedDir, version: "0.0.1")
        try makeSourcePlugin(at: installedDir, version: DSHIntegration.pluginVersion)
        try AtomicFile.writeUTF8("{\"dataDir\":\"/wrong/dir\"}", to: stagedDir.appendingPathComponent("runtime-config.json"))
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try AtomicFile.writeUTF8(
            "{\"name\":\"dsh-profile-desktop\",\"dsh\":{\"profile\":{\"bundles\":[\"@deepseek-ai/dsh-base\"]}}}",
            to: profileDir.appendingPathComponent("package.json")
        )

        let reasons = DSHIntegration.repairReasons(
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome,
            dshBinaryURL: nil
        )
        #expect(reasons.contains(.missingCLIBinary))
        #expect(reasons.contains(.stagedPluginMissingOrOutdated))
        #expect(reasons.contains(.invalidRuntimeConfig))
        #expect(reasons.contains(.pluginNotRegisteredInProfile))

        try FileManager.default.removeItem(at: profileDir.appendingPathComponent("package.json"))
        let missingProfileReasons = DSHIntegration.repairReasons(
            dataDirectoryURL: dataDir,
            dshHomeURL: dshHome,
            dshBinaryURL: fakeBin
        )
        #expect(missingProfileReasons.contains(.missingProfilePackage))
    }

    @Test("resolveDSHBinaryURL honors CODING_REWIND_DSH_BIN strictly and falls back to app bundle or ~/.local/bin/dsh")
    func binaryDiscoveryPrecedence() throws {
        let root = try makeTestDir("dsh-bin")
        defer { try? FileManager.default.removeItem(at: root) }

        let envBin = root.appendingPathComponent("env/dsh")
        let appBundle = root.appendingPathComponent("DeepSeek Harness.app", isDirectory: true)
        let appBin = appBundle.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh")
        let fakeHome = root.appendingPathComponent("Home", isDirectory: true)
        let localBin = fakeHome.appendingPathComponent(".local/bin/dsh")

        for url in [envBin, appBin, localBin] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeFakeDSHBinary(at: url)
        }

        let resolvedEnv = DSHIntegration.resolveDSHBinaryURL(
            environment: [DSHIntegration.binaryEnvironmentKey: envBin.path],
            applicationURL: appBundle,
            homeDirectory: fakeHome
        )
        #expect(resolvedEnv == envBin)

        let rejectedRelative = DSHIntegration.resolveDSHBinaryURL(
            environment: [DSHIntegration.binaryEnvironmentKey: "relative/dsh"],
            applicationURL: appBundle,
            homeDirectory: fakeHome
        )
        #expect(rejectedRelative == nil)

        let rejectedMissing = DSHIntegration.resolveDSHBinaryURL(
            environment: [DSHIntegration.binaryEnvironmentKey: root.appendingPathComponent("missing").path],
            applicationURL: appBundle,
            homeDirectory: fakeHome
        )
        #expect(rejectedMissing == nil)

        let resolvedApp = DSHIntegration.resolveDSHBinaryURL(
            environment: [:],
            applicationURL: appBundle,
            homeDirectory: fakeHome
        )
        #expect(resolvedApp == appBin)
    }

    @Test("installOrRepair tolerates unrelated post-pnpm reconcile failure when coding-rewind-dsh installed cleanly, but rejects explicit rejections or missing installs")
    func unrelatedReconcileFailureToleranceAndGuards() throws {
        let root = try makeTestDir("dsh-reconcile")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourcePlugin = root.appendingPathComponent("SourcePlugin", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin/dsh", isDirectory: false)
        try FileManager.default.createDirectory(at: fakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSourcePlugin(at: sourcePlugin, extraLibMarker: "reconcile-check")
        try makeFakeDSHBinary(at: fakeBin)

        @Sendable func simulatePnpmInstall(profileDir: URL, stagedPath: String) throws {
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            let profile: [String: Any] = [
                "name": "dsh-profile-desktop",
                "private": true,
                "dependencies": [
                    "broken-dangling-link": "link:/nonexistent/plugin",
                    DSHIntegration.pluginName: "file:\(stagedPath)"
                ],
                "dsh": [
                    "profile": [
                        "bundles": ["@deepseek-ai/dsh-base", "broken-dangling-link"]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted])
            try AtomicFile.writeData(data, to: profileDir.appendingPathComponent("package.json"), permissions: 0o600)

            let pnpmTarget = profileDir
                .appendingPathComponent("node_modules/.pnpm/\(DSHIntegration.pluginName)@file/node_modules/\(DSHIntegration.pluginName)", isDirectory: true)
            try FileManager.default.createDirectory(at: pnpmTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: pnpmTarget)
            try? FileManager.default.removeItem(at: pnpmTarget.appendingPathComponent("runtime-config.json"))
            let installedLink = profileDir
                .appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(DSHIntegration.pluginName, isDirectory: true)
            try FileManager.default.createSymbolicLink(at: installedLink, withDestinationURL: pnpmTarget)
        }

        let okDataDir = root.appendingPathComponent("OkData", isDirectory: true)
        let okDSHHome = root.appendingPathComponent("OkDSHHome", isDirectory: true)
        try FileManager.default.createDirectory(at: okDataDir, withIntermediateDirectories: true)
        let okProfileDir = DSHIntegration.desktopProfileDirectoryURL(in: okDSHHome)

        let stagedDir = try DSHIntegration.installOrRepair(
            dataDirectoryURL: okDataDir,
            dshHomeURL: okDSHHome,
            sourcePluginDirectoryURL: sourcePlugin,
            dshBinaryURL: fakeBin,
            commandRunner: { _, arguments, _ in
                let stagedPath = String((arguments.last ?? "").dropFirst("file:".count))
                try simulatePnpmInstall(profileDir: okProfileDir, stagedPath: stagedPath)
                return DSHCommandResult(
                    exitCode: 1,
                    output: "Error: cannot resolve profile bundle \"broken-dangling-link\""
                )
            }
        )

        #expect(stagedDir == DSHIntegration.stagedPluginDirectoryURL(in: okDataDir))
        let profileObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: okProfileDir.appendingPathComponent("package.json"))) as? [String: Any]
        )
        let dshObj = try #require(profileObj["dsh"] as? [String: Any])
        let profile = try #require(dshObj["profile"] as? [String: Any])
        let bundles = try #require(profile["bundles"] as? [String])
        #expect(bundles.contains(DSHIntegration.pluginName))

        let installedRuntimeConfigURL = okProfileDir
            .appendingPathComponent("node_modules/\(DSHIntegration.pluginName)/runtime-config.json")
        let installedRuntimeConfig = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: installedRuntimeConfigURL)) as? [String: String]
        )
        #expect(installedRuntimeConfig["dataDir"] == okDataDir.standardizedFileURL.path)
        #expect(DSHIntegration.repairReasons(
            dataDirectoryURL: okDataDir,
            dshHomeURL: okDSHHome,
            dshBinaryURL: fakeBin
        ).isEmpty)

        let rejectedDataDir = root.appendingPathComponent("RejectedData", isDirectory: true)
        let rejectedDSHHome = root.appendingPathComponent("RejectedDSHHome", isDirectory: true)
        try FileManager.default.createDirectory(at: rejectedDataDir, withIntermediateDirectories: true)
        let rejectedProfileDir = DSHIntegration.desktopProfileDirectoryURL(in: rejectedDSHHome)
        #expect(throws: RewindError.self) {
            _ = try DSHIntegration.installOrRepair(
                dataDirectoryURL: rejectedDataDir,
                dshHomeURL: rejectedDSHHome,
                sourcePluginDirectoryURL: sourcePlugin,
                dshBinaryURL: fakeBin,
                commandRunner: { _, arguments, _ in
                    let stagedPath = String((arguments.last ?? "").dropFirst("file:".count))
                    try simulatePnpmInstall(profileDir: rejectedProfileDir, stagedPath: stagedPath)
                    return DSHCommandResult(exitCode: 1, output: "Installation rejected by policy")
                }
            )
        }

        let missingDataDir = root.appendingPathComponent("MissingData", isDirectory: true)
        let missingDSHHome = root.appendingPathComponent("MissingDSHHome", isDirectory: true)
        try FileManager.default.createDirectory(at: missingDataDir, withIntermediateDirectories: true)
        let missingProfileDir = DSHIntegration.desktopProfileDirectoryURL(in: missingDSHHome)
        #expect(throws: RewindError.self) {
            _ = try DSHIntegration.installOrRepair(
                dataDirectoryURL: missingDataDir,
                dshHomeURL: missingDSHHome,
                sourcePluginDirectoryURL: sourcePlugin,
                dshBinaryURL: fakeBin,
                commandRunner: { _, arguments, _ in
                    try FileManager.default.createDirectory(at: missingProfileDir, withIntermediateDirectories: true)
                    let profile: [String: Any] = [
                        "name": "dsh-profile-desktop",
                        "dependencies": [DSHIntegration.pluginName: arguments.last ?? ""],
                        "dsh": ["profile": ["bundles": ["@deepseek-ai/dsh-base"]]]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: profile)
                    try AtomicFile.writeData(data, to: missingProfileDir.appendingPathComponent("package.json"), permissions: 0o600)
                    return DSHCommandResult(exitCode: 1, output: "pnpm install failed before linking node_modules")
                }
            )
        }
    }
}

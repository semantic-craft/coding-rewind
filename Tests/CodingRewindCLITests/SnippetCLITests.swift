// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Foundation
import Testing

@Suite("CodingRewind Single-Binary CLI Suite")
struct SnippetCLITests {
    @Test("CLIParser supports defaults, >72h windows, synthesized status, global flags anywhere, and canonical ID validation")
    func cliParserBehavior() throws {
        #expect(CLIParser.versionString == "0.4.0")

        let defaultList = try CLIParser.parse(arguments: ["coding-rewind", "list"])
        #expect(defaultList == .list(
            query: SnippetQuery(windowHours: 72, status: .active, sourcePlatform: nil, searchText: nil, limit: 50),
            dataDir: nil,
            json: false
        ))

        let allHistoryList = try CLIParser.parse(arguments: [
            "coding-rewind", "--json", "--data-dir", "/Users/shared/cr-data",
            "list", "--window", "all", "--status", "synthesized", "--source", "claude", "--limit", "200"
        ])
        #expect(allHistoryList == .list(
            query: SnippetQuery(windowHours: nil, status: .synthesized, sourcePlatform: "claude", searchText: nil, limit: 200),
            dataDir: "/Users/shared/cr-data",
            json: true
        ))

        let windowHoursSearch = try CLIParser.parse(arguments: [
            "coding-rewind", "search", "--window-hours=168", "--status=all", "--", "-flagLikeQuery"
        ])
        #expect(windowHoursSearch == .search(
            query: SnippetQuery(windowHours: 168, status: .all, sourcePlatform: nil, searchText: "-flagLikeQuery", limit: 50),
            dataDir: nil,
            json: false
        ))

        let getNoCtx = try CLIParser.parse(arguments: ["coding-rewind", "get", "memos/rw-1", "--no-context", "--json"])
        #expect(getNoCtx == .get(id: "rw-1", includeContext: false, dataDir: nil, json: true))

        for badArgs in [
            ["coding-rewind", "list", "--limit", "0"],
            ["coding-rewind", "list", "--limit", "501"],
            ["coding-rewind", "list", "--window", "invalid"],
            ["coding-rewind", "list", "--status", "bogus"],
            ["coding-rewind", "search"],
            ["coding-rewind", "get", "memos/../foo"],
            ["coding-rewind", "get", "memos/ foo"],
            ["coding-rewind", "get", ".."],
            ["coding-rewind", "archive", "memos/../foo"]
        ] {
            #expect(throws: CLIValidationError.self) {
                _ = try CLIParser.parse(arguments: badArgs)
            }
        }
    }

    @Test("CLIRunner executes list, search, get, archive, missing-snippet errors, and EX_USAGE 64 on invalid IDs")
    func cliRunnerEndToEndWithBackend() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRecords = SnippetCLIFixtures.makeSampleRecords()
        let backend = FakeSnippetBackend(records: sampleRecords)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let out1 = OutputCollector()
        let err1 = OutputCollector()
        let code1 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: out1.append,
            writeStderr: err1.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code1 == 0)
        #expect(err1.value().isEmpty)
        #expect(out1.value().contains("conversation://a216ac8b-30fc-4662-b3a6-949aee033024"))
        let defaultResult = try decoder.decode(SnippetQueryResult.self, from: Data(out1.value().utf8))
        #expect(defaultResult.snippets.map(\.id) == ["rw-recent-ready"])

        let out2 = OutputCollector()
        let code2 = await CLIRunner.run(
            arguments: ["coding-rewind", "list", "--window", "all", "--status", "all", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: out2.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(code2 == 0)
        let fullResult = try decoder.decode(SnippetQueryResult.self, from: Data(out2.value().utf8))
        #expect(fullResult.snippets.map(\.id) == ["rw-recent-ready", "rw-archived-synth", "rw-old-120h"])

        let outGetHuman = OutputCollector()
        let codeGet = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-recent-ready", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outGetHuman.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeGet == 0)
        let humanText = outGetHuman.value()
        #expect(humanText.contains("[Antigravity Session](conversation://a216ac8b-30fc-4662-b3a6-949aee033024)"))
        #expect(humanText.contains("### Conversation Context"))
        #expect(humanText.contains("#rewind/ready inside body must remain untouched!"))

        let outArchive = OutputCollector()
        let codeArchive = await CLIRunner.run(
            arguments: ["coding-rewind", "archive", "rw-recent-ready", "--data-dir", dir.path, "--json"],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: outArchive.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeArchive == 0)
        let archived = try decoder.decode(SnippetRecord.self, from: Data(outArchive.value().utf8))
        #expect(archived.status == .synthesized)
        #expect(archived.verbatimText == sampleRecords[0].verbatimText)

        let errNotFound = OutputCollector()
        let codeNotFound = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "rw-does-not-exist", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errNotFound.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeNotFound == 1)
        #expect(errNotFound.value().contains("未找到片段：rw-does-not-exist"))

        let errBadID = OutputCollector()
        let codeBadID = await CLIRunner.run(
            arguments: ["coding-rewind", "get", "memos/../foo", "--data-dir", dir.path],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: { _ in },
            writeStderr: errBadID.append,
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(codeBadID == 64)
        #expect(errBadID.value().contains("Invalid snippet id"))
    }

    @Test("Bare executablePath falls back to Bundle.main.executableURL and never resolves DeveloperCredentials.plist relative to PWD")
    func bareExecutablePathNeverReadsRelativePWDDeveloperCredentials() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let evilBundle = dir.appendingPathComponent("EvilPWD.app", isDirectory: true)
        let evilHelpers = evilBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let evilResources = evilBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let evilMarker = dir.appendingPathComponent("evil-op-ran.txt")
        let evilOp = dir.appendingPathComponent("evil-op")
        try FileManager.default.createDirectory(at: evilHelpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evilResources, withIntermediateDirectories: true)
        try AtomicFile.writeUTF8(
            "#!/bin/sh\necho pwned > \"\(evilMarker.path)\"\nprintf 'evil-token'\n",
            to: evilOp,
            permissions: 0o755
        )
        let evilPlist = evilResources.appendingPathComponent("DeveloperCredentials.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "token_reference": "op://evil/vault/token",
            "op_executable": evilOp.path
        ], format: .xml, options: 0).write(to: evilPlist)

        let safeExec = dir.appendingPathComponent("bin/coding-rewind")
        #expect(CLIRunner.resolveBundledCredentialsURL(
            executablePath: "coding-rewind",
            hasCustomDataDir: false,
            environment: [:],
            fallbackExecutableURL: safeExec
        ) == nil)

        let realHelperExec = evilHelpers.appendingPathComponent("coding-rewind")
        #expect(CLIRunner.resolveBundledCredentialsURL(
            executablePath: "coding-rewind",
            hasCustomDataDir: false,
            environment: [:],
            fallbackExecutableURL: realHelperExec
        ) == evilPlist.resolvingSymlinksInPath())

        let stagedDir = dir.appendingPathComponent("PathBin", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let sourceBinary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")
        let pathBinary = stagedDir.appendingPathComponent("coding-rewind")
        try FileManager.default.copyItem(at: sourceBinary, to: pathBinary)

        let isolatedHome = dir.appendingPathComponent("FakeHome", isDirectory: true)
        let appSupportDataDir = isolatedHome.appendingPathComponent("Library/Application Support/CodingRewind", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: appSupportDataDir)
        try paths.saveMemosURLString("http://127.0.0.1:9")

        let outPipe = Pipe()
        let errPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["coding-rewind", "list", "--json"]
        proc.currentDirectoryURL = evilHelpers
        proc.environment = [
            "HOME": isolatedHome.path,
            "PATH": "\(stagedDir.path):/usr/bin:/bin",
            KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        #expect(proc.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: evilMarker.path))
    }

    @Test("Real coding-rewind subprocess returns EX_USAGE 64 on malformed IDs and reads offline HotCache without mutating it")
    func subprocessCLIUsageExitCodesAndOfflineCache() throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
        let paths = try StoragePaths(dataDirectoryURL: dataDir)
        let recentDate = Date().addingTimeInterval(-3600)
        let rawMemo = """
            #rewind/ready #source/antigravity
            > **Title:** Cached Offline Card
            > **Source:** [AGY Session](conversation://cached-session-1) · \(MemosWireFormat.formatISO8601UTC(recentDate))

            Exact cached body line 1
            Exact cached body line 2
            """
        let card = try #require(MemosWireFormat.parseMemo(
            id: "rw-cached-1",
            rawContent: rawMemo,
            createdAt: recentDate,
            now: Date()
        ))
        try HotCache(fileURL: paths.hotCacheFileURL).saveCards([card], now: Date())
        let cacheBefore = try Data(contentsOf: paths.hotCacheFileURL)

        let binary = try SnippetCLIFixtures.builtExecutableURL(named: "coding-rewind")

        for badID in ["memos/../foo", "memos/ foo"] {
            let errPipe = Pipe()
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = ["get", badID, "--data-dir", dataDir.path]
            proc.environment = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe
            try proc.run()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 64)
        }

        let cliOutPipe = Pipe()
        let cliErrPipe = Pipe()
        let cliProc = Process()
        cliProc.executableURL = binary
        cliProc.arguments = ["list", "--data-dir", dataDir.path, "--json"]
        cliProc.environment = ["PATH": "/usr/bin:/bin", "CODING_REWIND_QA": "1"]
        cliProc.standardInput = FileHandle.nullDevice
        cliProc.standardOutput = cliOutPipe
        cliProc.standardError = cliErrPipe
        try cliProc.run()
        let cliOutData = cliOutPipe.fileHandleForReading.readDataToEndOfFile()
        let cliErrData = cliErrPipe.fileHandleForReading.readDataToEndOfFile()
        cliProc.waitUntilExit()

        #expect(cliProc.terminationStatus == 0)
        #expect(cliErrData.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cliDecoded = try decoder.decode(SnippetQueryResult.self, from: cliOutData)
        #expect(cliDecoded.resolution == .localOnly)
        #expect(cliDecoded.snippets.map(\.id) == ["rw-cached-1"])
        #expect(cliDecoded.snippets.first?.verbatimText == "Exact cached body line 1\nExact cached body line 2")
        #expect(try Data(contentsOf: paths.hotCacheFileURL) == cacheBefore)
    }
}

// SPDX-License-Identifier: MIT

@testable import CodingRewindCLI
import CodingRewindCore
import Darwin
import Foundation
import Testing

@Suite("AI Write Surface CLI & 7-Tool MCP Suite")
struct AIWriteSurfaceCLIMCPTests {
    @Test("MCPServer exposes 7 tools, enforces readOnly across all 4 mutating tools while keeping 3 read tools active, and reacts live to config.json toggles")
    func mcpSevenToolsAndReadOnlyLiveEnforcement() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )
        try paths.saveAIAccessMode(.readOnly)

        let backend = FakeSnippetBackend(records: SnippetCLIFixtures.makeSampleRecords())
        let server = MCPServer(
            repositoryProvider: { backend },
            accessModeProvider: { paths.resolveAIAccessMode(environment: [:]) },
            now: { SnippetCLIFixtures.fixedNow }
        )

        func callTool(_ id: Int, name: String, argsJSON: String) async throws -> (isError: Bool, text: String) {
            let payload = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(argsJSON)}}"#
            let respData = try #require(await server.handleLine(Data(payload.utf8)))
            guard case .object(let root) = try JSONValue.decode(from: respData),
                  case .object(let result) = root["result"],
                  case .bool(let isErr) = result["isError"],
                  case .array(let content) = result["content"],
                  case .object(let first) = content.first,
                  case .string(let text) = first["text"] else {
                Issue.record("Unexpected MCP tool response for \(name)")
                return (true, "")
            }
            return (isErr, text)
        }

        let listRead = try await callTool(1, name: "list_snippets", argsJSON: "{}")
        #expect(!listRead.isError)
        let searchRead = try await callTool(2, name: "search_snippets", argsJSON: #"{"query":"actor"}"#)
        #expect(!searchRead.isError)
        let getRead = try await callTool(3, name: "get_snippet", argsJSON: #"{"id":"rw-recent-ready"}"#)
        #expect(!getRead.isError)

        let expectedWriteBlockedText = try #require(RewindError.aiWriteDisabled.errorDescription)
        for (idx, mutatingCall) in [
            ("create_snippet", #"{"text":"blocked draft"}"#),
            ("update_snippet_metadata", #"{"id":"rw-recent-ready","title":"Blocked"}"#),
            ("append_snippet_note", #"{"id":"rw-recent-ready","note":"blocked note"}"#),
            ("archive_snippet", #"{"id":"rw-recent-ready"}"#)
        ].enumerated() {
            let outcome = try await callTool(10 + idx, name: mutatingCall.0, argsJSON: mutatingCall.1)
            #expect(outcome.isError)
            #expect(outcome.text == expectedWriteBlockedText)
        }

        #expect(await backend.recordedCreateInputs.isEmpty)
        #expect(await backend.recordedUpdateCalls.isEmpty)
        #expect(await backend.recordedNoteCalls.isEmpty)
        #expect(await backend.recordedArchiveIDs.isEmpty)

        try paths.saveAIAccessMode(.readWrite)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let created = try await callTool(
            20,
            name: "create_snippet",
            argsJSON: ##"{"text":"  verbatim code\nlet x = 1","title":"Synthesized Draft","tags":["#draft","ch1"]}"##
        )
        #expect(!created.isError)
        let createdRecord = try decoder.decode(SnippetRecord.self, from: Data(created.text.utf8))
        #expect(createdRecord.status == .ready)
        #expect(createdRecord.sourcePlatform == "agent")
        #expect(createdRecord.tags == ["draft", "ch1"])
        #expect(createdRecord.verbatimText == "  verbatim code\nlet x = 1")

        let updated = try await callTool(
            21,
            name: "update_snippet_metadata",
            argsJSON: #"{"id":"\#(createdRecord.id)","session_topic":"AI Write Loop","add_tags":["reviewed"],"remove_tags":["draft"]}"#
        )
        #expect(!updated.isError)
        let updatedRecord = try decoder.decode(SnippetRecord.self, from: Data(updated.text.utf8))
        #expect(updatedRecord.sessionTopic == "AI Write Loop")
        #expect(updatedRecord.tags == ["ch1", "reviewed"])
        #expect(updatedRecord.verbatimText == "  verbatim code\nlet x = 1")

        let noted = try await callTool(
            22,
            name: "append_snippet_note",
            argsJSON: #"{"id":"\#(createdRecord.id)","note":"Key takeaway verified.","author":"Codex"}"#
        )
        #expect(!noted.isError)
        let notedRecord = try decoder.decode(SnippetRecord.self, from: Data(noted.text.utf8))
        #expect(notedRecord.notes.count == 1)
        #expect(notedRecord.notes[0].author == "Codex")
        #expect(notedRecord.notes[0].content == "Key takeaway verified.")

        let emptyPatchErr = try await callTool(
            23,
            name: "update_snippet_metadata",
            argsJSON: #"{"id":"\#(createdRecord.id)"}"#
        )
        #expect(emptyPatchErr.isError)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let runTask = Task {
            await CLIRunner.run(
                arguments: ["coding-rewind", "mcp", "--data-dir", paths.dataDirectoryURL.path],
                environment: [StoragePaths.aiAccessEnvironmentKey: "corrupted_mode_value"],
                now: { SnippetCLIFixtures.fixedNow },
                inputFD: inPipe.fileHandleForReading.fileDescriptor,
                mcpOutputFD: outPipe.fileHandleForWriting.fileDescriptor,
                repositoryFactory: { _, _, _ in backend }
            )
        }
        let failClosedCalls = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_snippets","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_snippet","arguments":{"text":"must fail closed"}}}"#
        ].joined(separator: "\n") + "\n"
        _ = CLIRunner.writeUTF8(failClosedCalls, to: inPipe.fileHandleForWriting.fileDescriptor)
        try? inPipe.fileHandleForWriting.close()
        let runnerExit = await runTask.value
        try? outPipe.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()
        #expect(runnerExit == 0)

        let respLines = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(respLines.count == 2)
        if case .object(let firstObj) = try JSONValue.decode(from: Data(respLines[0].utf8)),
           case .object(let firstRes) = firstObj["result"] {
            #expect(firstRes["isError"] == .bool(false))
        } else {
            Issue.record("Expected read tool to succeed under fail-closed env")
        }
        if case .object(let secondObj) = try JSONValue.decode(from: Data(respLines[1].utf8)),
           case .object(let secondRes) = secondObj["result"] {
            #expect(secondRes["isError"] == .bool(true))
        } else {
            Issue.record("Expected write tool to fail closed under unrecognized CODING_REWIND_AI_ACCESS")
        }
    }

    @Test("CLIParser and CLIRunner support create, update, and note with --text, --stdin, --json, and human Markdown")
    func cliCreateUpdateAndNoteParsingAndExecution() async throws {
        let dir = try SnippetCLIFixtures.makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let parsedCreate = try CLIParser.parse(arguments: [
            "coding-rewind", "create",
            "--text", "Inline body",
            "--title", "Draft Title",
            "--session", "Session A",
            "--context", "Ctx A",
            "--keywords", "swift, mcp",
            "--tag", "#draft",
            "--tag", "v1",
            "--source", "agent",
            "--source-title", "Claude Synthesis",
            "--source-url", "conversation://abc-1",
            "--json"
        ])
        #expect(parsedCreate == .create(
            textSource: .inline("Inline body"),
            input: SnippetCreateInput(
                text: "Inline body",
                title: "Draft Title",
                sessionTopic: "Session A",
                contextSummary: "Ctx A",
                keywords: ["swift", "mcp"],
                tags: ["draft", "v1"],
                sourcePlatform: "agent",
                sourceTitle: "Claude Synthesis",
                sourceURL: "conversation://abc-1"
            ),
            dataDir: nil,
            json: true
        ))

        let parsedUpdate = try CLIParser.parse(arguments: [
            "coding-rewind", "update", "memos/rw-42",
            "--title", "Updated Title",
            "--add-tag", "keep",
            "--remove-tag", "#old",
            "--unarchive",
            "--json"
        ])
        #expect(parsedUpdate == .update(
            id: "rw-42",
            patch: SnippetMetadataPatch(
                title: "Updated Title",
                addTags: ["keep"],
                removeTags: ["old"],
                archived: false
            ),
            dataDir: nil,
            json: true
        ))

        let parsedNote = try CLIParser.parse(arguments: [
            "coding-rewind", "note", "memos/rw-42", "--stdin", "--author", "Antigravity"
        ])
        #expect(parsedNote == .note(
            id: "rw-42",
            textSource: .stdin,
            author: "Antigravity",
            dataDir: nil,
            json: false
        ))

        for invalidArgs in [
            ["coding-rewind", "create"],
            ["coding-rewind", "create", "--text", "a", "--stdin"],
            ["coding-rewind", "create", "--text", "   "],
            ["coding-rewind", "create", "--text", "ok", "--tag", "rewind/ready"],
            ["coding-rewind", "create", "--text", "ok", "--tag", "source/macos"],
            ["coding-rewind", "update", "rw-1"],
            ["coding-rewind", "update", "rw-1", "--archive", "--unarchive"],
            ["coding-rewind", "note", "rw-1"],
            ["coding-rewind", "note", "rw-1", "--text", "a", "--stdin"]
        ] {
            #expect(throws: CLIValidationError.self) {
                _ = try CLIParser.parse(arguments: invalidArgs)
            }
        }

        let backend = FakeSnippetBackend(records: SnippetCLIFixtures.makeSampleRecords())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let stdinMarkdown = "  Indented line\n\n```swift\nlet exact = \"汉字\"\n```"
        let createPipe = Pipe()
        _ = CLIRunner.writeUTF8(stdinMarkdown, to: createPipe.fileHandleForWriting.fileDescriptor)
        try createPipe.fileHandleForWriting.close()

        let createOut = OutputCollector()
        let createErr = OutputCollector()
        let createExit = await CLIRunner.run(
            arguments: [
                "coding-rewind", "create", "--stdin",
                "--tag", "loop",
                "--data-dir", dir.path,
                "--json"
            ],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            inputFD: createPipe.fileHandleForReading.fileDescriptor,
            writeStdout: createOut.append,
            writeStderr: createErr.append,
            repositoryFactory: { _, _, _ in backend }
        )
        try? createPipe.fileHandleForReading.close()
        #expect(createExit == 0)
        #expect(createErr.value().isEmpty)
        let createdRecord = try decoder.decode(SnippetRecord.self, from: Data(createOut.value().utf8))
        #expect(createdRecord.status == .pending)
        #expect(createdRecord.sourcePlatform == "agent")
        #expect(createdRecord.tags == ["loop"])
        #expect(createdRecord.verbatimText == stdinMarkdown)

        let updateOut = OutputCollector()
        let updateExit = await CLIRunner.run(
            arguments: [
                "coding-rewind", "update", createdRecord.id,
                "--title", "Promoted Ready",
                "--keywords", "k1, k2",
                "--add-tag", "ready-tag",
                "--data-dir", dir.path,
                "--json"
            ],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            writeStdout: updateOut.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        #expect(updateExit == 0)
        let updatedRecord = try decoder.decode(SnippetRecord.self, from: Data(updateOut.value().utf8))
        #expect(updatedRecord.status == .ready)
        #expect(updatedRecord.title == "Promoted Ready")
        #expect(updatedRecord.keywords == ["k1", "k2"])
        #expect(updatedRecord.tags == ["loop", "ready-tag"])
        #expect(updatedRecord.verbatimText == stdinMarkdown)

        let notePipe = Pipe()
        _ = CLIRunner.writeUTF8("Conclusion via --stdin", to: notePipe.fileHandleForWriting.fileDescriptor)
        try notePipe.fileHandleForWriting.close()
        let noteHumanOut = OutputCollector()
        let noteExit = await CLIRunner.run(
            arguments: [
                "coding-rewind", "note", createdRecord.id,
                "--stdin", "--author", "Claude",
                "--data-dir", dir.path
            ],
            environment: [:],
            now: { SnippetCLIFixtures.fixedNow },
            inputFD: notePipe.fileHandleForReading.fileDescriptor,
            writeStdout: noteHumanOut.append,
            writeStderr: { _ in },
            repositoryFactory: { _, _, _ in backend }
        )
        try? notePipe.fileHandleForReading.close()
        #expect(noteExit == 0)
        #expect(noteHumanOut.value().contains("Appended note to snippet \(createdRecord.id)"))
        #expect(noteHumanOut.value().contains("### Notes"))
        #expect(noteHumanOut.value().contains("Conclusion via --stdin"))
    }
}

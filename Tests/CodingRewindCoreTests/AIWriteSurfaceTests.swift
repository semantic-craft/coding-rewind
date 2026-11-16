// SPDX-License-Identifier: MIT

@testable import CodingRewindCore
import Foundation
import Testing

@Suite("AI Write Surface Config, Wire Format & Prompt Loop Suite")
struct AIWriteSurfaceTests {
    private func makeScratchDir() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data/test-aiwrite-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("AIAccessMode persists alongside memos_url without clobbering, fails closed on invalid env, and emits token-free MCP JSON")
    func aiAccessModePersistenceEnvOverrideAndMCPConfigJSON() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try StoragePaths(
            dataDirectoryURL: dir.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: dir.appendingPathComponent("Config", isDirectory: true)
        )

        #expect(paths.resolveAIAccessMode(environment: [:]) == .readWrite)
        #expect(!paths.isAIAccessManagedByEnvironment(environment: [:]))
        #expect(!paths.isAIAccessManagedByEnvironment(environment: [StoragePaths.aiAccessEnvironmentKey: "  "]))

        for rawRO in ["read_only", "readonly", "read-only", " READ_ONLY ", "Read-Only"] {
            #expect(StoragePaths.parseAIAccessMode(rawRO) == .readOnly)
        }
        for rawRW in ["read_write", "readwrite", "read-write", " READ_WRITE ", "Read-Write"] {
            #expect(StoragePaths.parseAIAccessMode(rawRW) == .readWrite)
        }
        #expect(StoragePaths.parseAIAccessMode("unknown") == nil)

        try paths.saveMemosURLString("https://memos.example.com/api/memos/")
        try paths.saveAIAccessMode(.readOnly)
        #expect(paths.resolveAIAccessMode(environment: [:]) == .readOnly)
        #expect(paths.readConfiguredMemosURLString(environment: [:]) == "https://memos.example.com")

        try paths.saveMemosURLString("https://updated.example.com")
        #expect(paths.readConfiguredMemosURLString(environment: [:]) == "https://updated.example.com")
        #expect(paths.resolveAIAccessMode(environment: [:]) == .readOnly)

        let rawConfigText = try String(contentsOf: paths.configFileURL, encoding: .utf8)
        #expect(rawConfigText.contains("\"ai_access_mode\""))
        #expect(rawConfigText.contains("\"memos_url\""))
        #expect(!rawConfigText.lowercased().contains("token"))

        #expect(paths.resolveAIAccessMode(environment: [StoragePaths.aiAccessEnvironmentKey: "read-write"]) == .readWrite)
        try paths.saveAIAccessMode(.readWrite)
        #expect(paths.resolveAIAccessMode(environment: [StoragePaths.aiAccessEnvironmentKey: "readonly"]) == .readOnly)
        #expect(paths.resolveAIAccessMode(environment: [StoragePaths.aiAccessEnvironmentKey: "bogus_value"]) == .readOnly)
        #expect(paths.isAIAccessManagedByEnvironment(environment: [StoragePaths.aiAccessEnvironmentKey: "bogus_value"]))

        let mcpJSON = StoragePaths.standardMCPConfigurationJSON()
        #expect(!mcpJSON.lowercased().contains("token"))
        let parsedMCP = try #require(JSONSerialization.jsonObject(with: Data(mcpJSON.utf8)) as? [String: Any])
        let servers = try #require(parsedMCP["mcpServers"] as? [String: Any])
        let entry = try #require(servers["coding-rewind"] as? [String: Any])
        #expect(entry["command"] as? String == "${HOME}/Library/Application Support/CodingRewind/bin/coding-rewind")
        #expect(entry["args"] as? [String] == ["mcp"])
        #expect(entry.keys.sorted() == ["args", "command"])
    }

    @Test("Wire format preserves 100% byte-identical verbatimText across agent creation, metadata updates, and note isolation")
    func wireFormatVerbatimPreservationAndNoteIsolation() throws {
        let now = Date(timeIntervalSince1970: 1_763_300_000)

        for _ in 0..<20 {
            let noteID = MemosWireFormat.makeNoteCommentID(snippetID: "rw-long-snippet-123456", now: now)
            #expect(noteID.utf8.count <= 36)
            #expect(MemosWireFormat.isValidMemoID(noteID))
        }

        let complexVerbatim = """
          Indented line with UTF-8 汉字 e\u{301} 👨‍👩‍👧‍👦

        ```swift
        // #rewind/pending and #rewind/synthesized inside code fence
        > **Title:** Fake Blockquote Inside Code
        func keepMe() -> Int {

            return 7
        }
        ```

        > **Title:** Literal Blockquote In Body
        """

        let pendingRaw = try MemosWireFormat.formatAgentCreatedContent(
            verbatimText: complexVerbatim,
            capturedAt: now,
            tags: ["#draft", "outline/v1", "DRAFT"]
        )
        #expect(pendingRaw.hasPrefix("#rewind/pending #source/agent #draft #outline/v1\n\n"))
        let parsedPending = try #require(MemosWireFormat.parseSnippetRecord(
            id: "rw-1",
            rawContent: pendingRaw,
            createdAt: now,
            dataOrigin: .remote
        ))
        #expect(parsedPending.status == .pending)
        #expect(parsedPending.sourcePlatform == "agent")
        #expect(parsedPending.tags == ["draft", "outline/v1"])
        #expect(parsedPending.verbatimText.utf8.elementsEqual(complexVerbatim.utf8))

        let promotedRaw = MemosWireFormat.updatingSnippetMetadata(
            rawContent: pendingRaw,
            title: "Chapter 1 Synthesis",
            sessionTopic: "Copyright Topic",
            contextSummary: "Synthesized from 3 clips.",
            keywords: ["copyright", "ai"],
            addTags: ["ch1"],
            removeTags: ["draft"]
        )
        let parsedPromoted = try #require(MemosWireFormat.parseSnippetRecord(
            id: "rw-1",
            rawContent: promotedRaw,
            createdAt: now,
            dataOrigin: .remote
        ))
        #expect(parsedPromoted.status == .ready)
        #expect(parsedPromoted.title == "Chapter 1 Synthesis")
        #expect(parsedPromoted.tags == ["outline/v1", "ch1"])
        #expect(parsedPromoted.verbatimText.utf8.elementsEqual(complexVerbatim.utf8))

        let archivedRaw = MemosWireFormat.updatingSnippetMetadata(rawContent: promotedRaw, archived: true)
        let unarchivedRaw = MemosWireFormat.updatingSnippetMetadata(rawContent: archivedRaw, archived: false)
        let parsedUnarchived = try #require(MemosWireFormat.parseSnippetRecord(
            id: "rw-1",
            rawContent: unarchivedRaw,
            createdAt: now,
            dataOrigin: .remote
        ))
        #expect(parsedUnarchived.status == .ready)
        #expect(parsedUnarchived.tags == ["outline/v1", "ch1"])
        #expect(parsedUnarchived.verbatimText.utf8.elementsEqual(complexVerbatim.utf8))

        let noteBody = "Conclusion:\n```md\n- A\n```\nAuthor: body line"
        let formattedNote = try MemosWireFormat.formatNoteComment(note: noteBody, author: "Claude\nAgent", createdAt: now)
        #expect(MemosWireFormat.parseContextComment(formattedNote) == nil)
        let parsedNote = try #require(MemosWireFormat.parseNoteComment(id: "memos/rw-note-1", rawComment: formattedNote))
        #expect(parsedNote.id == "rw-note-1")
        #expect(parsedNote.author == "Claude Agent")
        #expect(parsedNote.content == noteBody)

        let ctxRaw = CaptureContext(sessionTitle: "Chat", prompt: "Prompt", recentTurns: []).formattedCommentMarkdown()
        #expect(MemosWireFormat.parseNoteComment(id: "rw-ctx-1", rawComment: ctxRaw) == nil)
    }

    @Test("ConversationPrompt includes Clip ID and gates write-back hint on AIAccessMode; SKILL.md documents all 7 tools")
    func conversationPromptAndSkillGuidance() throws {
        let card = RewindCard(
            id: "rw-loop-42",
            rawContent: "#rewind/ready #source/antigravity\n\nVerbatim highlight.",
            status: .ready,
            sourcePlatform: "antigravity",
            title: "Loop Card",
            sourceTitle: "Antigravity",
            sourceURL: "conversation://loop-42",
            verbatimText: "Verbatim highlight.",
            createdAt: Date(timeIntervalSince1970: 1_763_300_000)
        )

        let zhRW = ConversationPrompt.buildPrompt(for: [card], language: .zhHans, aiAccessMode: .readWrite)
        let zhRO = ConversationPrompt.buildPrompt(for: [card], language: .zhHans, aiAccessMode: .readOnly)
        #expect(zhRW.contains("- 卡片 ID：`rw-loop-42`"))
        #expect(zhRW.contains("append_snippet_note") && zhRW.contains("create_snippet"))
        #expect(zhRO.contains("- 卡片 ID：`rw-loop-42`"))
        #expect(!zhRO.contains("append_snippet_note") && !zhRO.contains("create_snippet"))

        let enRW = ConversationPrompt.buildPrompt(for: [card], language: .en, aiAccessMode: .readWrite)
        let enRO = ConversationPrompt.buildPrompt(for: [card], language: .en, aiAccessMode: .readOnly)
        #expect(enRW.contains("- Clip ID: `rw-loop-42`"))
        #expect(enRW.contains("append_snippet_note") && enRW.contains("create_snippet"))
        #expect(enRO.contains("- Clip ID: `rw-loop-42`"))
        #expect(!enRO.contains("append_snippet_note") && !enRO.contains("create_snippet"))

        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
        let configDir = dir.appendingPathComponent("Config", isDirectory: true)
        let fakeBin = dir.appendingPathComponent("fake-bin")
        try AtomicFile.writeUTF8("#!/bin/sh\nexit 0\n", to: fakeBin, permissions: 0o755)
        let pluginDir = try AntigravityIntegration.installOrRepair(
            dataDirectoryURL: dataDir,
            configDirectoryURL: configDir,
            sourceCLIBinaryURL: fakeBin,
            sourceSidecarBinaryURL: fakeBin
        )
        let skillURL = pluginDir.appendingPathComponent("skills/rewind/SKILL.md")
        let skillText = try String(contentsOf: skillURL, encoding: .utf8)
        for tool in [
            "list_snippets", "search_snippets", "get_snippet",
            "create_snippet", "update_snippet_metadata", "append_snippet_note", "archive_snippet"
        ] {
            #expect(skillText.contains(tool))
        }
        #expect(AntigravityIntegration.repairReasons(dataDirectoryURL: dataDir, configDirectoryURL: configDir).isEmpty)
    }
}

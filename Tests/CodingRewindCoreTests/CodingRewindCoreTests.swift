// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

@Suite("CodingRewindCore Behavioral Suite")
struct CodingRewindCoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-rewind-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("VerbatimExcerpt strips NUL bytes, preserves formatting, and rejects blank input")
    func verbatimExcerptValidation() throws {
        let excerpt = try VerbatimExcerpt(validating: "  line 1\0\n  line 2  ")
        #expect(excerpt.text == "  line 1\n  line 2  ")

        #expect(throws: StashError.emptyExcerpt) {
            _ = try VerbatimExcerpt(validating: "   \n\t\0  ")
        }
    }

    @Test("PromptContext normalizes nil or blank strings to .missing without fabricating text")
    func promptContextBoundaryNormalization() {
        #expect(PromptContext.from(raw: nil) == .missing)
        #expect(PromptContext.from(raw: "  \n\t\0 ") == .missing)
        #expect(PromptContext.from(raw: "  如何配置 SQLite WAL 模式？ ") == .captured("如何配置 SQLite WAL 模式？"))
    }

    @Test("DraftID rejects path traversal and normalizes titles into safe stems")
    func draftIDRejectsTraversal() throws {
        let valid = try DraftID(parsing: "Architecture-Notes_01.md")
        #expect(valid.stem == "architecture-notes_01")
        #expect(valid.filename == "architecture-notes_01.md")

        #expect(throws: StashError.self) {
            _ = try DraftID(parsing: "../secret")
        }
        #expect(throws: StashError.self) {
            _ = try DraftID(parsing: "sub/file")
        }

        let cjkSlug = DraftID.makeSlug(fromTitle: "纯中文标题成文草稿", suffix: "2")
        #expect(cjkSlug.stem == "draft-2")
    }

    @Test("Clip lifecycle derives .hot within 72h, .archived past 72h, .synthesized, and supports non-destructive reheating")
    func clipLifecycleDerivationAndReheating() throws {
        let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
        var clip = Clip(
            verbatimExcerpt: try VerbatimExcerpt(validating: "[SYNTHETIC] Verbatim snippet"),
            promptContext: .missing,
            source: .web(site: .claude, url: "https://claude.ai/chat/synthetic", pageTitle: nil),
            capturedAt: baseDate
        )

        #expect(clip.lifecycle(at: baseDate.addingTimeInterval(3600)) == .hot)
        #expect(clip.lifecycle(at: baseDate.addingTimeInterval(72 * 3600)) == .hot)
        #expect(clip.lifecycle(at: baseDate.addingTimeInterval(72 * 3600 + 1)) == .archived)

        let reheatDate = baseDate.addingTimeInterval(100 * 3600)
        clip.disposition = .active(reheatedAt: reheatDate)
        #expect(clip.capturedAt == baseDate)
        #expect(clip.lifecycle(at: reheatDate.addingTimeInterval(24 * 3600)) == .hot)
        #expect(clip.lifecycle(at: reheatDate.addingTimeInterval(73 * 3600)) == .archived)

        clip.disposition = .cooled(at: reheatDate)
        #expect(clip.lifecycle(at: reheatDate) == .archived)

        clip.disposition = .synthesized(draftID: try DraftID(parsing: "note-1"), at: reheatDate)
        #expect(clip.lifecycle(at: reheatDate.addingTimeInterval(200 * 3600)) == .synthesized)
    }

    @Test("M2 + M3: StashStore captures without title/tags, separates annotations, exports Markdown/JSON, and synchronously purges FTS5 on delete")
    func stashStoreCaptureExportAndSynchronousFTSDelete() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = try StoragePaths(
            appSupportDirectoryURL: tempDir.appendingPathComponent("AppSupport"),
            antigravityConfigDirectoryURL: tempDir.appendingPathComponent("GeminiConfig")
        )
        let store = try StashStore(location: .sqliteFile(paths.stashDatabaseURL), mode: .readWrite)
        let now = Date(timeIntervalSince1970: 1_762_000_000)

        let clip1 = try await store.capture(
            NewClip(
                excerpt: "[SYNTHETIC] NSPanel 配合 nonactivatingPanel 实现不抢焦点的悬浮窗，适合边聊边存。",
                promptContext: .captured("[SYNTHETIC] macOS 上如何实现不打断当前窗口焦点的速览面板？"),
                source: .antigravity(
                    conversationId: "synthetic-conv-alpha",
                    workspacePath: "/tmp/synthetic-workspace",
                    locator: "conversation://synthetic-conv-alpha"
                ),
                capturedAt: now
            )
        )
        let clip2 = try await store.capture(
            NewClip(
                excerpt: "[SYNTHETIC] Antigravity 2.31 的 PostInvocation 钩子若误配成 PreToolUse 或未能输出空 JSON 对象会导致工具调用被拒绝。",
                promptContext: .missing,
                source: .web(site: .chatgpt, url: "https://chatgpt.com/c/synthetic-2", pageTitle: "Synthetic Hook Thread"),
                capturedAt: now.addingTimeInterval(10)
            )
        )

        #expect(clip1.annotation.isEmpty)
        #expect(clip2.promptContext == .missing)

        let updatedClip1 = try await store.updateAnnotation(
            ClipAnnotation(
                title: "不抢焦点 HUD 设计",
                tags: ["nspanel", "hud"],
                userNote: "个人批注：注意与原文严格区分。"
            ),
            for: clip1.id
        )
        #expect(updatedClip1.excerpt == clip1.excerpt)
        #expect(updatedClip1.annotation.userNote == "个人批注：注意与原文严格区分。")

        let mdExportData = try await store.exportClips(ids: [clip1.id, clip2.id], format: .markdown, now: now)
        let mdExport = try #require(String(data: mdExportData, encoding: .utf8))
        #expect(mdExport.contains(clip1.excerpt))
        #expect(mdExport.contains("个人批注：注意与原文严格区分。"))
        #expect(mdExport.contains("用户后补注释 (Separated User Annotation)"))
        #expect(mdExport.contains("原问题缺失"))

        let jsonExportData = try await store.exportClips(ids: nil, format: .json, now: now)
        let jsonExport = try #require(String(data: jsonExportData, encoding: .utf8))
        #expect(jsonExport.contains("\"promptStatus\" : \"missing\""))
        #expect(jsonExport.contains("\"annotationUserNote\" : \"个人批注：注意与原文严格区分。\""))

        let singleDeleteReceipt = try await store.deleteClip(id: clip1.id)
        #expect(singleDeleteReceipt.deletedClipCount == 1)
        #expect(singleDeleteReceipt.remainingClipCount == 1)

        let searchDeleted = try await store.clips(
            matching: ClipQuery(text: "不抢焦点的浮窗", scope: .all, referenceDate: now)
        )
        #expect(searchDeleted.isEmpty)

        let purgeAllReceipt = try await store.deleteAllClips(confirmation: .userConfirmedPurgeAll)
        #expect(purgeAllReceipt.deletedClipCount == 1)
        #expect(purgeAllReceipt.remainingClipCount == 0)
        #expect(purgeAllReceipt.remainingFTSTokenRows == 0)
    }

    @Test("M4: Natural-language retrieval matches Chinese and English phrases without exact substring and returns [] for unrelated queries")
    func naturalLanguageRetrievalAndRelevanceFloor() async throws {
        let store = try StashStore(location: .inMemory, mode: .readWrite)
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let seeds = try SyntheticDemoSeed.makeDemoClips(referenceDate: now)
        for seed in seeds {
            _ = try await store.capture(seed)
        }

        let hudHits = try await store.clips(
            matching: ClipQuery(text: "不抢焦点的浮窗", scope: .hot, referenceDate: now)
        )
        #expect(!hudHits.isEmpty)
        #expect(hudHits.first?.excerpt.contains("nonactivatingPanel") == true)

        let hookHits = try await store.clips(
            matching: ClipQuery(text: "钩子空输出拒绝调用", scope: .hot, referenceDate: now)
        )
        #expect(!hookHits.isEmpty)
        #expect(hookHits.first?.excerpt.contains("PostInvocation") == true)

        let walHits = try await store.clips(
            matching: ClipQuery(text: "倒排索引同步清零与并发读取", scope: .hot, referenceDate: now)
        )
        #expect(!walHits.isEmpty)
        #expect(walHits.first?.excerpt.contains("SQLite3") == true)

        let unrelatedChinese = try await store.clips(
            matching: ClipQuery(text: "如何用烤箱烘培蓝莓芝士蛋糕配方", scope: .all, referenceDate: now)
        )
        #expect(unrelatedChinese.isEmpty)

        let unrelatedEnglish = try await store.clips(
            matching: ClipQuery(text: "sourdough bread starter hydration temperature", scope: .all, referenceDate: now)
        )
        #expect(unrelatedEnglish.isEmpty)
    }

    @Test("DraftStore persists plain UTF-8 .md files on disk with a single leading HTML comment and appends citations")
    func draftStorePlainMarkdownPersistence() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let draftStore = try DraftStore(directoryURL: tempDir.appendingPathComponent("Drafts"))
        let clipID1 = try ClipID(parsing: "11111111-2222-3333-4444-555555555555")
        let clipID2 = try ClipID(parsing: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

        var draft = try await draftStore.createDraft(
            title: "Antigravity Hooks 设计笔记",
            pinnedClipIDs: [clipID1, clipID2]
        )
        #expect(FileManager.default.fileExists(atPath: draft.fileURL.path))

        let rawOnDisk = try String(contentsOf: draft.fileURL, encoding: .utf8)
        #expect(rawOnDisk.hasPrefix("<!-- coding-rewind-clips: \(clipID1.rawValue),\(clipID2.rawValue) -->\n# Antigravity Hooks 设计笔记"))

        let clip = Clip(
            id: clipID1,
            verbatimExcerpt: try VerbatimExcerpt(validating: "[SYNTHETIC] Hook must output {}"),
            promptContext: .captured("[SYNTHETIC] Hook contract?"),
            source: .antigravity(conversationId: "conv-1", workspacePath: nil, locator: "conversation://conv-1")
        )
        draft.markdownBody = DraftStore.appendCitedMarkdown(
            into: draft.markdownBody,
            insertedMarkdown: "必须保证钩子在 50ms 内返回空对象。",
            citedClips: [clip]
        )
        let saved = try await draftStore.saveDraft(draft)
        let reloaded = try await draftStore.loadDraft(id: saved.id)
        #expect(reloaded.pinnedClipIDs == [clipID1, clipID2])
        #expect(reloaded.markdownBody.contains("[^clip-11111111]"))
        #expect(reloaded.markdownBody.contains("[^clip-11111111]: 出处: Antigravity 2.x"))
    }

    @Test("ActiveTurnStore retains at most 4 freshest 0600 per-conversation snapshots and scopes reads to com.google.antigravity")
    func activeTurnStoreBoundedSnapshotsAndPermissions() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ActiveTurnStore(directoryURL: tempDir.appendingPathComponent("Runtime"))
        let baseDate = Date(timeIntervalSince1970: 1_762_000_000)

        for idx in 1...6 {
            let turn = try ActiveAntigravityTurn(
                conversationId: "conv-\(idx)",
                workspacePath: "/tmp/ws-\(idx)",
                userPrompt: "[SYNTHETIC] User question #\(idx)",
                observedAt: baseDate.addingTimeInterval(Double(idx * 60))
            )
            try store.record(turn)
        }

        let files = try store.retainedSnapshotFileURLs()
        #expect(files.count == 4)

        for url in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            #expect(perms == 0o600)
        }

        let safariTurn = try store.latestTurn(
            forFrontmostBundleID: "com.apple.Safari",
            now: baseDate.addingTimeInterval(500)
        )
        #expect(safariTurn == nil)

        let latestAntigravity = try store.latestTurn(
            forFrontmostBundleID: CapturedSelection.antigravityBundleIdentifier,
            now: baseDate.addingTimeInterval(500)
        )
        #expect(latestAntigravity?.conversationId == "conv-6")
        #expect(latestAntigravity?.userPrompt == "[SYNTHETIC] User question #6")
    }

    @Test("StashURLCommand parses coding-rewind://stash with clipboard fallback, missing prompt normalization, and silent flag")
    func stashURLCommandParsing() throws {
        let directURL = try #require(URL(
            string: "coding-rewind://stash?excerpt=%5BSYNTHETIC%5D%20Web%20snippet&source=claude&url=https://claude.ai/chat/123&silent=true"
        ))
        let directCmd = try StashURLCommand.parse(directURL, clipboardText: { nil })
        #expect(directCmd.isSilent == true)
        #expect(directCmd.newClip.excerpt == "[SYNTHETIC] Web snippet")
        #expect(directCmd.newClip.promptContext == .missing)
        #expect(directCmd.newClip.source == .web(site: .claude, url: "https://claude.ai/chat/123", pageTitle: nil))

        let clipboardURL = try #require(URL(
            string: "coding-rewind://stash?clipboard=1&prompt=%5BSYNTHETIC%5D%20Prompt&source=gemini&silent=0"
        ))
        let clipboardCmd = try StashURLCommand.parse(clipboardURL, clipboardText: { "[SYNTHETIC] Large clipboard excerpt" })
        #expect(clipboardCmd.isSilent == false)
        #expect(clipboardCmd.newClip.excerpt == "[SYNTHETIC] Large clipboard excerpt")
        #expect(clipboardCmd.newClip.promptContext == .captured("[SYNTHETIC] Prompt"))
        #expect(clipboardCmd.newClip.source == .web(site: .gemini, url: nil, pageTitle: nil))
    }

    @Test("StudioSynthesizer enforces zero outbound traffic by default and validates RemoteEndpointConsent")
    func studioSynthesizerOutboundFence() async throws {
        #expect(throws: StudioSynthesisError.self) {
            _ = try RemoteEndpointConsent(
                endpointURL: URL(string: "http://example.com/v1/chat/completions")!,
                modelIdentifier: "gpt-4o",
                keychainAccount: "acct",
                acknowledgedHost: "example.com"
            )
        }
        #expect(throws: StudioSynthesisError.self) {
            _ = try RemoteEndpointConsent(
                endpointURL: URL(string: "https://api.example.com/v1/chat/completions")!,
                modelIdentifier: "gpt-4o",
                keychainAccount: "acct",
                acknowledgedHost: "other.example.com"
            )
        }

        let clip = Clip(
            id: try ClipID(parsing: "abcdef12-3456-7890-abcd-ef1234567890"),
            verbatimExcerpt: try VerbatimExcerpt(validating: "[SYNTHETIC] Local synthesis evidence"),
            promptContext: .captured("[SYNTHETIC] How to structure local synthesis?"),
            source: .antigravity(conversationId: "c1", workspacePath: "/tmp/demo", locator: "conversation://c1")
        )
        let synthesizer = StudioSynthesizer()
        let localResponse = try await synthesizer.respond(
            StudioRequest(
                pinnedClips: [clip],
                conversation: [ChatTurn(role: .user, text: "整理成两段论据")],
                draftMarkdown: "# 草稿\n",
                backend: .localOutline
            )
        )
        #expect(localResponse.outboundHostUsed == nil)
        #expect(localResponse.citedClipIDs.contains(clip.id))
        #expect(localResponse.suggestedMarkdown.contains("[^clip-abcdef12]"))

        let handoffResponse = try await synthesizer.respond(
            StudioRequest(
                pinnedClips: [clip],
                conversation: [ChatTurn(role: .user, text: "交给 Antigravity 深入推演")],
                draftMarkdown: "# 草稿\n",
                backend: .antigravityHandoff
            )
        )
        #expect(handoffResponse.outboundHostUsed == nil)
        #expect(handoffResponse.suggestedMarkdown.hasPrefix("/rewind"))
        #expect(handoffResponse.suggestedMarkdown.contains(RewindMCPToolID.getClip.rawValue))
    }

    @Test("AntigravityIntegration idempotently installs, verifies, preserves unrelated hooks, and uninstalls in temp directory")
    func antigravityIntegrationIdempotentInstallAndVerify() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configDir = tempDir.appendingPathComponent("gemini-config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let existingHooksURL = configDir.appendingPathComponent("hooks.json")
        let preExistingHookJSON = """
        {
          "existing-user-hook": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/true"
                  }
                ]
              }
            ]
          }
        }
        """
        try preExistingHookJSON.write(to: existingHooksURL, atomically: true, encoding: .utf8)

        let binaries = AntigravityIntegration.BinaryLocations(
            antigravityBridgeExecutableURL: tempDir.appendingPathComponent("bin/coding-rewind-hook"),
            rewindMCPExecutableURL: tempDir.appendingPathComponent("bin/rewind-mcp")
        )

        if case .installed = AntigravityIntegration.verify(configDirectoryURL: configDir, binaries: binaries) {
            Issue.record("Expected needsInstallOrRepair before installation")
        }

        try AntigravityIntegration.installOrRepair(configDirectoryURL: configDir, binaries: binaries)
        try AntigravityIntegration.installOrRepair(configDirectoryURL: configDir, binaries: binaries)

        let status = AntigravityIntegration.verify(configDirectoryURL: configDir, binaries: binaries)
        switch status {
        case .installed(let pluginDir, let hooksFile):
            let hooksData = try Data(contentsOf: hooksFile)
            let hooksObj = try #require(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
            #expect(hooksObj["existing-user-hook"] != nil)
            let ourGroup = try #require(hooksObj["coding-rewind-bridge"] as? [String: Any])
            #expect(Set(ourGroup.keys) == Set(["PostInvocation", "Stop"]))

            let wrapperURL = pluginDir.appendingPathComponent("bin/rewind-mcp.sh")
            #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path))
        case .needsInstallOrRepair(let reasons):
            Issue.record("Unexpected repair needed: \(reasons)")
        }

        try AntigravityIntegration.uninstall(configDirectoryURL: configDir)
        let hooksAfterUninstall = try Data(contentsOf: existingHooksURL)
        let hooksObjAfter = try #require(JSONSerialization.jsonObject(with: hooksAfterUninstall) as? [String: Any])
        #expect(hooksObjAfter["existing-user-hook"] != nil)
        #expect(hooksObjAfter["coding-rewind-bridge"] == nil)
    }
}

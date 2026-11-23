// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CodingRewindCore

private struct PreferencesSelectionCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        CapturedSelection(text: "Selected text", bundleIdentifier: "fixture", appName: "Fixture")
    }
}

@Suite("Capture preferences")
struct CapturePreferencesTests {
    @Test("Skipping AI and omitting context are independent on DSH captures", arguments: [false, true], [false, true])
    @MainActor
    func dshCapturePolicy(includeContext: Bool, enrichWithAI: Bool) async throws {
        let paths = try makeIsolatedPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectoryURL.deletingLastPathComponent()) }
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: PreferencesSelectionCapturer(),
            capturePreferences: {
                CapturePreferences(includeContext: includeContext, enrichWithAI: enrichWithAI)
            }
        )
        let text = "    Selected code  \n"
        let prompt = "Explain the dispatch."
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let receipt = await coordinator.captureExternalDSHRequest(DSHCaptureBridgeRequest(
            text: text,
            sessionId: "fixture-session",
            sessionTitle: "DSH fixture",
            messages: [
                DSHSnapshotMessage(role: "user", text: prompt),
                DSHSnapshotMessage(role: "assistant", text: text)
            ],
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 30_000
        ))

        #expect(receipt.state == .queuedOffline)
        let clipID = try #require(receipt.clipId)
        let entry = try #require(OfflineOutbox(fileURL: paths.outboxFileURL).loadEntries().first { $0.clientClipId == clipID })
        let statusTag = enrichWithAI ? "#rewind/pending" : "#rewind/ready"
        let waitTag = includeContext && enrichWithAI ? " #rewind/has-ctx" : ""
        #expect(entry.memoContent.hasPrefix("\(statusTag)\(waitTag) #source/dsh\n"))
        #expect(entry.commentContent?.contains(prompt) == (includeContext ? true : nil))
        #expect(entry.memoContent.contains("dsh-session://fixture-session"))
        #expect(entry.memoContent.utf8.suffix(text.utf8.count).elementsEqual(text.utf8))
    }

    @Test("Quick capture overrides defaults without changing the preference for the next capture")
    @MainActor
    func quickCaptureOverride() async throws {
        let paths = try makeIsolatedPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectoryURL.deletingLastPathComponent()) }
        let project = try #require(PlaceRef(tag: "project/default-project"))
        let topic = try #require(PlaceRef(tag: "topic/one-off"))
        let coordinator = try AppCoordinator(
            paths: paths,
            environment: [StoragePaths.qaEnvironmentKey: "1"],
            capturer: PreferencesSelectionCapturer(),
            capturePreferences: { CapturePreferences(defaultPlace: project, defaultTags: ["DefaultTag"]) }
        )
        let clipPreferences = CapturePreferences(
            defaultPlace: topic,
            defaultTags: ["#Useful", "useful", "source/fake", "rewind/pending", "project/injected", "two tags"],
            enrichWithAI: false
        )
        let original = try ClipOriginal(filename: "sample.txt", data: Data("Original bytes".utf8))
        let text = "  let decomposed = \"e\u{301}\"  \n"
        guard case .queuedOffline(let overrideID) = await coordinator.captureQuickClip(
            text, original: original, preferences: clipPreferences
        ), case .queuedOffline(let defaultID) = await coordinator.captureQuickClip("Next clip") else {
            Issue.record("Expected both clips in the offline queue")
            return
        }

        let entries = OfflineOutbox(fileURL: paths.outboxFileURL).loadEntries()
        let overridden = try #require(entries.first { $0.clientClipId == overrideID })
        let defaulted = try #require(entries.first { $0.clientClipId == defaultID })
        #expect(overridden.memoContent.hasPrefix("#rewind/ready #source/macos #rewind/original #topic/one-off #Useful\n"))
        #expect(overridden.memoContent.utf8.suffix(text.utf8.count).elementsEqual(text.utf8))
        #expect(overridden.original == original)
        #expect(overridden.commentContent == nil)
        #expect(defaulted.memoContent.hasPrefix("#rewind/pending #source/macos #project/default-project #DefaultTag\n"))

        coordinator.places = [PlaceRecord(ref: project, title: "Default project", archived: true)]
        guard case .queuedOffline(let archivedID) = await coordinator.captureQuickClip("Clip after archival") else {
            Issue.record("Expected the clip to save after its default place was archived")
            return
        }
        let afterArchival = try #require(OfflineOutbox(fileURL: paths.outboxFileURL).loadEntries()
            .first { $0.clientClipId == archivedID })
        #expect(afterArchival.memoContent.hasPrefix("#rewind/pending #source/macos #DefaultTag\n"))
    }

    private func makeIsolatedPaths() throws -> StoragePaths {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-data/capture-preferences-\(UUID().uuidString)", isDirectory: true)
        return try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true),
            dshHomeDirectoryURL: root.appendingPathComponent("DSH", isDirectory: true)
        )
    }
}

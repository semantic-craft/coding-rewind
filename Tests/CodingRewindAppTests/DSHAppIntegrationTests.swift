// SPDX-License-Identifier: MIT

import AppKit
import CodingRewindCore
import Foundation
import Testing
@testable import CodingRewindApp

private struct DSHAppUnusedCapturer: SelectionCapturing {
    func captureFrontmostSelection() async throws -> CapturedSelection {
        throw RewindError.emptySelection
    }
}

@Suite("DSH app capture watcher and source localization")
@MainActor
struct DSHAppIntegrationTests {
    private func makeTestDir(_ prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-data/\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("DSHCaptureBridgeWatcher drains incoming pill captures into AppCoordinator and writes receipts")
    func watcherDrainsCaptureRequestsAndWritesReceipts() async throws {
        let root = try makeTestDir("dsh-watcher")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StoragePaths(
            dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
            antigravityConfigDirectoryURL: root.appendingPathComponent("Config", isDirectory: true)
        )
        let coord = try AppCoordinator(
            paths: paths,
            environment: [
                StoragePaths.qaEnvironmentKey: "1",
                KeychainTokenStore.disableKeychainFallbackEnvironmentKey: "1"
            ],
            capturer: DSHAppUnusedCapturer()
        )
        let store = try DSHCaptureBridgeStore(dataDirectoryURL: paths.dataDirectoryURL)
        var processedCount = 0
        let watcher = DSHCaptureBridgeWatcher(
            store: store,
            pollInterval: .milliseconds(30),
            handler: { request in
                await coord.captureExternalDSHRequest(request)
            },
            onProcessed: {
                processedCount += 1
            }
        )
        watcher.start()
        defer { watcher.stop() }

        let captureID = UUID().uuidString
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        try store.submit(DSHCaptureBridgeRequest(
            captureId: captureID,
            text: "Clip sent from DSH DOM selection pill",
            sessionId: "sess-pill-7",
            sessionTitle: "DSH Pill Thread",
            messages: [
                DSHSnapshotMessage(role: "user", text: "Prompt for pill test"),
                DSHSnapshotMessage(role: "assistant", text: "Clip sent from DSH DOM selection pill")
            ],
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 30_000
        ))

        for _ in 0..<50 {
            if (try? store.receipt(for: captureID)) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let receipt = try #require(try store.receipt(for: captureID))
        #expect(receipt.state == .queuedOffline)
        #expect(receipt.clipId != nil)
        #expect(processedCount >= 1)
        #expect(coord.cards.first?.sourcePlatform == "dsh")
        #expect(coord.cards.first?.sourceURL == "dsh-session://sess-pill-7")
        #expect(try store.pendingRequests().isEmpty)
    }

    @Test("DSH source locator strings and AppBundleID constants stay distinct from ChatGPT Desktop")
    func dshStringsAndBundleIdentifiers() {
        #expect(AppBundleID.dsh == "com.deepseek.dsh")
        #expect(AppBundleID.chatGPTDesktop == "com.openai.codex")
        #expect(AppStrings.sourceActionButton(for: .dshSession(sessionID: "s1"), in: .zhHans) == "打开原对话")
        #expect(AppStrings.sourceActionButton(for: .dshSession(sessionID: "s1"), in: .en) == "Open Chat")
        #expect(AppStrings.wakeDSHButton(in: .zhHans) == "唤醒 DSH")
        #expect(AppStrings.wakeDSHButton(in: .en) == "Wake DSH")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.dsh)], in: .zhHans) == "需要处理：DSH 插件待安装或修复…")
        #expect(L10n.menuAttentionTitle(issues: [.activeHostPlugin(.dsh)], in: .en) == "Needs Attention: DSH Plugin…")
    }
}

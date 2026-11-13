// SPDX-License-Identifier: MIT

import CodingRewindCore
import Foundation
import Testing

private func message(
    _ role: NativeConversationSnapshot.Message.Role, _ text: String, context: String? = nil
) -> NativeConversationSnapshot.Entry {
    .message(.init(role: role, renderedText: text, contextText: context))
}

private struct NativeSelectionCapturer: SelectionCapturing {
    let selection: CapturedSelection
    func captureFrontmostSelection() async throws -> CapturedSelection { selection }
}

struct NativeConversationContextTests {
    @Test("Native context includes at most four user rounds and stops at the selected message")
    func fourRoundsThroughSelection() throws {
        let entries = (1...6).flatMap { [message(.user, "Question \($0)"), message(.assistant, "Answer \($0)")] }
        let context = try #require(NativeConversationContext.resolve(
            selectedText: "Answer 5", snapshot: .init(entries: entries), sessionTitle: "Current chat"
        ))
        #expect(context.prompt == "Question 5")
        #expect(context.recentTurns.map(\.text) == [
            "Question 2", "Answer 2", "Question 3", "Answer 3", "Question 4", "Answer 4", "Question 5", "Answer 5"
        ])
    }

    @Test("User anchors have no prompt and repeated text needs an observed message anchor")
    func explicitAndUniqueAnchors() throws {
        let entries = [message(.user, "Question one"), message(.assistant, "Repeated"),
                       message(.user, "Question two"), message(.assistant, "Repeated")]
        #expect(NativeConversationContext.resolve(selectedText: "Repeated", snapshot: .init(entries: entries), sessionTitle: "Chat") == nil)
        let explicit = try #require(NativeConversationContext.resolve(
            selectedText: "Repeated", snapshot: .init(entries: entries, anchor: .message(1)), sessionTitle: "Chat"
        ))
        #expect(explicit.prompt == "Question one")
        #expect(explicit.recentTurns.map(\.text) == ["Question one", "Repeated"])
        let user = try #require(NativeConversationContext.resolve(
            selectedText: "Question two", snapshot: .init(entries: entries), sessionTitle: "Chat"
        ))
        #expect(user.prompt.isEmpty)
        #expect(user.recentTurns.last?.text == "Question two")
        #expect(NativeConversationContext.resolve(selectedText: "Repeated", snapshot: .init(entries: entries, anchor: .message(2)), sessionTitle: "Chat") == nil)
    }

    @Test("Context never crosses unavailable messages or guesses an unloaded prompt")
    func continuousInterval() throws {
        let entries = [message(.user, "Old prompt"), message(.assistant, "Old answer"), .gap,
                       message(.assistant, "Orphan answer"), message(.user, "Loaded prompt"), message(.assistant, "Loaded answer")]
        #expect(NativeConversationContext.resolve(selectedText: "Orphan answer", snapshot: .init(entries: entries), sessionTitle: "Chat") == nil)
        let context = try #require(NativeConversationContext.resolve(
            selectedText: "Loaded answer", snapshot: .init(entries: entries), sessionTitle: "Chat"
        ))
        #expect(context.prompt == "Loaded prompt")
        #expect(context.recentTurns.map(\.text) == ["Loaded prompt", "Loaded answer"])
    }

    @Test("Rendered selection matching preserves Markdown context and code whitespace")
    func distinctRenderedAndContextText() throws {
        let markdown = "**Reply**\n\n```swift\nlet x = 1\n\n    print(x)\n```"
        let entries = [message(.user, "Show code"), message(.assistant, "Reply\nlet x = 1\n\n    print(x)", context: markdown)]
        let context = try #require(NativeConversationContext.resolve(
            selectedText: "let x = 1\r\n\r\n    print(x)", snapshot: .init(entries: entries), sessionTitle: "Chat"
        ))
        #expect(context.recentTurns.last?.text == markdown)
        #expect(NativeConversationContext.resolve(selectedText: "let x = 1 print(x)", snapshot: .init(entries: entries), sessionTitle: "Chat") == nil)
    }

    @Test("Native provenance and exact selected text reach the existing offline queue", arguments: [NativeChatHost.chatGPT, .gemini])
    @MainActor
    func nativeOutbox(host: NativeChatHost) async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-context-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("host"))
        let selected = "**Selected code**\n\n    print(1)\n"
        let renderedSelection = "Selected code\n\n    print(1)\n"
        let backlink = try #require(URL(string: host == .chatGPT
            ? "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            : "https://gemini.google.com/app/aaaaaaaaaaaaaaaa"))
        let native = NativeChatCapture(host: host, title: "Current conversation", backlink: backlink,
            snapshot: .init(entries: [message(.user, "Current prompt"), message(.assistant, renderedSelection)]), renderedSelection: renderedSelection)
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: NativeSelectionCapturer(
            selection: CapturedSelection(text: selected, bundleIdentifier: "native.fixture", appName: "Fixture", nativeChat: native)
        ))
        await coordinator.captureSelection()
        let entry = try #require(coordinator.outbox.loadEntries().first)
        #expect(entry.memoContent.contains("#source/\(host.rawValue)"))
        #expect(entry.memoContent.contains("#rewind/has-ctx"))
        #expect(entry.memoContent.hasSuffix(selected))
        #expect(entry.commentContent?.contains("Prompt: Current prompt") == true)
        #expect(coordinator.cards.first?.sourceTitle == "Current conversation")
        #expect(coordinator.cards.first?.sourceURL == backlink.absoluteString)
    }

    @Test("Unmatched native selection keeps verified metadata without an invented context comment")
    @MainActor
    func unmatchedSelection() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-context-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try StoragePaths(dataDirectoryURL: dir, antigravityConfigDirectoryURL: dir.appendingPathComponent("host"))
        let native = NativeChatCapture(host: .chatGPT, title: "Current chat", backlink: URL(string: "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            snapshot: .init(entries: [message(.user, "Other prompt"), message(.assistant, "Other answer")]))
        let coordinator = try AppCoordinator(paths: paths, environment: [StoragePaths.qaEnvironmentKey: "1"], capturer: NativeSelectionCapturer(
            selection: CapturedSelection(text: "Actual selected text", bundleIdentifier: "native.fixture", appName: "Fixture", nativeChat: native)
        ))
        await coordinator.captureSelection()
        let entry = try #require(coordinator.outbox.loadEntries().first)
        #expect(entry.commentContent == nil)
        #expect(!entry.memoContent.contains("#rewind/has-ctx"))
        #expect(coordinator.cards.first?.sourceURL == native.backlink?.absoluteString)
    }
}

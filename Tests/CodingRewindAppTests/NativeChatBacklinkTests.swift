// SPDX-License-Identifier: MIT

@testable import CodingRewindApp
import Testing

@MainActor
struct NativeChatBacklinkTests {
    @Test("Native backlinks accept private conversation routes and reject share pages")
    func privateConversationRoutes() {
        let chat = "https://chatgpt.com/c/6af73726-57f0-83ea-867d-2d978b46c049"
        let projectChat = "https://chatgpt.com/g/g-p-68123abc/c/67fe1234-5678-8001-9abc-def012345678"
        let gemini = "https://gemini.google.com/app/590689084552ffa1?pli=1"
        #expect(NativeChatBacklink.conversationURL(chat, host: .chatGPT)?.absoluteString == chat)
        #expect(NativeChatBacklink.conversationURL(projectChat, host: .chatGPT)?.absoluteString == projectChat)
        #expect(NativeChatBacklink.conversationURL(gemini, host: .gemini)?.absoluteString == gemini)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/share/6af73726-57f0-83ea-867d-2d978b46c049", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/codex/tasks/67fe1234-5678-8001-9abc-def012345678", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/codex/c/67fe1234-5678-8001-9abc-def012345678", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/c/not-a-uuid", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/g/g-p-68123abc/c/not-a-uuid", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://gemini.google.com/share/590689084552ffa1", host: .gemini) == nil)
        #expect(NativeChatBacklink.conversationURL("app://-/index.html", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL(gemini, host: .chatGPT) == nil)
    }
}

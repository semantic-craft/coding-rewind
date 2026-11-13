// SPDX-License-Identifier: MIT

@testable import CodingRewindApp
import Testing

@MainActor
struct NativeChatBacklinkTests {
    @Test("Native backlinks accept private conversation routes and reject share pages")
    func privateConversationRoutes() {
        let chat = "https://chatgpt.com/c/6af73726-57f0-83ea-867d-2d978b46c049"
        let gemini = "https://gemini.google.com/app/590689084552ffa1?pli=1"
        #expect(NativeChatBacklink.conversationURL(chat, host: .chatGPT)?.absoluteString == chat)
        #expect(NativeChatBacklink.conversationURL(gemini, host: .gemini)?.absoluteString == gemini)
        #expect(NativeChatBacklink.conversationURL("https://chatgpt.com/share/6af73726-57f0-83ea-867d-2d978b46c049", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL("https://gemini.google.com/share/590689084552ffa1", host: .gemini) == nil)
        #expect(NativeChatBacklink.conversationURL("app://-/index.html", host: .chatGPT) == nil)
        #expect(NativeChatBacklink.conversationURL(gemini, host: .chatGPT) == nil)
    }
}

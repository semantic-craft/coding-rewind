// SPDX-License-Identifier: MIT

@testable import CodingRewindApp
import CodingRewindCore
import ApplicationServices
import Testing

struct NativeChatCaptureTests {
    @Test("Native ChatGPT selected HTML retains inline Markdown and exact line breaks")
    func selectedHTMLMarkdown() {
        let plain = "REWIND-NATIVE-A-20261114\n第二行：蓝色叶子与 alpha = 42。\n第三行：中文原文保持完整。"
        let html = "<meta charset='utf-8'><span>REWIND-NATIVE-A-20261114</span><br><span>第二行：</span><strong><span>蓝色叶子</span></strong><span>与 </span><code dir=\"ltr\">alpha = 42</code><span>。</span><br><span>第三行：中文原文保持完整。</span>"
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: plain) == "REWIND-NATIVE-A-20261114\n第二行：**蓝色叶子**与 `alpha = 42`。\n第三行：中文原文保持完整。")
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: "A different selection") == nil)
    }

    @Test("Gemini HTML wrapper whitespace is omitted only around the exact copied plain selection")
    func geminiHTMLWrapper() {
        let plain = "REWIND-WEB-QA-20261113-GEMINI\n第二行：绿色叶子与 alpha = 42。\n第三行：中文原文保持完整。"
        let html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, system-ui, sans-serif; font-size: 14px;\">\n  REWIND-WEB-QA-20261113-GEMINI<br>第二行：绿色叶子与 <code style=\"font-family: ui-monospace, monospace;\">alpha = 42</code>。<br>第三行：中文原文保持完整。\n</body></html>"
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: plain) == "REWIND-WEB-QA-20261113-GEMINI\n第二行：绿色叶子与 `alpha = 42`。\n第三行：中文原文保持完整。")
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: "  " + plain) == nil)
        let description = "REWIND-WEB-QA-20261113-GEMINI\n第二行：**绿色叶子**与 alpha = 42。\n第三行：中文原文保持完整。"
        let bold = NativeSelectionMarkdown.boldRanges(description: description, renderedText: plain, selectedText: plain)
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: plain, boldRanges: bold) == description.replacingOccurrences(of: "alpha = 42", with: "`alpha = 42`"))
        let partial = "色叶"
        let partialBold = NativeSelectionMarkdown.boldRanges(description: description, renderedText: plain, selectedText: partial)
        #expect(NativeSelectionMarkdown.convert(html: "<span>色叶</span>", plainText: partial, boldRanges: partialBold) == "**色叶**")
        #expect(NativeSelectionMarkdown.boldRanges(description: description, renderedText: "Different message", selectedText: partial).isEmpty)
    }

    @Test("ChatGPT rendered code preserves token spaces and empty CodeMirror lines")
    func chatGPTCodeLines() {
        let code = NativeChatCodeBlock(lines: [
            ["# REWIND-NATIVE-B-20261114"],
            ["def", " ", "example", "():"],
            ["    ", "return", " ", "\"橙色叶子\""],
            [],
            ["print", "(", "example", "())"]
        ])
        let expected = "# REWIND-NATIVE-B-20261114\ndef example():\n    return \"橙色叶子\"\n\nprint(example())"
        #expect(code.text == expected)
        #expect(NativeSelectionMarkdown.codeBlock(code.text) == "```\n" + expected + "\n```")
        #expect(NativeSelectionMarkdown.codeBlock("    return \"橙色叶子\"\n\n") == "```\n    return \"橙色叶子\"\n\n\n```")
        #expect(NativeSelectionMarkdown.codeBlock("print(\"```\")") == "````\nprint(\"```\")\n````")
    }

    @Test("ChatGPT code surface excludes the observed Ask ChatGPT composer")
    func chatGPTCodeComposerExclusion() {
        #expect(NativeChatCodeBlock.isEditor(role: "AXTextArea", title: "Edit code", classes: ["cm-content"]))
        #expect(!NativeChatCodeBlock.isEditor(role: "AXTextArea", title: "Ask ChatGPT", classes: ["ProseMirror"]))
    }

    @Test("Gemini code attachment retains its actual Markdown and does not match ordinary buttons")
    func geminiCodeAttachment() {
        let markdown = "```python\n# REWIND-NATIVE-GEMINI-B-20261114\ndef example():\n    return \"橙色叶子\"\n\nprint(example())\n\n```\n"
        let code = NativeChatCodeBlock.geminiAttachment(
            identifier: "code-widget-download-button-code-widget-download-button-code-widget-copy-button-code-widget-copy-button",
            description: markdown, renderedText: "\u{fffc}")
        #expect(code?.text == "# REWIND-NATIVE-GEMINI-B-20261114\ndef example():\n    return \"橙色叶子\"\n\nprint(example())\n")
        #expect(code?.markdown == markdown)
        #expect(NativeChatCodeBlock.geminiAttachment(identifier: "copy-button", description: markdown, renderedText: "\u{fffc}") == nil)
    }

    @Test("Gemini mixed attachment selection keeps surrounding text, code whitespace, and explicit language")
    func geminiMixedCodeSelection() {
        let prefix = "REWIND-NATIVE-GEMINI-B-MIXED-20261114\n"
        let code = "# REWIND-NATIVE-GEMINI-B-20261114\ndef example():\n    return \"橙色叶子\"\n\nprint(example())\n"
        let plain = prefix + code + "\n中文结束"
        let markdown = prefix + "```python\n" + code + "\n```\n中文结束\n"
        let attachment = NativeChatCodeBlock.geminiAttachment(
            identifier: "code-widget-download-button-code-widget-download-button-code-widget-copy-button-code-widget-copy-button",
            description: markdown, renderedText: prefix + "\u{fffc}\n中文结束")
        #expect(attachment?.text == plain)
        #expect(attachment?.markdown == markdown)
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head><body style="font-family: -apple-system, system-ui, sans-serif; font-size: 14px;">
          REWIND-NATIVE-GEMINI-B-MIXED-20261114<br><pre style="background-color: #f5f5f5; padding: 12px; border-radius: 6px; overflow-x: auto;"><code class="language-python" style="font-family: ui-monospace, monospace; font-size: 13px;"># REWIND-NATIVE-GEMINI-B-20261114<br>def example():<br>    return &quot;橙色叶子&quot;<br><br>print(example())<br></code></pre><br>中文结束
        </body></html>
        """
        #expect(NativeSelectionMarkdown.convert(html: html, plainText: plain) == String(markdown.dropLast()))
    }

    @Test("ChatGPT code formatting follows the copied message selection after focus moves")
    @MainActor
    func chatGPTCodeSelectionAfterFocusMoves() {
        let code = "# REWIND-NATIVE-B-20261114\ndef example():\n    return \"橙色叶子\"\n\nprint(example())"
        let element = AXUIElementCreateApplication(0)
        let codeMessage = NativeChatAXCapture.ObservedEntry(
            entry: .message(.init(role: .assistant, renderedText: code)), element: element,
            selectedText: "# REWIND-NATIVE-B-20261114def example():    return \"橙色叶子\"\nprint(example())",
            codeBlocks: [code])
        let observation = NativeChatAXCapture.Observation(host: .chatGPT, title: "生成Python代码", window: element,
            messages: [codeMessage])
        #expect(observation.isCodeSelection(code))
        #expect(observation.isCodeSelection("    return \"橙色叶子\"\n\n"))
        #expect(!observation.isCodeSelection(codeMessage.selectedText!))
        let ordinaryMessage = NativeChatAXCapture.ObservedEntry(
            entry: .message(.init(role: .assistant, renderedText: "原文保持完整。")), element: element, selectedText: nil)
        let ordinary = NativeChatAXCapture.Observation(host: .chatGPT, title: "生成Python代码", window: element,
            messages: [ordinaryMessage])
        #expect(!ordinary.isCodeSelection("原文保持完整。"))
    }

    @Test("Installed native chat apps retain their source and conversation titles")
    @MainActor
    func nativeSourceMetadata() {
        #expect(NativeChatAXCapture.host(bundleIdentifier: "com.openai.codex") == .chatGPT)
        #expect(NativeChatAXCapture.host(bundleIdentifier: "com.google.GeminiMacOS") == .gemini)
        #expect(NativeChatAXCapture.host(bundleIdentifier: "com.google.Chrome") == nil)
        #expect(NativeChatAXCapture.title(host: .chatGPT, windowTitle: "  Current Chat  ") == "Current Chat")
        #expect(NativeChatAXCapture.title(host: .gemini, windowTitle: "Gemini - Current Chat") == "Current Chat")
        #expect(NativeChatAXCapture.title(host: .gemini, windowTitle: nil) == "Gemini")
    }
}

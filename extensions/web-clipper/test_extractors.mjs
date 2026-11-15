// SPDX-License-Identifier: MIT

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";

import { parseHtmlDocument } from "./test_dom_shim.mjs";

import {
  detectPlatform,
  cleanSessionTitle,
  buildFallbackClip,
  htmlToMarkdown,
  selectionToMarkdown,
  extractSessionTitle,
  extractConversationTurns,
  extractClipContext
} from "./extractors.mjs";

import "./i18n.js";

import {
  CLIP_ID_PATTERN,
  MAX_OUTBOX_ITEMS,
  getToastMessages,
  generateClipId,
  normalizeMemosBaseUrl,
  buildAuthHeaders,
  buildMemosWirePayloads,
  parseServerMemoId,
  saveClipWithOutbox,
  flushOutbox,
  hasClipContext
} from "./memos_payload.mjs";

const defaultToasts = getToastMessages("auto");

import { initOptionsPage, probeMemosConnection, testMemosConnection } from "./options.js";

function createMemoryOutboxStorage(initial = []) {
  let state = structuredClone(initial);
  return {
    async getOutbox() {
      return structuredClone(state);
    },
    async setOutbox(items) {
      state = structuredClone(items);
    },
    peek() {
      return structuredClone(state);
    }
  };
}

test("detectPlatform and cleanSessionTitle strip provider boilerplate", () => {
  assert.equal(detectPlatform("https://chatgpt.com/c/abc-123"), "chatgpt");
  assert.equal(detectPlatform("https://claude.ai/chat/uuid-1"), "claude");
  assert.equal(detectPlatform("https://gemini.google.com/app/xyz"), "gemini");
  assert.equal(detectPlatform("https://developer.apple.com/documentation"), "web");

  assert.equal(cleanSessionTitle("Swift Concurrency Actor Isolation - ChatGPT"), "Swift Concurrency Actor Isolation");
  assert.equal(cleanSessionTitle("SQLite WAL Tuning - Claude"), "SQLite WAL Tuning");
  assert.equal(cleanSessionTitle("Google Gemini"), "");
  assert.equal(cleanSessionTitle("New chat - ChatGPT"), "");

  assert.deepEqual(
    buildFallbackClip({
      selectedMarkdown: "  exact fallback  ",
      sourceUrl: "https://chatgpt.com/c/abc-123",
      title: "Swift Concurrency Actor Isolation - ChatGPT"
    }),
    {
      selectedMarkdown: "  exact fallback  ",
      sourcePlatform: "chatgpt",
      sessionTitle: "Swift Concurrency Actor Isolation",
      prompt: "",
      recentTurns: "",
      sourceUrl: "https://chatgpt.com/c/abc-123"
    }
  );
  assert.deepEqual(
    extractClipContext({ selectedText: "docless selection", url: "https://claude.ai/chat/1" }),
    {
      selectedMarkdown: "docless selection",
      sourcePlatform: "claude",
      sessionTitle: "",
      prompt: "",
      recentTurns: "",
      sourceUrl: "https://claude.ai/chat/1"
    }
  );
});

test("htmlToMarkdown converts code blocks, copy headers, lists, headings, links, and inline styles", () => {
  const html = `
    <div>
      <h2>Migration Plan</h2>
      <p>Run <code>swift test</code> with <strong>strict</strong> <em>actor</em> checks on <a href="/docs/guide">the guide</a>.</p>
      <ul>
        <li>First step
          <ol start="3">
            <li>Sub-step A</li>
            <li>Sub-step B</li>
          </ol>
        </li>
        <li>Second step with <code>a \`backtick\` inside</code></li>
      </ul>
      <pre>
        <div class="code-header"><span>python</span><button>Copy code</button></div>
        <code class="hljs language-python">def enrich(memo_id: str) -&gt; bool:
    return memo_id.startswith("rw-")</code>
      </pre>
      <blockquote><p>Keep verbatim body untouched.</p></blockquote>
    </div>
  `;

  const md = htmlToMarkdown(html, { baseUrl: "https://chatgpt.com/c/999" });

  assert.match(md, /^## Migration Plan/m);
  assert.match(md, /Run `swift test` with \*\*strict\*\* \*actor\* checks on \[the guide\]\(https:\/\/chatgpt\.com\/docs\/guide\)\./);
  assert.match(md, /- First step\n  3\. Sub-step A\n  4\. Sub-step B\n- Second step with ``a `backtick` inside``/);
  assert.match(md, /```python\ndef enrich\(memo_id: str\) -> bool:\n    return memo_id\.startswith\("rw-"\)\n```/);
  assert.doesNotMatch(md, /Copy code/);
  assert.match(md, /> Keep verbatim body untouched\./);
});

test("ChatGPT semantic inline code survives selection and conversation context", () => {
  const doc = parseHtmlDocument('<div data-message-author-role="assistant"><p id="selected">REWIND-WEB-QA-20261113-CGPT<br>第二行：<strong>绿色叶子</strong>与 <span data-markdown-copy="inline-code" dir="ltr">alpha = 42</span>。<br>第三行：中文原文保持完整。</p></div>');
  const expected = 'REWIND-WEB-QA-20261113-CGPT\n第二行：**绿色叶子**与 `alpha = 42`。\n第三行：中文原文保持完整。';

  assert.equal(selectionToMarkdown(doc.createRangeFromNode(doc.querySelector("#selected"))), expected);
  assert.deepEqual(extractConversationTurns(doc, "chatgpt").map(({ role, text }) => ({ role, text })), [
    { role: "assistant", text: expected }
  ]);
});

test("selectionToMarkdown preserves ancestor fenced code block language on partial code selection", () => {
  const doc = parseHtmlDocument(
    `<pre><code class="language-swift"><span id="sel">let panel = NSPanel()</span>\npanel.isFloatingPanel = true</code></pre>`
  );
  const span = doc.querySelector("#sel");
  const range = doc.createRangeFromNode(span);
  const md = selectionToMarkdown(range, "https://chatgpt.com/c/1");
  assert.equal(md, "```swift\nlet panel = NSPanel()\n```");
});

test("ChatGPT inline code semantics survive text-only and wrapper selections", () => {
  const doc = parseHtmlDocument('<span id="code" data-markdown-copy="inline-code">alpha = 42</span>');
  const code = doc.querySelector("#code");
  const selected = "alpha ";
  const range = {
    commonAncestorContainer: code.childNodes[0],
    cloneContents() { return parseHtmlDocument(selected).body; },
    toString() { return selected; }
  };
  assert.equal(selectionToMarkdown(range), "`alpha `");

  const wrapper = parseHtmlDocument('<span id="wrapper">value <span data-markdown-copy="inline-code">alpha = 42</span></span>');
  assert.equal(selectionToMarkdown(wrapper.createRangeFromNode(wrapper.querySelector("#wrapper"))), "value `alpha = 42`");
});

test("a mixed Selection keeps code whitespace inside its Markdown delimiters", async (t) => {
  const cases = [
    { name: "starts inside code", html: '<span data-markdown-copy="inline-code"> = 42</span> remains. ', expected: "` = 42` remains. " },
    { name: "ends inside code", html: ' Keep <span data-markdown-copy="inline-code">alpha </span>', expected: " Keep `alpha `" }
  ];

  for (const { name, html, expected } of cases) {
    await t.test(name, () => {
      const doc = parseHtmlDocument(`<p>${html}</p>`);
      const range = doc.createRangeFromNode(doc.querySelector("p"));
      const selection = {
        rangeCount: 1,
        isCollapsed: false,
        getRangeAt() { return range; },
        toString() { return range.toString(); }
      };

      assert.equal(selectionToMarkdown(selection), expected);
    });
  }
});

test("rendered Gemini line breaks survive formatted selection and conversation conversion", () => {
  const html = '<p><span>REWIND-QA-GEMINI-20261113\n中文原文保真 Alpha 42\n</span><b>加粗测试</b><span> 与 </span><code>sample_code</code></p>';
  const doc = parseHtmlDocument(html);
  const paragraph = doc.querySelector("p");
  const attachDocument = (node) => {
    node.ownerDocument = doc;
    for (const child of node.childNodes) attachDocument(child);
  };
  attachDocument(paragraph);
  let whiteSpace = "pre-wrap";
  doc.defaultView = { getComputedStyle() { return { whiteSpace }; } };
  const range = {
    commonAncestorContainer: paragraph,
    startContainer: paragraph,
    startOffset: 0,
    endContainer: paragraph,
    endOffset: paragraph.childNodes.length,
    intersectsNode(node) { return paragraph.contains(node); },
    cloneContents() { return parseHtmlDocument(html).querySelector("p"); },
    toString() { return paragraph.textContent; }
  };
  const expected = 'REWIND-QA-GEMINI-20261113\n中文原文保真 Alpha 42\n**加粗测试** 与 `sample_code`';
  assert.equal(selectionToMarkdown(range), expected);
  assert.equal(htmlToMarkdown(paragraph), expected);
  whiteSpace = "normal";
  assert.equal(selectionToMarkdown(range), expected.replaceAll("\n", " "));
  assert.equal(htmlToMarkdown(paragraph), expected.replaceAll("\n", " "));
});

test("selectionToMarkdown preserves selected plain text boundaries", () => {
  const plainOnlySelection = {
    rangeCount: 0,
    isCollapsed: true,
    getRangeAt() {
      throw new Error("no range");
    },
    toString() {
      return "  fallback plain text  ";
    }
  };
  assert.equal(selectionToMarkdown(plainOnlySelection), "  fallback plain text  ");
  assert.equal(selectionToMarkdown("  first line\nsecond line \n"), "  first line\nsecond line \n");
  assert.equal(selectionToMarkdown(" \n\t "), "");
});

test("selectionToMarkdown preserves a plain Range without Markdown structure", () => {
  const selectedText = "  first line\nsecond line  \n";
  const doc = parseHtmlDocument(`<span id="plain">${selectedText}</span>`);
  const range = doc.createRangeFromNode(doc.querySelector("#plain"));
  assert.equal(selectionToMarkdown(range), selectedText);
});

test("selectionToMarkdown preserves selected code block boundaries", () => {
  const originalCode = "\n    let count = 1;  \n";
  const codeDoc = parseHtmlDocument(`<pre><code id="raw-code" class="language-swift">${originalCode}</code></pre>`);
  const codeRange = codeDoc.createRangeFromNode(codeDoc.querySelector("#raw-code"));
  assert.equal(selectionToMarkdown(codeRange), `\`\`\`swift\n${originalCode}\n\`\`\``);

  const inlineCodeDoc = parseHtmlDocument(`<code id="inline-code">  inline value  </code>`);
  const inlineCodeRange = inlineCodeDoc.createRangeFromNode(inlineCodeDoc.querySelector("#inline-code"));
  assert.equal(selectionToMarkdown(inlineCodeRange), "`   inline value   `");
});

test("selectionToMarkdown preserves blank lines inside a whole code block selected with prose", () => {
  const code = "first_call()  \n\n\nsecond_call()\t";
  const doc = parseHtmlDocument(`<section id="selection"><p>Keep the code spacing.</p><pre><code class="language-python">${code}</code></pre></section>`);

  assert.equal(
    selectionToMarkdown(doc.createRangeFromNode(doc.querySelector("code"))),
    `\`\`\`python\n${code}\n\`\`\``
  );
  assert.equal(
    selectionToMarkdown(doc.createRangeFromNode(doc.querySelector("#selection"))),
    `Keep the code spacing.\n\n\`\`\`python\n${code}\n\`\`\``
  );
  assert.equal(htmlToMarkdown("<p>First.</p><p></p><p>Second.</p>"), "First.\n\nSecond.");
});

test("background save response does not claim an offline clip is queued after storage rejects", async (t) => {
  const originalChrome = globalThis.chrome;
  const originalSelf = globalThis.self;
  const originalFetch = globalThis.fetch;
  t.after(() => {
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (originalSelf === undefined) delete globalThis.self;
    else globalThis.self = originalSelf;
    globalThis.fetch = originalFetch;
  });

  let onMessage;
  let onContextMenu;
  let onCommand;
  let onToast;
  let storageWrites = 0;
  let fetchCalls = 0;
  let rejectWrites = true;
  let rejectReads = false;
  const clip = { clipId: "rw-storage-failure", selectedMarkdown: "Keep this unsaved draft.", sourcePlatform: "web" };
  const tab = { id: 42 };
  const persistedOutbox = [];
  const ignoredEvent = { addListener() {} };
  globalThis.chrome = {
    runtime: {
      onInstalled: ignoredEvent,
      onStartup: ignoredEvent,
      onMessage: { addListener(listener) { onMessage = listener; } }
    },
    contextMenus: { onClicked: { addListener(listener) { onContextMenu = listener; } } },
    commands: { onCommand: { addListener(listener) { onCommand = listener; } } },
    tabs: {
      async query() { return [tab]; },
      async sendMessage(_tabId, message) {
        if (message.type === "REWIND_EXTRACT_SELECTION") return { clip };
        if (message.type === "REWIND_SHOW_TOAST") onToast(message);
      }
    },
    storage: {
      local: {
        async get() {
          if (rejectReads) throw new Error("Storage unavailable");
          return { memosUrl: "https://memos.invalid", memosToken: "", outbox: structuredClone(persistedOutbox) };
        },
        async set({ outbox }) {
          storageWrites += 1;
          if (rejectWrites) throw new Error("QUOTA_BYTES quota exceeded");
          persistedOutbox.splice(0, persistedOutbox.length, ...structuredClone(outbox));
        }
      }
    }
  };
  globalThis.self = { addEventListener() {} };
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("Network unavailable");
  };
  await import("./background.js?storage-rejection-regression");

  const response = await new Promise((resolve) => {
    assert.equal(onMessage({
      type: "REWIND_SAVE_CLIP",
      clip
    }, {}, resolve), true);
  });

  assert.equal(fetchCalls, 1);
  assert.equal(storageWrites, 1);
  assert.deepEqual(persistedOutbox, []);
  assert.equal(response.status, "error", "a failed storage write must not be reported as queued");
  assert.equal(response.queued, false);
  assert.match(response.toast, /保存失败|Save failed/);

  rejectWrites = false;
  const queued = await new Promise((resolve) => onMessage({ type: "REWIND_SAVE_CLIP", clip }, {}, resolve));
  assert.equal(queued.status, "queued");
  assert.equal(queued.queued, true);
  assert.equal(queued.toast, defaultToasts.QUEUED);
  assert.equal(persistedOutbox.length, 1);
  assert.equal(persistedOutbox[0].clipId, clip.clipId);

  persistedOutbox.length = 0;
  rejectWrites = true;
  const contextMenuToast = new Promise((resolve) => { onToast = resolve; });
  onContextMenu({ menuItemId: "save-to-coding-rewind" }, tab);
  assert.equal((await contextMenuToast).status, "error");

  const commandToast = new Promise((resolve) => { onToast = resolve; });
  await onCommand("save-selection");
  assert.equal((await commandToast).status, "error");

  rejectReads = true;
  const readFailure = await new Promise((resolve) => onMessage({ type: "REWIND_SAVE_CLIP", clip }, {}, resolve));
  assert.equal(readFailure.status, "error");
  assert.equal(readFailure.queued, false);
});

test("selected text excludes ChatGPT copy-excluded footers while preserving Markdown and selection boundaries", async (t) => {
  for (const formatted of [false, true]) {
    await t.test(formatted ? "formatted selection" : "plain selection", () => {
      const selectedText = "Keep only the selected sentence.\n\n";
      const sentence = formatted ? "<strong>Keep only the selected sentence.</strong>" : "<span>Keep only the selected sentence.</span>";
      const doc = parseHtmlDocument(`
        <div id="selection-region">
          <p>${sentence}</p>
          <div data-markdown-copy="exclude" class="select-none">
            <div data-markdown-copy="exclude">ChatGPT may make mistakes. Check important information.</div>
          </div>
        </div>
      `);
      const range = doc.createRangeFromNode(doc.querySelector("#selection-region"));
      assert.match(range.toString(), /Check important information/);

      const ctx = extractClipContext({ doc, selectionRange: range, selectedText, url: "https://chatgpt.com/c/boundaries" });
      assert.equal(ctx.selectedMarkdown, formatted ? "**Keep only the selected sentence.**\n\n" : selectedText);
    });
  }
});

test("ChatGPT context keeps four user-led rounds through the selected assistant block", () => {
  const url = "https://chatgpt.com/c/67f0a1b2-3344";
  const doc = parseHtmlDocument(
    `
    <html>
      <head><title>Non-Activating NSPanel HUD - ChatGPT</title></head>
      <body>
        <nav>
          <a href="/c/old">Older Thread</a>
          <a href="/c/67f0a1b2-3344" aria-current="page">Non-Activating NSPanel HUD</a>
        </nav>
        <main>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 1 user question</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 1 assistant reply</p></div></div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 2 user question</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 2 assistant reply</p></div></div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 3 user question</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 3 assistant reply</p></div></div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 4 user question</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 4 assistant reply</p></div></div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">How do I keep NSPanel from stealing focus?</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 5 assistant preface</p></div></div>
          <div data-message-author-role="assistant">
            <div class="markdown">
              <p>Use <code>.nonactivatingPanel</code> in your style mask:</p>
              <div id="picked">
                <pre><code class="language-swift">panel.styleMask.insert(.nonactivatingPanel)</code></pre>
              </div>
            </div>
          </div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 5 later assistant block</p></div></div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 6 later follow-up</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 6 later answer</p></div></div>
        </main>
      </body>
    </html>
    `,
    { url }
  );

  const picked = doc.querySelector("#picked");
  const range = doc.createRangeFromNode(picked);

  const ctx = extractClipContext({ doc, selectionRange: range, url });

  assert.equal(ctx.sourcePlatform, "chatgpt");
  assert.equal(ctx.sessionTitle, "Non-Activating NSPanel HUD");
  assert.equal(ctx.sourceUrl, url);
  assert.equal(ctx.prompt, "How do I keep NSPanel from stealing focus?");
  assert.equal(ctx.selectedMarkdown, "```swift\npanel.styleMask.insert(.nonactivatingPanel)\n```");

  assert.equal(ctx.recentTurns, [
    "User: Turn 2 user question",
    "Assistant: Turn 2 assistant reply",
    "User: Turn 3 user question",
    "Assistant: Turn 3 assistant reply",
    "User: Turn 4 user question",
    "Assistant: Turn 4 assistant reply",
    "User: How do I keep NSPanel from stealing focus?",
    "Assistant: Turn 5 assistant preface",
    "Assistant: Use `.nonactivatingPanel` in your style mask:\n\n" + ctx.selectedMarkdown
  ].join("\n\n"));
});

test("ChatGPT keeps a selected user message in recent rounds without attaching a preceding prompt", () => {
  const doc = parseHtmlDocument(`
    <div data-message-author-role="user">First question?</div>
    <div data-message-author-role="assistant">First answer.</div>
    <div data-message-author-role="user" id="picked">Next question?</div>
    <div data-message-author-role="assistant">Later answer.</div>
  `, { url: "https://chatgpt.com/c/selected-question" });
  const range = doc.createRangeFromNode(doc.querySelector("#picked"));
  const ctx = extractClipContext({ doc, selectionRange: range });
  assert.equal(ctx.selectedMarkdown, "Next question?");
  assert.equal(ctx.prompt, "");
  assert.equal(ctx.recentTurns, "User: First question?\n\nAssistant: First answer.\n\nUser: Next question?");
});

test("ChatGPT saves page text outside a message without attaching nearby chat context", () => {
  const doc = parseHtmlDocument(`
    <div data-message-author-role="user">First question?</div>
    <div data-message-author-role="assistant">First answer.</div>
    <aside id="picked">Text outside the chat.</aside>
    <div data-message-author-role="user">Later question?</div>
  `, { url: "https://chatgpt.com/c/outside-message" });
  const selectionRange = doc.createRangeFromNode(doc.querySelector("#picked"));

  const ctx = extractClipContext({ doc, selectionRange });
  assert.equal(ctx.selectedMarkdown, "Text outside the chat.");
  assert.equal(ctx.prompt, "");
  assert.equal(ctx.recentTurns, "");
});

test("ChatGPT saves a selection spanning messages without attaching context to either message", () => {
  const doc = parseHtmlDocument(
    '<main><div data-message-author-role="user">A question?</div><div data-message-author-role="assistant">An answer.</div></main>',
    { url: "https://chatgpt.com/c/spanning-messages" }
  );
  const main = doc.querySelector("main");
  const startContainer = main.children[0].childNodes[0];
  const endContainer = main.children[1].childNodes[0];
  const selectionRange = {
    ...doc.createRangeFromNode(main),
    startContainer,
    startOffset: 0,
    endContainer,
    endOffset: endContainer.nodeValue.length,
    toString() { return "A question?\n\nAn answer."; }
  };

  const ctx = extractClipContext({ doc, selectionRange });
  assert.equal(ctx.selectedMarkdown, "A question?\n\nAn answer.");
  assert.equal(ctx.prompt, "");
  assert.equal(ctx.recentTurns, "");
});

test("ChatGPT role headings preserve separate messages inside shared turn containers", () => {
  const url = "https://chatgpt.com/c/role-heading-chat";
  const doc = parseHtmlDocument(`
    <html>
      <head><title>Keep nearby context - ChatGPT</title></head>
      <body><main>
        <div data-talvt-turn-state="complete" class="group flex flex-col">
          <div class="BQZwFn7g">
            <h4 data-conversation-role="user">你说：你</h4>
            <div><div class="whitespace-pre-wrap">How do I save a snippet?</div></div>
          </div>
          <div data-content-search-unit-key="fallback-turn-1:2:assistant">
            <h4 data-conversation-role="assistant">ChatGPT 说：ChatGPT</h4>
            <div><div data-markdown-text-style="assistant-message"><p>Select the text and save it.</p></div></div>
          </div>
        </div>
        <div data-talvt-turn-state="complete" class="group flex flex-col">
          <div class="BQZwFn7g">
            <h4 data-conversation-role="user">You said: You</h4>
            <div><div class="whitespace-pre-wrap">Can it preserve the nearby question?</div></div>
          </div>
          <div data-content-search-unit-key="fallback-turn-2:2:assistant">
            <h4 data-conversation-role="assistant">ChatGPT said: ChatGPT</h4>
            <div><div data-markdown-text-style="assistant-message"><p id="new-chatgpt-pick">Keep the <strong>nearby question</strong> with the snippet.</p></div></div>
          </div>
        </div>
      </main></body>
    </html>
  `, { url });

  const turns = extractConversationTurns(doc, "chatgpt", url);
  assert.deepEqual(turns.map(({ role, text }) => ({ role, text })), [
    { role: "user", text: "How do I save a snippet?" },
    { role: "assistant", text: "Select the text and save it." },
    { role: "user", text: "Can it preserve the nearby question?" },
    { role: "assistant", text: "Keep the **nearby question** with the snippet." }
  ]);

  const range = doc.createRangeFromNode(doc.querySelector("#new-chatgpt-pick"));
  const ctx = extractClipContext({ doc, selectionRange: range, url });
  assert.equal(ctx.prompt, "Can it preserve the nearby question?");
  assert.equal(ctx.selectedMarkdown, "Keep the **nearby question** with the snippet.");
  assert.equal(ctx.recentTurns,
    "User: How do I save a snippet?\n\n" +
    "Assistant: Select the text and save it.\n\n" +
    "User: Can it preserve the nearby question?\n\n" +
    "Assistant: Keep the **nearby question** with the snippet."
  );
});

test("Claude DOM extraction deduplicates nested message containers and enforces 4000-char recentTurns cap", () => {
  const url = "https://claude.ai/chat/9b8c7d6e";
  const longText = "A".repeat(2600);
  const doc = parseHtmlDocument(
    `
    <html>
      <head><title>Standard Webhooks HMAC - Claude</title></head>
      <body>
        <header><button data-testid="chat-title-button">Standard Webhooks HMAC Verification</button></header>
        <div data-testid="user-message"><p>${longText}</p></div>
        <div data-testid="assistant-message">
          <div class="font-claude-message"><p>${longText}</p></div>
        </div>
        <div data-testid="user-message"><p>Why does Memos block private webhook IPs?</p></div>
        <div data-testid="assistant-message">
          <div class="font-claude-message">
            <p id="claude-pick">Memos blocks RFC1918 targets in its webhook dispatcher for SSRF protection, so pair webhook wakeups with an internal reconciliation poll.</p>
          </div>
        </div>
      </body>
    </html>
    `,
    { url }
  );

  const turns = extractConversationTurns(doc, "claude", url);
  assert.equal(turns.length, 4);

  const range = doc.createRangeFromNode(doc.querySelector("#claude-pick"));
  const ctx = extractClipContext({ doc, selectionRange: range, url, maxRecentChars: 4000 });

  assert.equal(ctx.sourcePlatform, "claude");
  assert.equal(ctx.sessionTitle, "Standard Webhooks HMAC Verification");
  assert.equal(ctx.prompt, "Why does Memos block private webhook IPs?");
  assert.ok(ctx.recentTurns.length <= 4000, `Expected <= 4000 chars, got ${ctx.recentTurns.length}`);
  assert.match(ctx.recentTurns, /Why does Memos block private webhook IPs\?/);
  assert.match(ctx.recentTurns, /A…/);
});

test("Gemini DOM extraction parses custom elements and cleans Google Gemini boilerplate", () => {
  const url = "https://gemini.google.com/app/4f5e6d7c";
  const doc = parseHtmlDocument(
    `
    <html>
      <head><title>Google Gemini</title></head>
      <body>
        <aside><div class="selected"><span class="conversation-title">MV3 Service Worker Outbox</span></div></aside>
        <user-query><div class="user-query-text">How do we make MV3 retries idempotent against Memos?</div></user-query>
        <model-response>
          <message-content id="gemini-pick">
            <p>Pass a deterministic <code>memoId</code> query parameter to <code>POST /api/memos</code>.</p>
          </message-content>
        </model-response>
      </body>
    </html>
    `,
    { url }
  );

  const range = doc.createRangeFromNode(doc.querySelector("#gemini-pick"));
  const ctx = extractClipContext({ doc, selectionRange: range, url });

  assert.equal(ctx.sourcePlatform, "gemini");
  assert.equal(ctx.sessionTitle, "MV3 Service Worker Outbox");
  assert.equal(ctx.prompt, "How do we make MV3 retries idempotent against Memos?");
  assert.equal(
    ctx.selectedMarkdown,
    "Pass a deterministic `memoId` query parameter to `POST /api/memos`."
  );
  assert.match(ctx.recentTurns, /^User: How do we make MV3 retries idempotent against Memos\?\n\nAssistant: Pass a deterministic `memoId`/);
});

test("Gemini context excludes the duplicate screen reader prompt label and keeps normal headings", () => {
  const url = "https://gemini.google.com/app/prompt-label";
  const doc = parseHtmlDocument('<user-query><div class="query-text"><h5 class="cdk-visually-hidden screen-reader-user-query-label"><span>You said</span> 请保留完整…</h5><p class="query-text-line">请保留完整提问。</p><h5>用户标题</h5></div></user-query><model-response><message-content><p id="answer">原样保留。</p></message-content></model-response>');
  const ctx = extractClipContext({ doc, selectionRange: doc.createRangeFromNode(doc.querySelector("#answer")), url });

  assert.equal(ctx.prompt, "请保留完整提问。\n\n##### 用户标题");
  assert.equal(ctx.recentTurns, "User: 请保留完整提问。\n\n##### 用户标题\n\nAssistant: 原样保留。");
});

test("buildMemosWirePayloads matches exact canonical wire contract with and without context", () => {
  const clipId = generateClipId(1794366666123, () => 0.42);
  assert.match(clipId, CLIP_ID_PATTERN);
  assert.match(`${clipId}-ctx`, CLIP_ID_PATTERN);

  const withCtx = buildMemosWirePayloads(
    {
      selectedMarkdown: "```swift\nlet ok = true\n```",
      sourcePlatform: "chatgpt",
      sessionTitle: "Swift Snippet",
      prompt: "Show a minimal flag",
      recentTurns: "User: Show a minimal flag\n\nAssistant: ```swift\nlet ok = true\n```",
      sourceUrl: "https://chatgpt.com/c/123"
    },
    { clipId, createdAt: "2026-11-11T03:15:00Z" }
  );

  assert.equal(withCtx.hasContext, true);
  assert.equal(withCtx.memoPath, `/api/memos?memoId=${clipId}`);
  assert.deepEqual(withCtx.memoBody, {
    content:
      "#rewind/pending #rewind/has-ctx #source/chatgpt\n\n" +
      "> **Source:** [Swift Snippet](https://chatgpt.com/c/123) · 2026-11-11T03:15:00Z\n\n" +
      "```swift\nlet ok = true\n```",
    visibility: "PRIVATE"
  });
  assert.equal(withCtx.commentPathForServerId("9876"), `/api/memos/9876/comments?commentId=${clipId}-ctx`);
  assert.deepEqual(withCtx.commentBody, {
    content:
      "<!-- rewind-context-v1 -->\n" +
      "Session Title: Swift Snippet\n" +
      "Prompt: Show a minimal flag\n\n" +
      "### Recent Turns\n" +
      "User: Show a minimal flag\n\nAssistant: ```swift\nlet ok = true\n```",
    visibility: "PRIVATE"
  });

  const withoutCtx = buildMemosWirePayloads(
    {
      selectedMarkdown: "Standalone paragraph",
      sourcePlatform: "web",
      sessionTitle: "",
      prompt: "",
      recentTurns: "",
      sourceUrl: "https://example.org/notes"
    },
    { clipId: "rw-1794366666123-plain001", createdAt: "2026-11-11T03:16:00Z", locale: "zh-CN" }
  );

  assert.equal(withoutCtx.hasContext, false);
  assert.equal(withoutCtx.commentBody, null);
  assert.doesNotMatch(withoutCtx.memoBody.content, /#rewind\/has-ctx/);
  assert.match(withoutCtx.memoBody.content, /^#rewind\/pending #source\/web\n\n> \*\*Source:\*\* \[未命名对话\]\(https:\/\/example\.org\/notes\) · 2026-11-11T03:16:00Z\n\nStandalone paragraph$/);

  const withoutCtxEn = buildMemosWirePayloads(
    {
      selectedMarkdown: "Standalone paragraph",
      sourcePlatform: "ChatGPT",
      sessionTitle: "",
      prompt: "",
      recentTurns: "",
      sourceUrl: "https://chatgpt.com/c/untitled"
    },
    { clipId: "rw-1794366666123-plain002", createdAt: "2026-11-11T03:16:00Z", locale: "en" }
  );
  assert.match(
    withoutCtxEn.memoBody.content,
    /^#rewind\/pending #source\/chatgpt\n\n> \*\*Source:\*\* \[Untitled Session\]\(https:\/\/chatgpt\.com\/c\/untitled\) · 2026-11-11T03:16:00Z\n\nStandalone paragraph$/
  );
  assert.equal(parseServerMemoId({ name: "memos/abc999" }), "abc999");
});

test("buildMemosWirePayloads validates selected text without trimming its contents", () => {
  const selectedMarkdown = "\n  let count = 1;  \n";
  const payload = buildMemosWirePayloads(
    { selectedMarkdown, sourcePlatform: "web" },
    { clipId: "rw-1794366666123-preserve01", createdAt: "2026-11-11T03:16:00Z" }
  );

  assert.ok(payload.memoBody.content.endsWith(selectedMarkdown));
  assert.throws(
    () => buildMemosWirePayloads({ selectedMarkdown: " \n\t " }),
    /selectedMarkdown must not be empty/
  );
});

test("general web page clip keeps Source title link without setting #rewind/has-ctx or posting an empty context comment", async () => {
  const sourceUrl = "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html";
  const clip = {
    selectedMarkdown: "Each value in Rust has an **owner**.",
    sourcePlatform: "web",
    sessionTitle: "Rust Ownership Guide",
    prompt: "",
    recentTurns: "",
    sourceUrl
  };

  assert.equal(hasClipContext(clip), false);
  const built = buildMemosWirePayloads(clip, {
    clipId: "rw-1794366666123-rustbook1",
    createdAt: "2026-11-15T04:00:00Z"
  });

  assert.equal(built.hasContext, false);
  assert.equal(built.commentBody, null);
  assert.doesNotMatch(built.memoBody.content, /#rewind\/has-ctx/);
  assert.equal(
    built.memoBody.content,
    "#rewind/pending #source/web\n\n" +
      `> **Source:** [Rust Ownership Guide](${sourceUrl}) · 2026-11-15T04:00:00Z\n\n` +
      "Each value in Rust has an **owner**."
  );

  const storage = createMemoryOutboxStorage();
  const requests = [];
  const res = await saveClipWithOutbox({
    clip,
    baseUrl: "https://memos.internal.test",
    token: "tok-web",
    storage,
    nowMs: 1794366666123,
    randomFn: () => 0.5,
    fetchImpl: async (reqUrl, init) => {
      requests.push({ url: reqUrl, method: init.method });
      return {
        ok: true,
        status: 200,
        async json() {
          return { name: "memos/web-srv-1" };
        }
      };
    }
  });

  assert.equal(res.status, "saved");
  assert.equal(requests.length, 1);
  assert.match(requests[0].url, /^https:\/\/memos\.internal\.test\/api\/memos\?memoId=/);
  assert.equal(requests.some((r) => r.url.includes("/comments")), false);
});

test("buildMemosWirePayloads blocks unsafe URL schemes and percent-encodes parentheses", () => {
  for (const unsafeUrl of ["javascript:alert(1)", "java\nscript:alert(1)", "data:text/html,hi", "vbscript:run"]) {
    const payload = buildMemosWirePayloads(
      {
        selectedMarkdown: "Safe body",
        sourcePlatform: "web",
        sessionTitle: "Untrusted Title",
        sourceUrl: unsafeUrl
      },
      { clipId: "rw-1700000000000-sec00001", createdAt: "2026-11-15T08:00:00Z" }
    );
    assert.match(payload.memoBody.content, /> \*\*Source:\*\* Untrusted Title · 2026-11-15T08:00:00Z/);
    assert.doesNotMatch(payload.memoBody.content, /javascript:|vbscript:|data:/i);
  }

  const wikiPayload = buildMemosWirePayloads(
    {
      selectedMarkdown: "Safe body",
      sourcePlatform: "web",
      sessionTitle: "Closure",
      sourceUrl: "https://en.wikipedia.org/wiki/Closure_(computer_programming)"
    },
    { clipId: "rw-1700000000000-sec00002", createdAt: "2026-11-15T08:00:00Z" }
  );
  assert.match(
    wikiPayload.memoBody.content,
    /> \*\*Source:\*\* \[Closure\]\(https:\/\/en\.wikipedia\.org\/wiki\/Closure_%28computer_programming%29\) · 2026-11-15T08:00:00Z/
  );
});

test("saveClipWithOutbox queues malformed successful responses for same-ID replay", async (t) => {
  const malformedResponseCases = [
    {
      name: "invalid JSON",
      response: {
        ok: true,
        status: 201,
        async json() {
          throw new SyntaxError("invalid JSON response");
        }
      }
    },
    {
      name: "missing memo name",
      response: { ok: true, status: 201, async json() { return {}; } }
    }
  ];

  for (let i = 0; i < malformedResponseCases.length; i += 1) {
    const malformedCase = malformedResponseCases[i];
    await t.test(malformedCase.name, async () => {
      const storage = createMemoryOutboxStorage();
      const selectedMarkdown = `\n  preserved ${malformedCase.name}  \n`;
      const clip = {
        selectedMarkdown,
        sourcePlatform: "chatgpt",
        sessionTitle: "Retry malformed response",
        prompt: "How should a malformed success response retry?",
        recentTurns: "User: How should a malformed success response retry?\n\nAssistant: Reuse the same memo ID.",
        sourceUrl: "https://chatgpt.com/c/retry-malformed"
      };
      const calls = [];
      let memoPostCount = 0;
      const fetchImpl = async (requestUrl, init) => {
        const url = new URL(requestUrl);
        const body = init.body ? JSON.parse(init.body) : null;
        calls.push({ method: init.method, pathname: url.pathname, memoId: url.searchParams.get("memoId"), body });

        if (init.method === "POST" && url.pathname === "/api/memos" && url.searchParams.has("memoId")) {
          memoPostCount += 1;
          return memoPostCount === 1
            ? malformedCase.response
            : { ok: false, status: 409, async json() { return {}; } };
        }
        if (init.method === "GET" && url.pathname.startsWith("/api/memos/")) {
          return { ok: true, status: 200, async json() { return { name: "memos/server-recovered" }; } };
        }
        if (init.method === "POST" && url.pathname.endsWith("/comments")) {
          return { ok: true, status: 201, async json() { return { name: "memos/server-recovered/comments/1" }; } };
        }
        throw new Error(`Unexpected request ${init.method} ${url.pathname}`);
      };

      const saved = await saveClipWithOutbox({
        clip,
        baseUrl: "https://memos.internal.test",
        token: "test-token",
        storage,
        fetchImpl,
        nowMs: 1794366900000 + i,
        randomFn: () => 0.4
      });

      assert.equal(saved.status, "queued");
      assert.equal(saved.queued, true);
      assert.equal(storage.peek().length, 1);
      assert.equal(storage.peek()[0].clipId, saved.clipId);
      assert.ok(storage.peek()[0].memoBody.content.endsWith(selectedMarkdown));

      const flushed = await flushOutbox({
        baseUrl: "https://memos.internal.test",
        token: "test-token",
        storage,
        fetchImpl
      });

      assert.deepEqual(flushed, { flushed: 1, remaining: 0 });
      assert.equal(storage.peek().length, 0);
      const memoPosts = calls.filter((call) => call.method === "POST" && call.pathname === "/api/memos");
      assert.equal(memoPosts.length, 2);
      assert.deepEqual(memoPosts.map((call) => call.memoId), [saved.clipId, saved.clipId]);
      assert.equal(calls.filter((call) => call.method === "GET").length, 1);
      const commentPosts = calls.filter((call) => call.pathname.endsWith("/comments"));
      assert.equal(commentPosts.length, 1);
      assert.equal(commentPosts[0].pathname, "/api/memos/server-recovered/comments");
    });
  }
});

test("saveClipWithOutbox handles unconfigured URL, HTTP 5xx offline queue, 50-item cap, and idempotent retry", async () => {
  const storage = createMemoryOutboxStorage();
  const sampleClip = {
    selectedMarkdown: "Idempotent capture test",
    sourcePlatform: "claude",
    sessionTitle: "Retry Session",
    prompt: "Test retry?",
    recentTurns: "User: Test retry?\n\nAssistant: Idempotent capture test",
    sourceUrl: "https://claude.ai/chat/retry-1"
  };

  const unconfiguredRes = await saveClipWithOutbox({
    clip: sampleClip,
    baseUrl: "",
    token: "",
    storage,
    nowMs: 1794366666001,
    randomFn: () => 0.1
  });
  assert.equal(unconfiguredRes.status, "unconfigured");
  assert.equal(unconfiguredRes.toast, defaultToasts.UNCONFIGURED);
  assert.equal(storage.peek().length, 1);
  const firstClipId = unconfiguredRes.clipId;

  const calls = [];
  let failNetwork = true;
  const mockFetch = async (reqUrl, init) => {
    calls.push({ url: reqUrl, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : null });
    if (failNetwork) {
      return { ok: false, status: 503, async json() { return {}; } };
    }
    if (reqUrl.includes("/comments?")) {
      return { ok: true, status: 200, async json() { return { name: "memos/srv-1/comments/1" }; } };
    }
    const u = new URL(reqUrl);
    const memoId = u.searchParams.get("memoId");
    return { ok: true, status: 200, async json() { return { name: `memos/srv-${memoId}` }; } };
  };

  const offlineRes = await saveClipWithOutbox({
    clip: { ...sampleClip, selectedMarkdown: "Second clip while 503" },
    baseUrl: "https://memos.internal.test/",
    token: "test-token",
    storage,
    fetchImpl: mockFetch,
    nowMs: 1794366666002,
    randomFn: () => 0.2
  });

  assert.equal(offlineRes.status, "queued");
  assert.equal(offlineRes.toast, defaultToasts.QUEUED);
  assert.equal(storage.peek().length, 2);

  failNetwork = false;
  const flushRes = await flushOutbox({
    baseUrl: "https://memos.internal.test/api/v1",
    token: "test-token",
    storage,
    fetchImpl: mockFetch
  });

  assert.equal(flushRes.flushed, 2);
  assert.equal(flushRes.remaining, 0);
  assert.equal(storage.peek().length, 0);

  const retriedFirstMemoCall = calls.filter(
    (c) => c.url === `https://memos.internal.test/api/memos?memoId=${encodeURIComponent(firstClipId)}`
  );
  assert.equal(retriedFirstMemoCall.length, 2);
  assert.equal(retriedFirstMemoCall[1].headers.Authorization, "Bearer test-token");

  const retriedFirstCommentCall = calls.find(
    (c) => c.url === `https://memos.internal.test/api/memos/srv-${firstClipId}/comments?commentId=${encodeURIComponent(`${firstClipId}-ctx`)}`
  );
  assert.ok(retriedFirstCommentCall, "Expected comment POST with serverId parsed from resp.name");

  const capStorage = createMemoryOutboxStorage();
  for (let i = 0; i < 55; i += 1) {
    await saveClipWithOutbox({
      clip: { ...sampleClip, selectedMarkdown: `Item ${i}` },
      baseUrl: "",
      token: "",
      storage: capStorage,
      nowMs: 1794366700000 + i,
      randomFn: () => (i % 30) / 36
    });
  }
  assert.equal(capStorage.peek().length, MAX_OUTBOX_ITEMS);
  assert.match(capStorage.peek()[0].memoBody.content, /Item 5$/);
  assert.match(capStorage.peek()[49].memoBody.content, /Item 54$/);

  const partialStorage = createMemoryOutboxStorage();
  let commentShouldFail = true;
  const partialCalls = [];
  const partialFetch = async (reqUrl, init) => {
    partialCalls.push({ url: reqUrl, method: init.method });
    if (reqUrl.includes("/comments?")) {
      if (commentShouldFail) {
        return { ok: false, status: 502, async json() { return {}; } };
      }
      return { ok: true, status: 200, async json() { return { name: "memos/srv-partial/comments/1" }; } };
    }
    return { ok: true, status: 200, async json() { return { name: "memos/srv-partial" }; } };
  };

  const partialSave = await saveClipWithOutbox({
    clip: sampleClip,
    baseUrl: "https://memos.internal.test",
    token: "test-token",
    storage: partialStorage,
    fetchImpl: partialFetch,
    nowMs: 1794366800000,
    randomFn: () => 0.3
  });
  assert.equal(partialSave.status, "queued");
  assert.equal(partialStorage.peek()[0].serverId, "srv-partial");

  commentShouldFail = false;
  const partialFlush = await flushOutbox({
    baseUrl: "https://memos.internal.test",
    token: "test-token",
    storage: partialStorage,
    fetchImpl: partialFetch
  });
  assert.equal(partialFlush.flushed, 1);
  assert.equal(partialFlush.remaining, 0);
});

test("options testMemosConnection calls GET /api/memos?pageSize=1 and manifest.json is valid MV3", async () => {
  let seenUrl = "";
  let seenHeaders = null;
  const methods = [];
  const conn = await testMemosConnection({
    baseUrl: "https://memos.internal.test/",
    token: "tok-abc",
    fetchImpl: async (url, init) => {
      seenUrl = url;
      seenHeaders = init.headers;
      methods.push(init.method);
      return { ok: true, status: 200, async json() { return { memos: [] }; } };
    }
  });
  assert.equal(conn.ok, true);
  assert.equal(conn.message, "连接成功，可读取片段。尚未验证保存。");
  assert.equal(seenUrl, "https://memos.internal.test/api/memos?pageSize=1");
  assert.deepEqual(seenHeaders, { Authorization: "Bearer tok-abc" });
  assert.deepEqual(buildAuthHeaders("tok-abc"), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-abc"
  });
  assert.deepEqual(methods, ["GET"]);

  assert.equal(normalizeMemosBaseUrl("https://memos.internal.test/api/memos/"), "https://memos.internal.test");
  assert.equal(normalizeMemosBaseUrl("https://memos.internal.test/api/v1/memos/"), "https://memos.internal.test");
  assert.equal(normalizeMemosBaseUrl("https://memos.internal.test/api/"), "https://memos.internal.test");

  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const optionsHtml = fs.readFileSync(path.join(__dirname, "options.html"), "utf8");
  assert.match(optionsHtml, /<button id="test-btn" type="button">测试连接<\/button>/);
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  for (const perm of ["storage", "contextMenus", "activeTab", "scripting"]) {
    assert.ok(manifest.permissions.includes(perm), `missing permission ${perm}`);
  }
  for (const host of ["https://chatgpt.com/*", "https://claude.ai/*", "https://gemini.google.com/*"]) {
    assert.ok(manifest.host_permissions.includes(host), `missing host permission ${host}`);
  }
});

test("extension and toolbar icons provide each declared PNG size", () => {
  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const manifest = JSON.parse(fs.readFileSync(path.join(extensionDir, "manifest.json"), "utf8"));
  assert.deepEqual(Object.keys(manifest.icons), ["16", "32", "48", "128"]);
  assert.deepEqual(manifest.action.default_icon, manifest.icons);

  for (const [size, resource] of Object.entries(manifest.icons)) {
    const png = fs.readFileSync(path.join(extensionDir, resource));
    assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    assert.equal(png.toString("ascii", 12, 16), "IHDR");
    assert.equal(png.readUInt32BE(16), Number(size), `${resource} width`);
    assert.equal(png.readUInt32BE(20), Number(size), `${resource} height`);
  }
});

test("captured range keeps its excerpt and context after the live selection moves", () => {
  const doc = parseHtmlDocument(`
    <div data-message-author-role="user">Question A</div>
    <div data-message-author-role="assistant" id="a">Answer A</div>
    <div data-message-author-role="user">Question B</div>
    <div data-message-author-role="assistant" id="b">Answer B</div>
  `, { url: "https://chatgpt.com/c/selection-race" });
  const selectionRange = doc.createRangeFromNode(doc.querySelector("#a"));
  const changedRange = doc.createRangeFromNode(doc.querySelector("#b"));
  const selection = {
    rangeCount: 1,
    isCollapsed: false,
    getRangeAt() { return changedRange; },
    toString() { return changedRange.toString(); }
  };
  const clip = extractClipContext({ doc, selectionRange, selectedText: "Answer A", selection });
  assert.equal(clip.selectedMarkdown, "Answer A");
  assert.equal(clip.prompt, "Question A");
  assert.equal(clip.recentTurns, "User: Question A\n\nAssistant: Answer A");
});

test("content.js Hyper+S shortcut accepts only non-repeating Hyper+S and rejects Alt+Shift+S, partial modifiers, and other keys", async () => {
  const harness = createContentScriptHarness();

  const rejectedEvents = [
    { key: "S", code: "KeyS", ctrlKey: false, altKey: true, shiftKey: true, metaKey: false, repeat: false },
    { key: "s", code: "KeyS", ctrlKey: true, altKey: true, shiftKey: false, metaKey: true, repeat: false },
    { key: "s", code: "KeyS", ctrlKey: false, altKey: false, shiftKey: false, metaKey: true, repeat: false },
    { key: "r", code: "KeyR", ctrlKey: true, altKey: true, shiftKey: true, metaKey: true, repeat: false },
    { key: "s", code: "KeyS", ctrlKey: true, altKey: true, shiftKey: true, metaKey: true, repeat: true }
  ];

  for (const evt of rejectedEvents) {
    const res = harness.document.dispatch("keydown", evt);
    assert.equal(res.defaultPrevented, false);
  }
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 0);

  const accepted = harness.document.dispatch("keydown", {
    key: "s",
    code: "KeyS",
    ctrlKey: true,
    altKey: true,
    shiftKey: true,
    metaKey: true,
    repeat: false
  });
  assert.equal(accepted.defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1);
  assert.equal(harness.sentMessages[0].type, "REWIND_SAVE_CLIP");
});

function createContentScriptHarness({
  extractorsUrl,
  sendMessageImpl,
  uiLanguage = "auto",
  browserLanguage = undefined
} = {}) {
  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const i18nScriptPath = path.join(extensionDir, "i18n.js");
  const i18nCode = fs.readFileSync(i18nScriptPath, "utf8");
  const contentScriptPath = path.join(extensionDir, "content.js");
  const contentCode = fs.readFileSync(contentScriptPath, "utf8");
  const resolvedExtractorsUrl = extractorsUrl || pathToFileURL(path.join(extensionDir, "extractors.mjs")).href;

  let nowMs = 1_000_000;
  let nextTimerId = 1;
  const timers = new Map();

  function scheduleTimeout(cb, ms = 0) {
    const id = nextTimerId++;
    timers.set(id, { cb, dueAt: nowMs + Number(ms) });
    return id;
  }

  function cancelTimeout(id) {
    timers.delete(id);
  }

  function advanceTime(deltaMs) {
    nowMs += deltaMs;
    while (true) {
      let earliestId = null;
      let earliestDue = Infinity;
      for (const [id, entry] of timers.entries()) {
        if (entry.dueAt <= nowMs && entry.dueAt < earliestDue) {
          earliestDue = entry.dueAt;
          earliestId = id;
        }
      }
      if (earliestId === null) break;
      const entry = timers.get(earliestId);
      timers.delete(earliestId);
      entry.cb();
    }
  }

  function makeEventTarget() {
    const map = new Map();
    return {
      addEventListener(type, fn, options) {
        const capture = typeof options === "boolean" ? options : Boolean(options && options.capture);
        if (!map.has(type)) map.set(type, []);
        map.get(type).push({ fn, capture });
      },
      dispatch(type, rawEvent = {}) {
        let defaultPrevented = false;
        let propagationStopped = false;
        const event = {
          type,
          ...rawEvent,
          get defaultPrevented() {
            return defaultPrevented;
          },
          preventDefault() {
            defaultPrevented = true;
          },
          stopPropagation() {
            propagationStopped = true;
          },
          composedPath() {
            return rawEvent.path || [];
          }
        };
        const entries = (map.get(type) || []).slice();
        const ordered = [
          ...entries.filter((e) => e.capture),
          ...entries.filter((e) => !e.capture)
        ];
        for (const { fn } of ordered) {
          if (propagationStopped) break;
          fn(event);
        }
        return { event, defaultPrevented, propagationStopped };
      }
    };
  }

  function createFakeElement(tagName) {
    const target = makeEventTarget();
    const el = {
      nodeType: 1,
      tagName: String(tagName).toUpperCase(),
      className: "",
      type: "",
      tabIndex: 0,
      hidden: false,
      textContent: "",
      isConnected: false,
      offsetWidth: 116,
      offsetHeight: 26,
      style: {},
      attributes: {},
      children: [],
      childNodes: [],
      parentElement: null,
      shadowRoot: null,
      setAttribute(name, val) {
        this.attributes[String(name)] = String(val);
      },
      getAttribute(name) {
        const k = String(name);
        return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null;
      },
      appendChild(child) {
        child.parentElement = this;
        child.isConnected = this.isConnected;
        this.children.push(child);
        this.childNodes.push(child);
        return child;
      },
      append(...nodes) {
        for (const n of nodes) this.appendChild(n);
      },
      attachShadow({ mode }) {
        const sr = {
          mode,
          host: el,
          children: [],
          append(...nodes) {
            for (const n of nodes) this.children.push(n);
          },
          querySelector(cls) {
            if (cls.startsWith(".")) {
              const targetCls = cls.slice(1);
              return this.children.find((c) => (c.className || "").split(/\s+/).includes(targetCls)) || null;
            }
            return this.children.find((c) => c.tagName === cls.toUpperCase()) || null;
          }
        };
        el.shadowRoot = sr;
        return sr;
      },
      addEventListener: target.addEventListener,
      dispatch: target.dispatch
    };
    return el;
  }

  const parsedDoc = parseHtmlDocument(
    `<html><head><title>Capsule VM Test - ChatGPT</title></head><body>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Why did Alt+Shift+S duplicate?</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p id="picked">Keep <code>Hyper+S</code> in content script only.</p></div></div>
    </body></html>`,
    { url: "https://chatgpt.com/c/capsule-vm" }
  );
  const pickedEl = parsedDoc.querySelector("#picked");
  let selectionCollapsed = false;
  let selectionRect = { left: 300, top: 200, bottom: 224, width: 160, height: 24 };

  const currentSelection = {
    get rangeCount() {
      return selectionCollapsed ? 0 : 1;
    },
    get isCollapsed() {
      return selectionCollapsed;
    },
    get anchorNode() {
      return pickedEl;
    },
    get focusNode() {
      return pickedEl;
    },
    collapse() {
      selectionCollapsed = true;
    },
    toString() {
      return selectionCollapsed ? "" : pickedEl.textContent;
    },
    getRangeAt() {
      const baseRange = parsedDoc.createRangeFromNode(pickedEl);
      return {
        ...baseRange,
        getBoundingClientRect() {
          return selectionRect;
        },
        cloneRange() {
          return parsedDoc.createRangeFromNode(pickedEl);
        }
      };
    }
  };

  const docEvents = makeEventTarget();
  const winEvents = makeEventTarget();
  const documentElement = createFakeElement("html");
  documentElement.isConnected = true;

  const fakeDocument = {
    title: parsedDoc.title,
    location: parsedDoc.location,
    documentElement,
    body: documentElement,
    createElement: createFakeElement,
    querySelectorAll: (sel) => parsedDoc.querySelectorAll(sel),
    querySelector: (sel) => parsedDoc.querySelector(sel),
    addEventListener: docEvents.addEventListener,
    dispatch: docEvents.dispatch
  };

  const fakeWindow = {
    innerWidth: 1280,
    innerHeight: 800,
    getSelection: () => currentSelection,
    addEventListener: winEvents.addEventListener,
    dispatch: winEvents.dispatch
  };

  const sentMessages = [];
  const storageChangedListeners = [];
  let storedState = { showSelectionPill: true, uiLanguage };
  let messageHandler = sendMessageImpl || (async () => ({ status: "saved", toast: defaultToasts.SAVED }));

  const fakeChrome = {
    ...(browserLanguage !== undefined
      ? {
          i18n: {
            getUILanguage() {
              return browserLanguage;
            }
          }
        }
      : {}),
    runtime: {
      getURL() {
        return resolvedExtractorsUrl;
      },
      async sendMessage(payload) {
        sentMessages.push(payload);
        return messageHandler(payload);
      },
      onMessage: { addListener() {} }
    },
    storage: {
      local: {
        get(keys, cb) {
          const base =
            keys && typeof keys === "object" && !Array.isArray(keys) ? { ...keys } : {};
          const result = { ...base, ...storedState };
          if (typeof cb === "function") cb(result);
          return Promise.resolve(result);
        }
      },
      onChanged: {
        addListener(fn) {
          storageChangedListeners.push(fn);
        }
      }
    }
  };

  const sandbox = {
    Date: { now: () => nowMs },
    Math,
    Number,
    String,
    Boolean,
    Object,
    Set,
    WeakMap,
    URL,
    Promise,
    setTimeout: scheduleTimeout,
    clearTimeout: cancelTimeout,
    navigator: {
      platform: "MacIntel",
      userAgent: "Mozilla/5.0 (Macintosh)",
      ...(browserLanguage !== undefined ? { language: browserLanguage } : {})
    },
    location: parsedDoc.location,
    window: fakeWindow,
    document: fakeDocument,
    chrome: fakeChrome
  };
  sandbox.globalThis = sandbox;

  const vmContext = vm.createContext(sandbox);
  vm.runInContext(i18nCode, vmContext, { filename: i18nScriptPath });
  vm.runInContext(contentCode, vmContext, {
    filename: contentScriptPath,
    importModuleDynamically: vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER
  });

  return {
    advanceTime,
    sentMessages,
    emitStorageChange(changes, area = "local") {
      for (const [key, diff] of Object.entries(changes)) {
        if (diff && Object.prototype.hasOwnProperty.call(diff, "newValue")) {
          storedState[key] = diff.newValue;
        }
      }
      for (const fn of storageChangedListeners) {
        fn(changes, area);
      }
    },
    setSendMessageHandler(fn) {
      messageHandler = fn;
    },
    setSelectionCollapsed(collapsed) {
      selectionCollapsed = collapsed;
    },
    setSelectionRect(rect) {
      selectionRect = rect;
    },
    setViewportSize(width, height) {
      fakeWindow.innerWidth = width;
      fakeWindow.innerHeight = height;
    },
    isSelectionCollapsed() {
      return selectionCollapsed;
    },
    document: fakeDocument,
    window: fakeWindow,
    getHost() {
      return documentElement.children.find((c) => c.getAttribute("data-coding-rewind-ui") === "1") || null;
    },
    getPill() {
      return this.getHost()?.shadowRoot?.querySelector(".rw-pill") || null;
    },
    getPillLabel() {
      return this.getPill()?.children.find((c) => c.className === "rw-pill-label")?.textContent ?? null;
    },
    getToast() {
      return this.getHost()?.shadowRoot?.querySelector(".rw-toast") || null;
    },
    getStyleText() {
      return this.getHost()?.shadowRoot?.querySelector("style")?.textContent || "";
    }
  };
}

test("content.js capsule positions on mouseup, absorbs rapid double-mousedown without collapsing selection, and handles Hyper+S vs Alt+Shift+S", async () => {
  let resolveInFlightSave;
  const harness = createContentScriptHarness({
    sendMessageImpl: () =>
      new Promise((resolve) => {
        resolveInFlightSave = resolve;
      })
  });

  harness.document.addEventListener("mousedown", () => {
    harness.setSelectionCollapsed(true);
  }, false);

  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  const pillIcon = pill?.children.find((c) => c.className === "rw-pill-icon");
  assert.ok(pill, "Expected .rw-pill to be mounted in shadow root");
  assert.equal(pill.style.display, "inline-flex");
  assert.equal(pill.style.visibility, "visible");
  assert.equal(pill.getAttribute("data-state"), "ready");
  assert.equal(harness.getPillLabel(), "暂存");
  assert.equal(pillIcon.hidden, true);
  assert.equal(pillIcon.textContent, "");
  assert.equal(pill.style.left, "322px", "pill centers horizontally above selection rect");
  assert.equal(pill.style.top, "166px", "pill positions above selection rect");
  assert.doesNotMatch(
    harness.getStyleText(),
    /\.rw-pill\[data-state="saving"\][\s\S]*?pointer-events:\s*none/
  );

  const click1 = pill.dispatch("mousedown", { path: [pill] });
  assert.equal(click1.defaultPrevented, true);
  assert.equal(click1.propagationStopped, true);
  assert.equal(pill.getAttribute("data-state"), "saving");
  assert.equal(harness.getPillLabel(), "暂存中…");
  assert.equal(pillIcon.hidden, false);
  assert.equal(pillIcon.textContent, "…");

  const click2 = pill.dispatch("mousedown", { path: [pill] });
  assert.equal(click2.defaultPrevented, true);
  assert.equal(click2.propagationStopped, true);
  assert.equal(harness.isSelectionCollapsed(), false, "rapid second click must not fall through and collapse selection");

  harness.window.dispatch("scroll");
  harness.document.dispatch("mousedown", { path: [] });
  harness.setSelectionCollapsed(false);
  assert.equal(pill.getAttribute("data-state"), "saving", "scroll and outside mousedown must not wipe in-flight saving state");

  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1);
  assert.equal(harness.sentMessages[0].type, "REWIND_SAVE_CLIP");
  assert.equal(harness.sentMessages[0].clip.selectedMarkdown, "Keep `Hyper+S` in content script only.");

  harness.advanceTime(400);
  pill.dispatch("mousedown", { path: [pill] });
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1, "click while saving is ignored even after 350ms cooldown");

  resolveInFlightSave({ status: "saved", toast: defaultToasts.SAVED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "saved");
  assert.equal(harness.getPillLabel(), "已同步");
  assert.equal(pillIcon.hidden, false);
  assert.equal(pillIcon.textContent, "✓");
  assert.equal(pill.style.left, "322px");
  assert.equal(pill.style.top, "166px");

  harness.advanceTime(950);
  assert.equal(pill.getAttribute("data-state"), "hidden");
  assert.equal(pill.style.display, "none");

  let resolveQueuedSave;
  harness.setSendMessageHandler(() => new Promise((resolve) => { resolveQueuedSave = resolve; }));
  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);
  assert.equal(harness.getPillLabel(), "暂存");
  pill.dispatch("mousedown", { path: [pill] });
  assert.equal(harness.getPillLabel(), "暂存中…");
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  resolveQueuedSave({ status: "queued", toast: defaultToasts.QUEUED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "queued");
  assert.equal(harness.getPillLabel(), "待同步");
  harness.advanceTime(950);
  assert.equal(pill.getAttribute("data-state"), "hidden");

  harness.setSendMessageHandler(async () => ({ status: "saved", toast: defaultToasts.SAVED }));
  harness.advanceTime(500);

  const altShiftRes = harness.document.dispatch("keydown", {
    key: "S",
    code: "KeyS",
    altKey: true,
    shiftKey: true,
    ctrlKey: false,
    metaKey: false,
    repeat: false
  });
  await new Promise((r) => setImmediate(r));
  assert.equal(altShiftRes.defaultPrevented, false);
  assert.equal(harness.sentMessages.length, 2, "Alt+Shift+S must be left exclusively to chrome.commands");

  const hyperRes = harness.document.dispatch("keydown", {
    key: "s",
    code: "KeyS",
    ctrlKey: true,
    altKey: true,
    shiftKey: true,
    metaKey: true,
    repeat: false
  });
  assert.equal(hyperRes.defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 3, "Hyper+S must trigger REWIND_SAVE_CLIP");
});

test("content.js capsule hides cleanly on Escape mid-save and never freezes in saving when extractClipContext or sendMessage rejects", async () => {
  let finishSave;
  const escapeHarness = createContentScriptHarness({
    sendMessageImpl: () => new Promise((resolve) => { finishSave = resolve; })
  });
  escapeHarness.document.dispatch("mouseup", { path: [] });
  escapeHarness.advanceTime(20);
  const escapePill = escapeHarness.getPill();
  escapePill.dispatch("mousedown", { path: [escapePill] });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(escapePill.getAttribute("data-state"), "saving");

  escapeHarness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  assert.equal(escapePill.getAttribute("data-state"), "hidden");
  assert.equal(escapePill.style.display, "none");

  finishSave({ status: "saved", toast: defaultToasts.SAVED });
  await new Promise((r) => setImmediate(r));
  assert.equal(escapePill.getAttribute("data-state"), "hidden", "Escape during saving keeps pill hidden after response");
  assert.equal(escapePill.style.display, "none");

  const rejectMsgHarness = createContentScriptHarness({
    sendMessageImpl: async () => {
      throw new Error("Extension context invalidated");
    }
  });
  rejectMsgHarness.document.dispatch("mouseup", { path: [] });
  rejectMsgHarness.advanceTime(20);
  const msgPill = rejectMsgHarness.getPill();
  assert.equal(msgPill.getAttribute("data-state"), "ready");

  msgPill.dispatch("mousedown", { path: [msgPill] });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(msgPill.getAttribute("data-state"), "hidden", "sendMessage rejection hides pill");
  assert.equal(msgPill.style.display, "none");
  assert.equal(rejectMsgHarness.getToast().getAttribute("data-visible"), "true");

  const throwingExtractorsUrl =
    "data:text/javascript," +
    encodeURIComponent("export function extractClipContext() { throw new Error('DOM extraction crashed'); }");
  const rejectExtractHarness = createContentScriptHarness({
    extractorsUrl: throwingExtractorsUrl
  });
  rejectExtractHarness.document.dispatch("mouseup", { path: [] });
  rejectExtractHarness.advanceTime(20);
  const extractPill = rejectExtractHarness.getPill();
  assert.equal(extractPill.getAttribute("data-state"), "ready");

  extractPill.dispatch("mousedown", { path: [extractPill] });
  assert.equal(extractPill.getAttribute("data-state"), "saving");
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(extractPill.getAttribute("data-state"), "hidden", "extractClipContext rejection hides pill");
  assert.equal(extractPill.style.display, "none");
  assert.equal(rejectExtractHarness.sentMessages.length, 0);
  assert.equal(rejectExtractHarness.getToast().getAttribute("data-visible"), "true");
});

test("content.js capsule centers above selection, flips below near top edge, and clamps horizontally", () => {
  const harness = createContentScriptHarness();
  harness.setViewportSize(1280, 800);

  const cases = [
    {
      rect: { left: 300, top: 200, bottom: 224, width: 160, height: 24 },
      expected: { left: "322px", top: "166px" }
    },
    {
      rect: { left: 300, top: 18, bottom: 42, width: 160, height: 24 },
      expected: { left: "322px", top: "50px" }
    },
    {
      rect: { left: 2, top: 200, bottom: 224, width: 20, height: 24 },
      expected: { left: "8px", top: "166px" }
    },
    {
      rect: { left: 1250, top: 200, bottom: 224, width: 24, height: 24 },
      expected: { left: "1156px", top: "166px" }
    }
  ];

  for (const { rect, expected } of cases) {
    harness.setSelectionRect(rect);
    harness.document.dispatch("mouseup", { path: [] });
    harness.advanceTime(20);
    const pill = harness.getPill();
    assert.deepEqual({ left: pill.style.left, top: pill.style.top }, expected);
  }

  harness.setViewportSize(400, 300);
  harness.setSelectionRect({ left: 370, top: 200, bottom: 224, width: 24, height: 24 });
  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);
  const clampedPill = harness.getPill();
  assert.deepEqual({ left: clampedPill.style.left, top: clampedPill.style.top }, { left: "276px", top: "166px" });
});

test("htmlToMarkdown falls back cleanly when DOMParser is unavailable", () => {
  const originalDOMParser = globalThis.DOMParser;
  try {
    globalThis.DOMParser = undefined;
    assert.equal(htmlToMarkdown("  worker fallback\n\n\nline two  "), "worker fallback\n\nline two");
  } finally {
    globalThis.DOMParser = originalDOMParser;
  }
});

test("MV3 _locales catalogs, manifest __MSG__ bindings, and CodingRewindI18n dictionary have full key parity", () => {
  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const manifest = JSON.parse(fs.readFileSync(path.join(extensionDir, "manifest.json"), "utf8"));
  const enMessages = JSON.parse(
    fs.readFileSync(path.join(extensionDir, "_locales", "en", "messages.json"), "utf8")
  );
  const zhMessages = JSON.parse(
    fs.readFileSync(path.join(extensionDir, "_locales", "zh_CN", "messages.json"), "utf8")
  );

  assert.equal(manifest.default_locale, "en");
  assert.equal(manifest.name, "__MSG_extName__");
  assert.equal(manifest.description, "__MSG_extDescription__");
  assert.equal(manifest.action.default_title, "__MSG_actionTitle__");
  assert.equal(manifest.commands["save-selection"].description, "__MSG_saveSelectionCommand__");
  assert.deepEqual(manifest.content_scripts[0].js, ["i18n.js", "content.js"]);

  const expectedLocaleKeys = [
    "actionTitle",
    "extDescription",
    "extName",
    "saveSelectionCommand",
    "untitledSession"
  ];
  assert.deepEqual(Object.keys(enMessages).sort(), expectedLocaleKeys);
  assert.deepEqual(Object.keys(zhMessages).sort(), expectedLocaleKeys);
  for (const key of expectedLocaleKeys) {
    assert.equal(typeof enMessages[key].message, "string");
    assert.ok(enMessages[key].message.length > 0);
    assert.equal(typeof zhMessages[key].message, "string");
    assert.ok(zhMessages[key].message.length > 0);
  }

  const i18n = globalThis.CodingRewindI18n;
  assert.deepEqual(i18n.SUPPORTED_UI_LANGUAGES, ["auto", "zh-CN", "en"]);
  assert.deepEqual(
    Object.keys(i18n.MESSAGES["zh-CN"]).sort(),
    Object.keys(i18n.MESSAGES.en).sort()
  );
});

test("resolveLocale and createTranslator resolve auto, browser languages, and explicit overrides", (t) => {
  const { detectBrowserLanguage, resolveLocale, createTranslator } = globalThis.CodingRewindI18n;
  const originalChrome = globalThis.chrome;
  const navDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  t.after(() => {
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (navDescriptor) Object.defineProperty(globalThis, "navigator", navDescriptor);
    else delete globalThis.navigator;
  });

  assert.equal(resolveLocale("auto", "en-US"), "en");
  assert.equal(resolveLocale("auto", "zh-CN"), "zh-CN");
  assert.equal(resolveLocale("auto", "zh_CN"), "zh-CN");
  assert.equal(resolveLocale("auto", "zh-TW"), "zh-CN");
  assert.equal(resolveLocale("auto", "ja-JP"), "en");

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { language: "en-GB" }
  });
  globalThis.chrome = { i18n: { getUILanguage: () => "zh-CN" } };
  assert.equal(detectBrowserLanguage(), "zh-CN");
  assert.equal(resolveLocale("auto"), "zh-CN");
  assert.equal(resolveLocale("auto", undefined), "zh-CN");
  assert.equal(resolveLocale("auto", null), "zh-CN");

  delete globalThis.chrome;
  assert.equal(detectBrowserLanguage(), "en-GB");
  assert.equal(resolveLocale("auto"), "en");
  assert.equal(resolveLocale("auto", undefined), "en");

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { language: "" }
  });
  assert.equal(detectBrowserLanguage(), undefined);
  assert.equal(resolveLocale("auto", undefined), "zh-CN");
  assert.equal(resolveLocale("auto", ""), "zh-CN");
  assert.equal(resolveLocale("en", "zh-CN"), "en");
  assert.equal(resolveLocale("zh-CN", "en-US"), "zh-CN");
  assert.equal(resolveLocale("zh-Hans", "en-US"), "zh-CN");
  assert.equal(resolveLocale("zh", "en-US"), "zh-CN");

  const enTranslator = createTranslator({ preferredLanguage: "auto", browserLanguage: "en-US" });
  assert.equal(enTranslator.locale, "en");
  assert.equal(enTranslator("pillReady"), "Stash");
  assert.equal(enTranslator.t("outboxCount", { count: 3 }), "Pending clips: 3");

  const zhTranslator = createTranslator({ preferredLanguage: "zh-CN", browserLanguage: "en-US" });
  assert.equal(zhTranslator.locale, "zh-CN");
  assert.equal(zhTranslator("pillReady"), "暂存");
  assert.equal(zhTranslator.t("outboxCount", { count: 3 }), "待同步片段：3 条");

  assert.equal(cleanSessionTitle("New conversation - Claude"), "");
  assert.equal(cleanSessionTitle("未命名对话 - ChatGPT"), "");
});

test("content.js renders English pill states and updates live on chrome.storage.onChanged", async () => {
  let resolveSave;
  const harness = createContentScriptHarness({
    uiLanguage: "auto",
    browserLanguage: "en-US",
    sendMessageImpl: () =>
      new Promise((resolve) => {
        resolveSave = resolve;
      })
  });

  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.ok(pill);
  assert.equal(pill.getAttribute("data-state"), "ready");
  assert.equal(pill.getAttribute("aria-label"), "Stash selected text");
  assert.equal(harness.getPillLabel(), "Stash");

  harness.emitStorageChange({ uiLanguage: { oldValue: "auto", newValue: "zh-CN" } });
  assert.equal(pill.getAttribute("aria-label"), "暂存选中文本");
  assert.equal(harness.getPillLabel(), "暂存");

  harness.emitStorageChange({ uiLanguage: { oldValue: "zh-CN", newValue: "en" } });
  assert.equal(pill.getAttribute("aria-label"), "Stash selected text");
  assert.equal(harness.getPillLabel(), "Stash");

  pill.dispatch("mousedown", { path: [pill] });
  assert.equal(pill.getAttribute("data-state"), "saving");
  assert.equal(harness.getPillLabel(), "Saving…");

  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  resolveSave({ status: "saved", toast: getToastMessages("en").SAVED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "saved");
  assert.equal(harness.getPillLabel(), "Synced");

  harness.advanceTime(950);
  assert.equal(pill.getAttribute("data-state"), "hidden");

  let resolveQueued;
  harness.setSendMessageHandler(() => new Promise((resolve) => { resolveQueued = resolve; }));
  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);
  assert.equal(harness.getPillLabel(), "Stash");

  pill.dispatch("mousedown", { path: [pill] });
  assert.equal(harness.getPillLabel(), "Saving…");
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  resolveQueued({ status: "queued", toast: getToastMessages("en").QUEUED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "queued");
  assert.equal(harness.getPillLabel(), "Pending sync");
});

test("probeMemosConnection, saveClipWithOutbox, and background context menu localize to English", async (t) => {
  const invalidUrl = await probeMemosConnection("not-a-url", "", globalThis.fetch, "en");
  assert.equal(invalidUrl.ok, false);
  assert.equal(invalidUrl.message, "Please enter a valid Memos server URL");

  const httpFail = await probeMemosConnection(
    "https://memos.internal.test",
    "tok",
    async () => ({ ok: false, status: 401 }),
    "en"
  );
  assert.equal(httpFail.ok, false);
  assert.equal(httpFail.message, "Connection failed (HTTP 401)");

  const okConn = await probeMemosConnection(
    "https://memos.internal.test",
    "tok",
    async () => ({ ok: true, status: 200, async json() { return { memos: [] }; } }),
    "en"
  );
  assert.equal(okConn.ok, true);
  assert.equal(okConn.message, "Connected; clips can be read. Saving has not been verified yet.");

  const storage = createMemoryOutboxStorage();
  const sampleClip = { selectedMarkdown: "English clip test", sourcePlatform: "chatgpt" };

  const unconf = await saveClipWithOutbox({
    clip: sampleClip,
    baseUrl: "",
    token: "",
    storage,
    locale: "en"
  });
  assert.equal(unconf.status, "unconfigured");
  assert.equal(unconf.toast, "Clip saved locally; check Memos URL and access token");
  assert.match(
    storage.peek()[0].memoBody.content,
    /^#rewind\/pending #source\/chatgpt\n\n> \*\*Source:\*\* Untitled Session · /
  );

  const queued = await saveClipWithOutbox({
    clip: sampleClip,
    baseUrl: "https://memos.internal.test",
    token: "tok",
    storage,
    fetchImpl: async () => ({ ok: false, status: 503, async json() { return {}; } }),
    locale: "en"
  });
  assert.equal(queued.status, "queued");
  assert.equal(queued.toast, "Clip saved locally; will retry sync automatically");

  const saved = await saveClipWithOutbox({
    clip: sampleClip,
    baseUrl: "https://memos.internal.test",
    token: "tok",
    storage: createMemoryOutboxStorage(),
    fetchImpl: async () => ({ ok: true, status: 200, async json() { return { name: "memos/en-1" }; } }),
    locale: "en"
  });
  assert.equal(saved.status, "saved");
  assert.equal(saved.toast, "Clip saved to Memos");

  const originalChrome = globalThis.chrome;
  const originalSelf = globalThis.self;
  t.after(() => {
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (originalSelf === undefined) delete globalThis.self;
    else globalThis.self = originalSelf;
  });

  let installedListener;
  let storageChangedListener;
  const createdMenus = [];
  const updatedMenus = [];
  let currentLang = "auto";
  globalThis.chrome = {
    i18n: { getUILanguage: () => "en-US" },
    runtime: {
      onInstalled: { addListener(fn) { installedListener = fn; } },
      onStartup: { addListener() {} },
      onMessage: { addListener() {} }
    },
    contextMenus: {
      removeAll(cb) { cb(); },
      create(item) { createdMenus.push(item); },
      update(id, patch, cb) { updatedMenus.push({ id, patch }); if (cb) cb(); },
      onClicked: { addListener() {} }
    },
    commands: { onCommand: { addListener() {} } },
    storage: {
      local: {
        async get() { return { uiLanguage: currentLang, outbox: [] }; },
        async set() {}
      },
      onChanged: { addListener(fn) { storageChangedListener = fn; } }
    }
  };
  globalThis.self = { addEventListener() {} };

  await import("./background.js?live-i18n-menu");
  installedListener();
  await new Promise((r) => setImmediate(r));
  assert.equal(createdMenus.at(-1)?.title, "Save selection to Coding Rewind");

  currentLang = "zh-CN";
  storageChangedListener({ uiLanguage: { oldValue: "auto", newValue: "zh-CN" } }, "local");
  assert.equal(updatedMenus.at(-1)?.patch.title, "保存所选文本到 Coding Rewind");

  currentLang = "en";
  storageChangedListener({ uiLanguage: { oldValue: "zh-CN", newValue: "en" } }, "local");
  assert.equal(updatedMenus.at(-1)?.patch.title, "Save selection to Coding Rewind");
});

test("options.html and initOptionsPage switch UI language live and persist uiLanguage immediately", async (t) => {
  const originalDocument = globalThis.document;
  const originalChrome = globalThis.chrome;
  t.after(() => {
    if (originalDocument === undefined) delete globalThis.document;
    else globalThis.document = originalDocument;
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
  });

  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const optionsHtml = fs.readFileSync(path.join(extensionDir, "options.html"), "utf8");
  const parsed = parseHtmlDocument(optionsHtml);

  const enhanceNode = (node) => {
    const listeners = new Map();
    let customText = null;
    Object.defineProperty(node, "textContent", {
      configurable: true,
      get() {
        return customText !== null ? customText : node.childNodes.map((c) => c.textContent).join("");
      },
      set(val) {
        customText = String(val);
      }
    });
    node.setAttribute = (name, val) => {
      node.attributes[String(name).toLowerCase()] = String(val);
    };
    node.addEventListener = (type, fn) => {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    };
    node.dispatch = async (type, event = {}) => {
      for (const fn of listeners.get(type) || []) {
        await fn({ preventDefault() {}, ...event });
      }
    };
    for (const child of node.children || []) {
      enhanceNode(child);
    }
  };
  enhanceNode(parsed.body);

  parsed.documentElement = parsed.querySelector("html") || { lang: "zh-CN" };
  parsed.getElementById = (id) => parsed.querySelector(`#${id}`);

  const persisted = {
    memosUrl: "https://memos.internal.test",
    memosToken: "tok-1",
    showSelectionPill: true,
    uiLanguage: "auto",
    outbox: [{ clipId: "rw-1" }, { clipId: "rw-2" }]
  };
  const setCalls = [];

  globalThis.document = parsed;
  globalThis.chrome = {
    i18n: { getUILanguage: () => "zh-CN" },
    permissions: { async request() { return true; } },
    runtime: { async sendMessage() { return { ok: true, flushed: 2, remaining: 0 }; } },
    storage: {
      local: {
        async get() { return { ...persisted }; },
        async set(patch) {
          setCalls.push(patch);
          Object.assign(persisted, patch);
        }
      },
      onChanged: { addListener() {} }
    }
  };

  initOptionsPage();
  await new Promise((r) => setImmediate(r));

  assert.equal(parsed.title, "Coding Rewind 网页扩展设置");
  assert.equal(parsed.getElementById("test-btn").textContent, "测试连接");
  assert.equal(parsed.getElementById("outbox-count").textContent, "待同步片段：2 条");

  const languageSelect = parsed.getElementById("ui-language");
  languageSelect.value = "en";
  await languageSelect.dispatch("change");

  assert.deepEqual(setCalls.at(-1), { uiLanguage: "en" });
  assert.equal(parsed.documentElement.lang, "en");
  assert.equal(parsed.title, "Coding Rewind Web Clipper Settings");
  assert.equal(parsed.getElementById("connection-heading").textContent, "Memos Connection");
  assert.equal(parsed.getElementById("test-btn").textContent, "Test Connection");
  assert.equal(parsed.getElementById("memos-url").placeholder, "Enter Memos server URL");
  assert.equal(parsed.getElementById("outbox-count").textContent, "Pending clips: 2");
  assert.equal(parsed.getElementById("save-btn").textContent, "Save Settings");

  await parsed.getElementById("settings-form").dispatch("submit");
  assert.equal(parsed.getElementById("status").textContent, "Settings saved");
  assert.equal(persisted.uiLanguage, "en");
});

test("background setupMenusAndAlarms serializes concurrent onInstalled, onStartup, and storage.onChanged calls", async (t) => {
  const originalChrome = globalThis.chrome;
  const originalSelf = globalThis.self;
  t.after(() => {
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (originalSelf === undefined) delete globalThis.self;
    else globalThis.self = originalSelf;
  });

  let installedListener;
  let startupListener;
  let storageChangedListener;
  const events = [];
  const pendingRemovals = [];
  let currentLang = "en";

  globalThis.chrome = {
    i18n: { getUILanguage: () => "en-US" },
    runtime: {
      onInstalled: { addListener(fn) { installedListener = fn; } },
      onStartup: { addListener(fn) { startupListener = fn; } },
      onMessage: { addListener() {} }
    },
    contextMenus: {
      removeAll(cb) {
        events.push("removeAll:start");
        pendingRemovals.push(() => {
          events.push("removeAll:done");
          cb();
        });
      },
      create(item) {
        events.push(`create:${item.title}`);
      },
      update(_id, patch, cb) {
        events.push(`update:${patch.title}`);
        if (cb) cb();
      },
      onClicked: { addListener() {} }
    },
    commands: { onCommand: { addListener() {} } },
    storage: {
      local: {
        async get() { return { uiLanguage: currentLang, outbox: [] }; },
        async set() {}
      },
      onChanged: { addListener(fn) { storageChangedListener = fn; } }
    }
  };
  globalThis.self = { addEventListener() {} };

  await import("./background.js?serialized-menu-setup");

  installedListener();
  startupListener();
  await new Promise((r) => setImmediate(r));

  assert.equal(pendingRemovals.length, 1);
  assert.deepEqual(events, ["removeAll:start"]);

  currentLang = "zh-CN";
  storageChangedListener({ uiLanguage: { oldValue: "en", newValue: "zh-CN" } }, "local");
  assert.deepEqual(events, ["removeAll:start"]);

  pendingRemovals.shift()();
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  assert.equal(pendingRemovals.length, 1);
  pendingRemovals.shift()();
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  assert.deepEqual(events, [
    "removeAll:start",
    "removeAll:done",
    "create:保存所选文本到 Coding Rewind",
    "removeAll:start",
    "removeAll:done",
    "create:保存所选文本到 Coding Rewind",
    "update:保存所选文本到 Coding Rewind"
  ]);
});

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
  extractChatSessionId,
  cleanSessionTitle,
  buildFallbackClip,
  htmlToMarkdown,
  selectionToMarkdown,
  extractSessionTitle,
  extractConversationTurns,
  closeUnbalancedCodeFence,
  formatRecentTurns,
  extractSessionOpening,
  extractPageLead,
  buildTextFragmentUrl,
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
  hasClipContext,
  buildMemosWirePayloads,
  parseServerMemoId,
  saveClipWithOutbox,
  flushOutbox
} from "./memos_payload.mjs";

import {
  DEFAULT_EXCLUDED_DOMAINS,
  normalizeDomainEntry,
  parseExcludedDomains,
  resolvePillScope,
  testMemosConnection,
  initOptionsPage
} from "./options.js";

import { injectContentScriptIntoOpenTabs } from "./background.js";

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
      sessionId: "",
      sessionOpening: "",
      pageLead: "",
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
      sessionId: "",
      sessionOpening: "",
      pageLead: "",
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
  assert.match(response.toast, /(?:保存失败|Save failed)/);

  rejectWrites = false;
  const queued = await new Promise((resolve) => onMessage({ type: "REWIND_SAVE_CLIP", clip }, {}, resolve));
  assert.equal(queued.status, "queued");
  assert.equal(queued.queued, true);
  assert.equal(queued.toast, getToastMessages("auto").QUEUED);
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
      sourceUrl: "https://example.org/notes"
    },
    { clipId: "rw-1794366666123-plain002", createdAt: "2026-11-11T03:16:00Z", locale: "en" }
  );
  assert.match(withoutCtxEn.memoBody.content, /^#rewind\/pending #source\/chatgpt\n\n> \*\*Source:\*\* \[Untitled Session\]\(https:\/\/example\.org\/notes\) · 2026-11-11T03:16:00Z\n\nStandalone paragraph$/);
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
  assert.equal(unconfiguredRes.toast, getToastMessages("auto").UNCONFIGURED);
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
  assert.equal(offlineRes.toast, getToastMessages("auto").QUEUED);
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
  assert.match(optionsHtml, /<button id="test-btn" type="button"[^>]*>测试连接<\/button>/);
  assert.match(optionsHtml, /<select id="pill-scope"/);
  assert.match(optionsHtml, /<textarea id="excluded-domains"/);
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.version, "0.6.0.0");
  assert.equal(manifest.version_name, "0.6.0");
  for (const perm of ["storage", "contextMenus", "activeTab", "scripting"]) {
    assert.ok(manifest.permissions.includes(perm), `missing permission ${perm}`);
  }
  assert.deepEqual(manifest.host_permissions, ["https://*/*", "http://*/*"]);
  assert.deepEqual(manifest.content_scripts[0].matches, ["https://*/*", "http://*/*"]);
  assert.deepEqual(manifest.web_accessible_resources[0].resources, ["extractors.mjs"]);
  for (const matchPattern of ["https://*/*", "http://*/*", "file:///*"]) {
    assert.ok(
      manifest.web_accessible_resources[0].matches.includes(matchPattern),
      `missing web_accessible_resources match ${matchPattern}`
    );
  }
  assert.equal(manifest.web_accessible_resources[0].use_dynamic_url, true);
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
  url = "https://chatgpt.com/c/capsule-vm",
  html = `<html><head><title>Capsule VM Test - ChatGPT</title></head><body>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Why did Alt+Shift+S duplicate?</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p id="picked">Keep <code>Hyper+S</code> in content script only.</p></div></div>
    </body></html>`,
  pickedSelector = "#picked",
  clientRects = null,
  storageData = { showSelectionPill: true },
  storageGetDelayMs = 0,
  preExistingOrphanHosts = 0,
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
      removeEventListener(type, fn, options) {
        const list = map.get(type);
        if (!list) return;
        const capture = typeof options === "boolean" ? options : Boolean(options && options.capture);
        const idx = list.findIndex((e) => e.fn === fn && e.capture === capture);
        if (idx >= 0) list.splice(idx, 1);
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
        if (child.parentElement && typeof child.parentElement.removeChild === "function") {
          child.parentElement.removeChild(child);
        }
        child.parentElement = this;
        child.isConnected = this.isConnected;
        this.children.push(child);
        this.childNodes.push(child);
        return child;
      },
      removeChild(child) {
        const idx = this.children.indexOf(child);
        if (idx >= 0) this.children.splice(idx, 1);
        const cIdx = this.childNodes.indexOf(child);
        if (cIdx >= 0) this.childNodes.splice(cIdx, 1);
        child.parentElement = null;
        child.isConnected = false;
        return child;
      },
      remove() {
        if (this.parentElement && typeof this.parentElement.removeChild === "function") {
          this.parentElement.removeChild(this);
        }
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
      removeEventListener: target.removeEventListener,
      dispatch: target.dispatch
    };
    return el;
  }

  const parsedDoc = parseHtmlDocument(html, { url });
  let pickedEl = parsedDoc.querySelector(pickedSelector) || parsedDoc.body;
  let anchorNode = pickedEl;
  let anchorOffset = 0;
  let focusNode = pickedEl;
  let focusOffset = 1;
  let selectionCollapsed = false;
  let selectionRect = { left: 300, top: 200, bottom: 224, width: 160, height: 24 };
  let selectionClientRects = clientRects;

  const currentSelection = {
    get rangeCount() {
      return selectionCollapsed ? 0 : 1;
    },
    get isCollapsed() {
      return selectionCollapsed;
    },
    get anchorNode() {
      return anchorNode;
    },
    get anchorOffset() {
      return anchorOffset;
    },
    get focusNode() {
      return focusNode;
    },
    get focusOffset() {
      return focusOffset;
    },
    collapse() {
      selectionCollapsed = true;
    },
    toString() {
      return selectionCollapsed ? "" : (pickedEl.textContent || "Selected sample text");
    },
    getRangeAt() {
      const baseRange = parsedDoc.createRangeFromNode(pickedEl);
      return {
        ...baseRange,
        getBoundingClientRect() {
          return selectionRect;
        },
        getClientRects() {
          return Array.isArray(selectionClientRects) ? selectionClientRects : [selectionRect];
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
  for (let i = 0; i < preExistingOrphanHosts; i += 1) {
    const orphan = createFakeElement("div");
    orphan.setAttribute("data-coding-rewind-ui", "1");
    documentElement.appendChild(orphan);
  }

  const fakeDocument = {
    title: parsedDoc.title,
    location: parsedDoc.location,
    hidden: false,
    activeElement: null,
    documentElement,
    body: documentElement,
    createElement: createFakeElement,
    querySelectorAll: (sel) => {
      if (sel === '[data-coding-rewind-ui="1"]') {
        return documentElement.children.filter((c) => c.getAttribute("data-coding-rewind-ui") === "1");
      }
      return parsedDoc.querySelectorAll(sel);
    },
    querySelector: (sel) => parsedDoc.querySelector(sel),
    addEventListener: docEvents.addEventListener,
    removeEventListener: docEvents.removeEventListener,
    dispatch: docEvents.dispatch
  };

  const fakeWindow = {
    innerWidth: 1280,
    innerHeight: 800,
    getSelection: () => currentSelection,
    addEventListener: winEvents.addEventListener,
    removeEventListener: winEvents.removeEventListener,
    dispatch: winEvents.dispatch
  };

  const sentMessages = [];
  let messageHandler = sendMessageImpl || (async () => ({ status: "saved", toast: getToastMessages("auto").SAVED }));
  const onMessageListeners = [];
  const onStorageChangedListeners = [];
  const liveStorage = {
    showSelectionPill: true,
    uiLanguage,
    ...(storageData && typeof storageData === "object" ? storageData : {})
  };

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
      onMessage: {
        addListener(fn) {
          onMessageListeners.push(fn);
        },
        removeListener(fn) {
          const idx = onMessageListeners.indexOf(fn);
          if (idx >= 0) onMessageListeners.splice(idx, 1);
        }
      }
    },
    storage: {
      local: {
        get(_keys, cb) {
          const snapshot = { ...liveStorage };
          if (storageGetDelayMs > 0) {
            scheduleTimeout(() => cb(snapshot), storageGetDelayMs);
          } else {
            cb(snapshot);
          }
        }
      },
      onChanged: {
        addListener(fn) {
          onStorageChangedListeners.push(fn);
        },
        removeListener(fn) {
          const idx = onStorageChangedListeners.indexOf(fn);
          if (idx >= 0) onStorageChangedListeners.splice(idx, 1);
        }
      }
    }
  };

  const sandbox = {
    Array,
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
    navigator: { platform: "MacIntel", userAgent: "Mozilla/5.0 (Macintosh)" },
    location: parsedDoc.location,
    window: fakeWindow,
    document: fakeDocument,
    chrome: fakeChrome
  };
  sandbox.globalThis = sandbox;

  function executeContentScript() {
    vm.runInNewContext(i18nCode + "\n;" + contentCode, sandbox, {
      filename: contentScriptPath,
      importModuleDynamically: vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER
    });
  }

  executeContentScript();

  return {
    advanceTime,
    sentMessages,
    parsedDoc,
    reinjectContentScript: executeContentScript,
    setSendMessageHandler(fn) {
      messageHandler = fn;
    },
    setSelectionCollapsed(collapsed) {
      selectionCollapsed = collapsed;
    },
    setSelectionRect(rect) {
      selectionRect = rect;
    },
    setClientRects(rects) {
      selectionClientRects = rects;
    },
    setPickedElement(el) {
      pickedEl = el;
      anchorNode = el;
      focusNode = el;
    },
    setSelectionNodes({ anchorNode: aNode, anchorOffset: aOff = 0, focusNode: fNode, focusOffset: fOff = 1 }) {
      anchorNode = aNode;
      anchorOffset = aOff;
      focusNode = fNode;
      focusOffset = fOff;
    },
    setActiveElement(el) {
      fakeDocument.activeElement = el;
    },
    setDocumentHidden(hidden) {
      fakeDocument.hidden = Boolean(hidden);
    },
    emitStorageChanged(changes, area = "local") {
      for (const [k, v] of Object.entries(changes)) {
        liveStorage[k] = v.newValue;
      }
      for (const fn of onStorageChangedListeners.slice()) {
        fn(changes, area);
      }
    },
    emitStorageChange(changes, area = "local") {
      this.emitStorageChanged(changes, area);
    },
    async sendRuntimeMessage(msg) {
      for (const fn of onMessageListeners.slice()) {
        let responseValue;
        const asyncHandled = fn(msg, {}, (res) => { responseValue = res; });
        if (asyncHandled) {
          return new Promise((resolve) => fn(msg, {}, resolve));
        }
        if (responseValue !== undefined) return responseValue;
      }
      return undefined;
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
    getAllHosts() {
      return documentElement.children.filter((c) => c.getAttribute("data-coding-rewind-ui") === "1");
    },
    getHost() {
      return this.getAllHosts()[0] || null;
    },
    getPill() {
      return this.getHost()?.shadowRoot?.querySelector(".rw-pill") || null;
    },
    getPillIcon() {
      return this.getPill()?.children.find((c) => c.className === "rw-pill-icon") || null;
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
  assert.equal(harness.getPillIcon()?.hidden, true);
  assert.equal(harness.getPillIcon()?.textContent, "");
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
  assert.equal(harness.getPillIcon()?.hidden, false);
  assert.equal(harness.getPillIcon()?.textContent, "…");
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
  harness.document.dispatch("mouseup", { path: [pill] });
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1, "click while saving is ignored even after 350ms cooldown");

  resolveInFlightSave({ status: "saved", toast: getToastMessages("auto").SAVED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "saved");
  assert.equal(harness.getPillIcon()?.hidden, false);
  assert.equal(harness.getPillIcon()?.textContent, "✓");
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
  resolveQueuedSave({ status: "queued", toast: getToastMessages("auto").QUEUED });
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "queued");
  assert.equal(harness.getPillLabel(), "待同步");
  harness.advanceTime(950);
  assert.equal(pill.getAttribute("data-state"), "hidden");

  harness.setSendMessageHandler(async () => ({ status: "saved", toast: getToastMessages("auto").SAVED }));
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

  finishSave({ status: "saved", toast: getToastMessages("auto").SAVED });
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

test("extractSessionTitle strips og:site_name suffixes across separators and falls back to og:title on web pages", () => {
  const separators = [" - ", " | ", " — ", " · ", " :: "];
  for (const sep of separators) {
    const doc = parseHtmlDocument(
      `<html><head>
        <title>Async Cancellation Patterns${sep}MDN Web Docs</title>
        <meta property="og:site_name" content="mdn web docs">
      </head><body><p>Body</p></body></html>`,
      { url: "https://developer.mozilla.org/en-US/docs/Web/JavaScript" }
    );
    assert.equal(
      extractSessionTitle(doc, "https://developer.mozilla.org/en-US/docs/Web/JavaScript"),
      "Async Cancellation Patterns",
      `separator ${JSON.stringify(sep)}`
    );
  }

  const fallbackDoc = parseHtmlDocument(
    `<html><head>
      <title>   </title>
      <meta property="og:site_name" content="Rust Blog">
      <meta property="og:title" content="Pinning and Self-Referential Types | Rust Blog">
    </head><body><h1>Ignored H1</h1></body></html>`,
    { url: "https://blog.rust-lang.org/2026/pinning" }
  );
  assert.equal(
    extractSessionTitle(fallbackDoc, "https://blog.rust-lang.org/2026/pinning"),
    "Pinning and Self-Referential Types"
  );
});

test("defuddle-grade code normalization preserves Shiki lines, strips highlighter gutters, and converts GitHub code tables", () => {
  const shikiHtml = `<pre class="shiki"><code class="language-ts"><span class="line"><span>const a = 1;</span></span>
<span class="line"></span>
<span class="line"><span>const b = 2;</span></span></code></pre>`;
  assert.equal(htmlToMarkdown(shikiHtml), "```ts\nconst a = 1;\n\nconst b = 2;\n```");

  const ecHtml = `<pre data-lang="rust"><code><div class="ec-line"><div class="gutter">1</div><div class="code">fn main() {<br></div></div>
<div class="ec-line"><div class="gutter">2</div><div class="code">    println!("ok");<br></div></div>
<div class="ec-line"><div class="gutter">3</div><div class="code">}</div></div></code></pre>`;
  assert.equal(htmlToMarkdown(ecHtml), '```rust\nfn main() {\n    println!("ok");\n}\n```');

  const pygmentsAndPrismHtml = `<pre class="syntax-go"><span class="line-numbers-rows"><span></span><span></span></span><code><span class="lineno">1 </span>package main
<span class="lineno">2 </span><span class="react-syntax-highlighter-line-number">2</span><span data-line-number="2"></span>func run() {}</code></pre>`;
  assert.equal(htmlToMarkdown(pygmentsAndPrismHtml), "```go\npackage main\nfunc run() {}\n```");

  const rougeTableHtml = `<div class="language-ruby"><table class="rouge-table"><tbody><tr>
    <td class="rouge-gutter gl"><pre class="lineno">1\n2</pre></td>
    <td class="rouge-code"><pre>puts :hello\nputs :world</pre></td>
  </tr></tbody></table></div>`;
  assert.equal(htmlToMarkdown(rougeTableHtml), "```ruby\nputs :hello\nputs :world\n```");

  const chromaHtml = `<div class="highlight"><table class="lntable"><tr>
    <td class="lntd"><pre><code><span class="lnt">1\n</span><span class="lnt">2\n</span></code></pre></td>
    <td class="lntd"><pre><code class="language-go">x := 1\ny := 2</code></pre></td>
  </tr></table></div>`;
  assert.equal(htmlToMarkdown(chromaHtml), "```go\nx := 1\ny := 2\n```");

  const githubTableDoc = parseHtmlDocument(
    `<div class="highlight highlight-source-python"><table class="highlight"><tbody>
      <tr id="row-1"><td class="blob-num" data-line-number="1"></td><td class="blob-code">def compute(x):</td></tr>
      <tr id="row-2"><td class="blob-num" data-line-number="2"></td><td class="blob-code">    return x * 2</td></tr>
    </tbody></table></div>`,
    { url: "https://github.com/org/repo/blob/main/app.py" }
  );
  assert.equal(
    htmlToMarkdown(githubTableDoc.body),
    "```python\ndef compute(x):\n    return x * 2\n```"
  );
  assert.equal(
    selectionToMarkdown(githubTableDoc.createRangeFromNode(githubTableDoc.querySelector("tbody"))),
    "```python\ndef compute(x):\n    return x * 2\n```"
  );

  const githubPreDoc = parseHtmlDocument(
    `<div class="highlight highlight-source-python"><pre id="gh-pre"><span>import</span> sys\nprint(sys.version)</pre></div>`
  );
  assert.equal(
    htmlToMarkdown(githubPreDoc.body),
    "```python\nimport sys\nprint(sys.version)\n```"
  );
});

test("turndown rich elements convert images, GFM task lists, mark, kbd, and details/summary", () => {
  const longDataUri = `data:image/png;base64,${"A".repeat(220)}`;
  const shortDataUri = "data:image/gif;base64,R0lGODlhAQABAAAAACw=";

  const richDoc = parseHtmlDocument(
    `<article id="rich">
      <p> diagram: <img alt="System [v2]" src="/assets/arch.png"> <img alt="huge" src="${longDataUri}"> <img alt="tiny" src="${shortDataUri}"> </p>
      <ul>
        <li><input type="checkbox" checked> Ship universal capsule</li>
        <li><input type="checkbox" id="dynamic-cb"> Add domain exclusions</li>
      </ul>
      <p>Press <kbd>⌘</kbd> + <kbd>Return</kbd> to <mark>launch thread</mark>.</p>
      <details>
        <summary>Implementation Notes</summary>
        <p>Keep content script idle footprint at zero imports.</p>
      </details>
    </article>`,
    { url: "https://example.com/blog/post" }
  );

  const ctx = extractClipContext({
    doc: richDoc,
    selectionRange: richDoc.createRangeFromNode(richDoc.querySelector("#rich")),
    url: "https://example.com/blog/post"
  });

  assert.match(ctx.selectedMarkdown, /!\[System \\\[v2\\\]\]\(https:\/\/example\.com\/assets\/arch\.png\)/);
  assert.doesNotMatch(ctx.selectedMarkdown, /!\[huge\]/);
  assert.match(ctx.selectedMarkdown, new RegExp(`!\\[tiny\\]\\(${shortDataUri}\\)`));
  assert.match(ctx.selectedMarkdown, /- \[x\] Ship universal capsule\n- \[ \] Add domain exclusions/);
  assert.match(ctx.selectedMarkdown, /Press <kbd>⌘<\/kbd> \+ <kbd>Return<\/kbd> to ==launch thread==\./);
  assert.match(ctx.selectedMarkdown, /\*\*Implementation Notes\*\*\n\nKeep content script idle footprint at zero imports\./);

  richDoc.querySelector("#dynamic-cb").checked = true;
  assert.match(htmlToMarkdown(richDoc.querySelector("ul")), /- \[x\] Add domain exclusions/);
  assert.equal(htmlToMarkdown('<img alt="rel" src="/img/a.png">'), "![rel](/img/a.png)");
});

test("content.js GestureGate filters right-click and stationary clicks while supporting drag, double-click, Shift-click, keyboard selection, resize, and visibilitychange", () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/article",
    html: `<html><head><title>Article</title></head><body><article><p id="picked">Universal web clipper gesture gating test.</p><a id="lnk" href="/more">More</a></article></body></html>`
  });

  harness.document.dispatch("mousedown", { button: 2, clientX: 100, clientY: 100 });
  harness.document.dispatch("mouseup", { button: 2, clientX: 160, clientY: 100 });
  harness.advanceTime(30);
  assert.equal(harness.getPill(), null, "right-click must never mount or pop the pill");

  harness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 100 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 102, clientY: 101, detail: 1, shiftKey: false });
  harness.advanceTime(30);
  assert.equal(harness.getPill(), null, "stationary single-click suppresses pill");

  const linkEl = harness.parsedDoc.querySelector("#lnk");
  harness.document.dispatch("mouseup", { button: 0, clientX: 102, clientY: 101, detail: 1, shiftKey: false, target: linkEl });
  harness.advanceTime(30);
  assert.equal(harness.getPill(), null, "stationary click on link suppresses pill");

  harness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 100 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 140, clientY: 102, detail: 1, shiftKey: false });
  harness.advanceTime(20);
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready", "drag >= 6px pops pill");

  harness.window.dispatch("resize");
  assert.equal(harness.getPill().getAttribute("data-state"), "hidden", "window resize hides ready pill");

  harness.document.dispatch("mousedown", { button: 0, clientX: 200, clientY: 200 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 200, clientY: 200, detail: 2, shiftKey: false });
  harness.advanceTime(20);
  assert.equal(harness.getPill().getAttribute("data-state"), "ready", "double-click word selection pops pill");

  harness.setDocumentHidden(true);
  harness.document.dispatch("visibilitychange");
  assert.equal(harness.getPill().getAttribute("data-state"), "hidden", "hidden tab dismisses pill");
  harness.setDocumentHidden(false);

  harness.document.dispatch("mousedown", { button: 0, clientX: 220, clientY: 200 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 220, clientY: 200, detail: 1, shiftKey: true });
  harness.advanceTime(20);
  assert.equal(harness.getPill().getAttribute("data-state"), "ready", "Shift+Click selection extension pops pill");

  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  assert.equal(harness.getPill().getAttribute("data-state"), "hidden");

  harness.document.dispatch("keyup", { key: "ArrowRight", shiftKey: true });
  harness.advanceTime(60);
  assert.equal(harness.getPill().getAttribute("data-state"), "hidden", "keyboard selection debounces 120ms");
  harness.advanceTime(70);
  assert.equal(harness.getPill().getAttribute("data-state"), "ready", "keyboard Shift+ArrowRight pops pill after 120ms");
});

test("content.js allows readonly inputs while suppressing pill inside editable inputs and live code editors without blocking Hyper+S", async () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/playground",
    html: `<html><body>
      <textarea id="ro-ta" readonly>Readonly snippet text</textarea>
      <input id="ro-in" type="text" readonly value="Readonly input value" />
      <textarea id="rw-ta">Editable textarea draft</textarea>
      <div id="ce" contenteditable="true"><p id="ce-p">Editable rich text</p></div>
      <div id="ce-ro" contenteditable="true" aria-readonly="true"><p id="ce-ro-p">Readonly rich view</p></div>
      <div class="monaco-editor"><div id="monaco-line">const live = true;</div></div>
      <div class="cm-editor"><div contenteditable="true"><span id="cm-live">let x = 1;</span></div></div>
      <div class="cm-editor"><div class="cm-content"><span id="cm-readonly">let y = 2;</span></div></div>
    </body></html>`,
    pickedSelector: "#ro-ta"
  });

  const triggerDragSelect = () => {
    harness.document.dispatch("mousedown", { button: 0, clientX: 80, clientY: 80 });
    harness.document.dispatch("mouseup", { button: 0, clientX: 160, clientY: 80, detail: 1 });
    harness.advanceTime(20);
  };

  harness.setPickedElement(harness.parsedDoc.querySelector("#ro-ta"));
  triggerDragSelect();
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready", "<textarea readonly> allows pill");

  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  harness.setPickedElement(harness.parsedDoc.querySelector("#ro-in"));
  triggerDragSelect();
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready", "<input readonly> allows pill");

  harness.setPickedElement(harness.parsedDoc.querySelector("#ce-ro-p"));
  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  triggerDragSelect();
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready", "aria-readonly='true' allows pill");

  harness.setPickedElement(harness.parsedDoc.querySelector("#cm-readonly"));
  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  triggerDragSelect();
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready", "read-only .cm-editor without contenteditable allows pill");

  for (const blockedSelector of ["#rw-ta", "#ce-p", "#monaco-line", "#cm-live"]) {
    harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
    harness.setPickedElement(harness.parsedDoc.querySelector(blockedSelector));
    triggerDragSelect();
    assert.equal(
      harness.getPill()?.getAttribute("data-state"),
      "hidden",
      `${blockedSelector} must suppress automatic floating pill`
    );
  }

  const hyperSave = harness.document.dispatch("keydown", {
    key: "s",
    code: "KeyS",
    ctrlKey: true,
    altKey: true,
    shiftKey: true,
    metaKey: true,
    repeat: false
  });
  assert.equal(hyperSave.defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1);
  assert.equal(harness.sentMessages[0].clip.selectedMarkdown, "let x = 1;");
});

test("content.js multi-line getClientRects anchors below forward end, flips above near bottom, and anchors above backward start", () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/long-article",
    html: `<html><body><article id="picked"><span id="first">Line one</span><span id="middle">Line two</span><span id="last">Line three</span></article></body></html>`,
    pickedSelector: "#picked"
  });
  harness.setViewportSize(1280, 800);

  const firstEl = harness.parsedDoc.querySelector("#first");
  const lastEl = harness.parsedDoc.querySelector("#last");

  harness.setSelectionNodes({ anchorNode: firstEl, focusNode: lastEl });
  harness.setClientRects([
    { left: 120, top: 100, right: 620, bottom: 124, width: 500, height: 24 },
    { left: 100, top: 126, right: 620, bottom: 150, width: 520, height: 24 },
    { left: 100, top: 152, right: 340, bottom: 176, width: 240, height: 24 }
  ]);
  harness.document.dispatch("mousedown", { button: 0, clientX: 130, clientY: 112 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 310, clientY: 168, detail: 1 });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.deepEqual(
    { left: pill.style.left, top: pill.style.top },
    { left: "252px", top: "184px" },
    "forward multi-line selection anchors below last line near release clientX"
  );

  harness.setClientRects([
    { left: 120, top: 710, right: 620, bottom: 734, width: 500, height: 24 },
    { left: 100, top: 736, right: 620, bottom: 760, width: 520, height: 24 },
    { left: 100, top: 762, right: 340, bottom: 786, width: 240, height: 24 }
  ]);
  harness.document.dispatch("mousedown", { button: 0, clientX: 130, clientY: 720 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 310, clientY: 774, detail: 1 });
  harness.advanceTime(20);
  assert.deepEqual(
    { left: pill.style.left, top: pill.style.top },
    { left: "252px", top: "676px" },
    "forward multi-line selection near viewport bottom flips above first line"
  );

  harness.setSelectionNodes({ anchorNode: lastEl, focusNode: firstEl });
  harness.setClientRects([
    { left: 120, top: 100, right: 620, bottom: 124, width: 500, height: 24 },
    { left: 100, top: 126, right: 620, bottom: 150, width: 520, height: 24 },
    { left: 100, top: 152, right: 340, bottom: 176, width: 240, height: 24 }
  ]);
  harness.document.dispatch("mousedown", { button: 0, clientX: 310, clientY: 168 });
  harness.document.dispatch("mouseup", { button: 0, clientX: 150, clientY: 112, detail: 1 });
  harness.advanceTime(20);
  assert.deepEqual(
    { left: pill.style.left, top: pill.style.top },
    { left: "92px", top: "66px" },
    "backward multi-line selection anchors above first line"
  );
});

test("content.js re-injection disposes prior Shadow DOM host and listeners so Hyper+S sends exactly one clip", async () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/reload-safety"
  });

  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);
  const firstHost = harness.getHost();
  assert.ok(firstHost);
  assert.equal(harness.getAllHosts().length, 1);

  harness.reinjectContentScript();
  assert.equal(firstHost.isConnected, false, "old Shadow DOM host is detached on re-injection");
  assert.equal(harness.getAllHosts().length, 0);

  harness.document.dispatch("mouseup", { path: [] });
  harness.advanceTime(20);
  assert.equal(harness.getAllHosts().length, 1, "only one UI host exists after re-injection");
  assert.equal(harness.getPill()?.getAttribute("data-state"), "ready");

  harness.advanceTime(500);
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
  assert.equal(harness.sentMessages.length, 1, "Hyper+S must fire only from the latest active instance");
});

test("options helpers and content.js enforce pill scope and excludedDomains while keeping Hyper+S active everywhere", async () => {
  assert.equal(resolvePillScope({}), "all");
  assert.equal(resolvePillScope({ showSelectionPill: true }), "all");
  assert.equal(resolvePillScope({ showSelectionPill: false }), "off");
  assert.equal(resolvePillScope({ selectionPillScope: "chat", showSelectionPill: true }), "chat");
  assert.equal(resolvePillScope({ selectionPillScope: "all", showSelectionPill: false }), "all");
  assert.equal(resolvePillScope({ selectionPillScope: "off", showSelectionPill: true }), "off");
  assert.ok(DEFAULT_EXCLUDED_DOMAINS.includes("docs.google.com"));
  assert.ok(DEFAULT_EXCLUDED_DOMAINS.includes("figma.com"));

  assert.deepEqual(
    parseExcludedDomains("  https://Docs.Google.com/document/d/1 , *.Figma.com\nnotion.so:443\ndocs.google.com "),
    ["docs.google.com", "figma.com", "notion.so"]
  );
  assert.deepEqual(parseExcludedDomains(""), []);

  const hnHarness = createContentScriptHarness({
    url: "https://news.ycombinator.com/item?id=1",
    html: `<html><head><title>Show HN | Hacker News</title></head><body><p id="picked">Interesting systems thread.</p></body></html>`,
    storageData: { selectionPillScope: "chat", showSelectionPill: true }
  });
  hnHarness.document.dispatch("mouseup", { path: [] });
  hnHarness.advanceTime(20);
  assert.equal(hnHarness.getPill(), null, "chat scope suppresses pill on Hacker News");

  hnHarness.emitStorageChanged({
    selectionPillScope: { newValue: "all" },
    showSelectionPill: { newValue: true }
  });
  hnHarness.document.dispatch("mouseup", { path: [] });
  hnHarness.advanceTime(20);
  assert.equal(hnHarness.getPill()?.getAttribute("data-state"), "ready", "switching to 'all' enables pill on Hacker News");

  hnHarness.emitStorageChanged({
    selectionPillScope: { newValue: "chat" }
  });
  assert.equal(hnHarness.getPill().getAttribute("data-state"), "hidden", "switching back to 'chat' immediately hides open pill");

  const chatHarness = createContentScriptHarness({
    url: "https://chatgpt.com/c/1",
    storageData: { selectionPillScope: "chat", showSelectionPill: true }
  });
  chatHarness.document.dispatch("mouseup", { path: [] });
  chatHarness.advanceTime(20);
  assert.equal(chatHarness.getPill()?.getAttribute("data-state"), "ready", "chat scope allows pill on chatgpt.com");

  const excludedHarness = createContentScriptHarness({
    url: "https://docs.google.com/document/d/abc/edit",
    html: `<html><head><title>Design Doc</title></head><body><p id="picked"> Canvas selection text </p></body></html>`,
    storageData: { selectionPillScope: "all", showSelectionPill: true }
  });
  excludedHarness.document.dispatch("mouseup", { path: [] });
  excludedHarness.advanceTime(20);
  assert.equal(excludedHarness.getPill(), null, "default excludedDomains suppresses pill on docs.google.com");

  const hyperOnExcluded = excludedHarness.document.dispatch("keydown", {
    key: "s",
    code: "KeyS",
    ctrlKey: true,
    altKey: true,
    shiftKey: true,
    metaKey: true,
    repeat: false
  });
  assert.equal(hyperOnExcluded.defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(excludedHarness.sentMessages.length, 1, "Hyper+S still captures on excluded domains");

  const extractedViaMenu = await excludedHarness.sendRuntimeMessage({ type: "REWIND_EXTRACT_SELECTION" });
  assert.equal(extractedViaMenu.clip.selectedMarkdown.trim(), "Canvas selection text");
});

test("background.js injectContentScriptIntoOpenTabs injects open http(s) tabs on install and ignores restricted tab rejections", async () => {
  const queries = [];
  const executions = [];

  const summary = await injectContentScriptIntoOpenTabs({
    tabsApi: {
      async query(filter) {
        queries.push(filter);
        return [
          { id: 101, url: "https://news.ycombinator.com/" },
          { id: 102, url: "https://chromewebstore.google.com/detail/xyz" },
          { url: "https://example.com/no-id" },
          { id: 103, url: "http://localhost:8080/docs" }
        ];
      }
    },
    scriptingApi: {
      async executeScript(args) {
        executions.push(args);
        if (args.target.tabId === 102) {
          throw new Error("Cannot access contents of url \"https://chromewebstore.google.com/detail/xyz\".");
        }
      }
    }
  });

  assert.deepEqual(queries, [{ url: ["https://*/*", "http://*/*"] }]);
  assert.deepEqual(
    executions.map((e) => ({ tabId: e.target.tabId, files: e.files })),
    [
      { tabId: 101, files: ["i18n.js", "content.js"] },
      { tabId: 102, files: ["i18n.js", "content.js"] },
      { tabId: 103, files: ["i18n.js", "content.js"] }
    ]
  );
  assert.deepEqual(summary, { attempted: 3, injected: 2 });

  const previousChrome = globalThis.chrome;
  const previousSelf = globalThis.self;
  let onInstalledListener = null;
  let onStartupListener = null;
  const installedExecutions = [];
  try {
    globalThis.chrome = {
      runtime: {
        onInstalled: { addListener(fn) { onInstalledListener = fn; } },
        onStartup: { addListener(fn) { onStartupListener = fn; } },
        onMessage: { addListener() {} }
      },
      contextMenus: {
        removeAll(cb) { if (cb) cb(); },
        create() {},
        onClicked: { addListener() {} }
      },
      commands: { onCommand: { addListener() {} } },
      tabs: {
        async query() {
          return [
            { id: 201, url: "https://chatgpt.com/c/1" },
            { id: 202, url: "https://chromewebstore.google.com/" }
          ];
        }
      },
      scripting: {
        async executeScript(args) {
          installedExecutions.push(args.target.tabId);
          if (args.target.tabId === 202) {
            throw new Error("Restricted tab");
          }
        }
      },
      storage: {
        local: {
          async get() { return { memosUrl: "", memosToken: "", outbox: [] }; },
          async set() {}
        }
      }
    };
    globalThis.self = { addEventListener() {} };

    await import("./background.js?on-installed-tab-injection");
    assert.equal(typeof onInstalledListener, "function");
    assert.equal(typeof onStartupListener, "function");

    onStartupListener();
    await new Promise((r) => setImmediate(r));
    assert.deepEqual(installedExecutions, [], "onStartup must not executeScript across tabs");

    onInstalledListener();
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    assert.deepEqual(installedExecutions, [201, 202], "onInstalled injects open tabs and ignores restricted tab failure");
  } finally {
    globalThis.chrome = previousChrome;
    globalThis.self = previousSelf;
  }
});

test("extractors.mjs handles non-Array iterable NodeList childNodes on Shiki code blocks and GitHub highlight tables", () => {
  function toStrictNodeListTree(node) {
    if (!node || typeof node !== "object") return node;
    const rawChildren = Array.from(node.childNodes || []);
    for (const child of rawChildren) {
      toStrictNodeListTree(child);
    }
    const indexed = {
      length: rawChildren.length,
      item(i) {
        return rawChildren[i] || null;
      },
      [Symbol.iterator]() {
        return rawChildren[Symbol.iterator]();
      }
    };
    rawChildren.forEach((child, idx) => {
      indexed[idx] = child;
    });
    Object.setPrototypeOf(indexed, null);
    node.childNodes = Object.freeze(indexed);
    const originalCloneNode = typeof node.cloneNode === "function" ? node.cloneNode.bind(node) : null;
    if (originalCloneNode) {
      node.cloneNode = (deep = false) => toStrictNodeListTree(originalCloneNode(deep));
    }
    return node;
  }

  const doc = parseHtmlDocument(
    `<html><head><title>Live DOM NodeList Check</title></head><body>
      <article id="root">
        <p>Inline <code>let count = 1;</code> sample.</p>
        <pre><code class="language-rust"><span class="line">fn main() {</span>\n<span class="line">    println!("ok");</span>\n<span class="line">}</span></code></pre>
        <div class="highlight highlight-source-python">
          <table class="highlight">
            <tr><td class="blob-num">1</td><td class="blob-code">def greet():</td></tr>
            <tr><td class="blob-num">2</td><td class="blob-code">    return "hi"</td></tr>
          </table>
        </div>
      </article>
    </body></html>`,
    { url: "https://github.com/org/repo/blob/main/README.md" }
  );

  const root = doc.querySelector("#root");
  const baseRange = doc.createRangeFromNode(root);
  const clonedFragment = toStrictNodeListTree(baseRange.cloneContents());
  toStrictNodeListTree(doc);

  assert.equal(Array.isArray(root.childNodes), false);
  assert.equal(root.childNodes.some, undefined);
  assert.equal(root.childNodes.map, undefined);
  assert.equal(Array.isArray(clonedFragment.childNodes), false);
  assert.equal(clonedFragment.childNodes.some, undefined);

  const directMd = htmlToMarkdown(root, { baseUrl: "https://github.com/org/repo/blob/main/README.md" });
  assert.match(directMd, /Inline `let count = 1;` sample\./);
  assert.match(directMd, /```rust\nfn main\(\) \{\n    println!\("ok"\);\n\}\n```/);
  assert.match(directMd, /```python\ndef greet\(\):\n    return "hi"\n```/);

  const rangeWithNodeList = {
    commonAncestorContainer: baseRange.commonAncestorContainer,
    startContainer: baseRange.startContainer,
    startOffset: baseRange.startOffset,
    endContainer: baseRange.endContainer,
    endOffset: baseRange.endOffset,
    intersectsNode(node) {
      return baseRange.intersectsNode(node);
    },
    toString() {
      return root.textContent;
    },
    cloneContents() {
      return clonedFragment;
    },
    cloneRange() {
      return this;
    }
  };

  const md = selectionToMarkdown(rangeWithNodeList, "https://github.com/org/repo/blob/main/README.md");
  assert.equal(md, directMd);

  const clip = extractClipContext({
    doc,
    selectionRange: rangeWithNodeList,
    selectedText: root.textContent.trim(),
    url: "https://github.com/org/repo/blob/main/README.md"
  });
  assert.equal(clip.selectedMarkdown, md);
});

test("content.js suppresses trailing document mouseup when pill hides mid-click so capsule does not re-appear", async () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/mid-click-hide",
    sendMessageImpl: async () => {
      throw new Error("Simulated save failure before mouse button release");
    }
  });

  harness.document.dispatch("mousedown", { button: 0, clientX: 300, clientY: 210, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 380, clientY: 210, detail: 1, path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.equal(pill.getAttribute("data-state"), "ready");
  assert.equal(pill.style.display, "inline-flex");

  harness.document.dispatch("mousedown", { button: 0, clientX: 340, clientY: 175, path: [pill] });
  pill.dispatch("mousedown", { button: 0, clientX: 340, clientY: 175, path: [pill] });

  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "hidden", "rejected save hides pill before mouseup");
  assert.equal(pill.style.display, "none");

  harness.document.dispatch("mouseup", { button: 0, clientX: 340, clientY: 175, detail: 1, path: [] });
  harness.advanceTime(30);
  assert.equal(pill.getAttribute("data-state"), "hidden", "trailing mouseup on document must not re-open pill");
  assert.equal(pill.style.display, "none");

  harness.document.dispatch("mousedown", { button: 0, clientX: 300, clientY: 210, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 390, clientY: 210, detail: 1, path: [] });
  harness.advanceTime(20);
  assert.equal(pill.getAttribute("data-state"), "ready", "subsequent genuine drag selection still opens pill");
});

test("content.js ignores unrelated focused composers and supports real Blink readonly textarea/input selectionStart/End", async () => {
  const harness = createContentScriptHarness({
    url: "https://chatgpt.com/c/focused-composer",
    html: `<html><head><title>Chat Thread</title></head><body>
      <article><p id="picked">Important assistant paragraph while composer keeps focus.</p></article>
      <div id="composer" contenteditable="true"><p id="composer-p">Drafting next prompt</p></div>
      <input id="search-box" type="text" value="query" />
      <textarea id="ro-blink" readonly>const token = computeSignature(payload);</textarea>
    </body></html>`,
    pickedSelector: "#picked"
  });

  const composerEl = harness.parsedDoc.querySelector("#composer");
  const searchBoxEl = harness.parsedDoc.querySelector("#search-box");
  const pickedEl = harness.parsedDoc.querySelector("#picked");

  harness.setActiveElement(composerEl);
  harness.setPickedElement(pickedEl);
  harness.document.dispatch("mousedown", { button: 0, clientX: 120, clientY: 200, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 280, clientY: 200, detail: 1, path: [] });
  harness.advanceTime(20);
  assert.equal(
    harness.getPill()?.getAttribute("data-state"),
    "ready",
    "unrelated focused contenteditable composer must not suppress prose selection pill"
  );

  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  harness.setActiveElement(searchBoxEl);
  harness.document.dispatch("mousedown", { button: 0, clientX: 120, clientY: 200, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 280, clientY: 200, detail: 1, path: [] });
  harness.advanceTime(20);
  assert.equal(
    harness.getPill()?.getAttribute("data-state"),
    "ready",
    "unrelated focused text input must not suppress prose selection pill"
  );

  harness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  harness.setActiveElement(composerEl);
  harness.setPickedElement(harness.parsedDoc.querySelector("#composer-p"));
  harness.document.dispatch("mousedown", { button: 0, clientX: 120, clientY: 400, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 240, clientY: 400, detail: 1, path: [] });
  harness.advanceTime(20);
  assert.equal(
    harness.getPill()?.getAttribute("data-state"),
    "hidden",
    "selection inside focused contenteditable composer still suppresses pill"
  );

  const roTextarea = harness.parsedDoc.querySelector("#ro-blink");
  roTextarea.value = "const token = computeSignature(payload);";
  roTextarea.selectionStart = 6;
  roTextarea.selectionEnd = 22;
  roTextarea.getBoundingClientRect = () => ({
    left: 200,
    top: 180,
    right: 500,
    bottom: 240,
    width: 300,
    height: 60
  });

  harness.setSelectionCollapsed(true);
  harness.setActiveElement(roTextarea);
  harness.document.dispatch("mousedown", { button: 0, clientX: 220, clientY: 200, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 340, clientY: 200, detail: 1, path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.equal(pill.getAttribute("data-state"), "ready", "Blink readonly textarea with collapsed window.getSelection shows pill");
  harness.document.dispatch("selectionchange");
  assert.equal(pill.getAttribute("data-state"), "ready", "selectionchange keeps pill open while readonly control selection is active");

  harness.advanceTime(400);
  pill.dispatch("mousedown", { button: 0, path: [pill] });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 1);
  assert.equal(harness.sentMessages[0].clip.selectedMarkdown, "token = computeS");

  harness.advanceTime(1000);
  roTextarea.selectionStart = 14;
  roTextarea.selectionEnd = 39;
  const hyperRo = harness.document.dispatch("keydown", {
    key: "s",
    code: "KeyS",
    ctrlKey: true,
    altKey: true,
    shiftKey: true,
    metaKey: true,
    repeat: false
  });
  assert.equal(hyperRo.defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(harness.sentMessages.length, 2);
  assert.equal(harness.sentMessages[1].clip.selectedMarkdown, "computeSignature(payload)");

  roTextarea.selectionStart = 5;
  roTextarea.selectionEnd = 5;
  harness.document.dispatch("selectionchange");
  assert.equal(pill.getAttribute("data-state"), "hidden");
});

test("content.js merges inline client rects on the same visual line instead of treating inline code/strong spans as multi-line", () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/inline-rects",
    html: `<html><body><p id="picked"><span>Use </span><code>resolveSelectionPlacement</code><strong> now</strong></p></body></html>`,
    pickedSelector: "#picked"
  });
  harness.setViewportSize(1280, 800);

  harness.setClientRects([
    { left: 100, top: 200, right: 160, bottom: 220, width: 60, height: 20 },
    { left: 160, top: 202, right: 340, bottom: 218, width: 180, height: 16 },
    { left: 340, top: 200, right: 400, bottom: 220, width: 60, height: 20 }
  ]);

  harness.document.dispatch("mousedown", { button: 0, clientX: 105, clientY: 210, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 395, clientY: 210, detail: 1, path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.equal(pill.getAttribute("data-state"), "ready");
  assert.deepEqual(
    { left: pill.style.left, top: pill.style.top },
    { left: "192px", top: "166px" },
    "merged single-line inline rects anchor centered above [100..400] rather than below the last inline box"
  );
});

test("content.js cleans orphan Shadow DOM hosts, prevents storage.local.get init race, and guards slow/cancelled in-flight saves", async () => {
  const raceHarness = createContentScriptHarness({
    url: "https://example.com/race-and-orphans",
    storageData: {
      selectionPillScope: "all",
      showSelectionPill: true,
      excludedDomains: ["blocked.example.net"]
    },
    storageGetDelayMs: 50,
    preExistingOrphanHosts: 2
  });

  assert.equal(raceHarness.getAllHosts().length, 0, "pre-existing cross-world orphan Shadow DOM hosts removed on startup");

  raceHarness.advanceTime(10);
  raceHarness.emitStorageChanged({
    selectionPillScope: { oldValue: "all", newValue: "off" },
    showSelectionPill: { oldValue: true, newValue: false }
  });

  raceHarness.advanceTime(60);
  raceHarness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 200, path: [] });
  raceHarness.document.dispatch("mouseup", { button: 0, clientX: 240, clientY: 200, detail: 1, path: [] });
  raceHarness.advanceTime(20);
  assert.equal(
    raceHarness.getPill(),
    null,
    "stale storage.local.get callback must not overwrite newer storage.onChanged 'off' scope"
  );

  const pendingResolvers = [];
  const saveHarness = createContentScriptHarness({
    url: "https://example.com/slow-save",
    sendMessageImpl: () =>
      new Promise((resolve) => {
        pendingResolvers.push(resolve);
      })
  });

  const fireHyperS = () =>
    saveHarness.document.dispatch("keydown", {
      key: "s",
      code: "KeyS",
      ctrlKey: true,
      altKey: true,
      shiftKey: true,
      metaKey: true,
      repeat: false
    });

  assert.equal(fireHyperS().defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(saveHarness.sentMessages.length, 1);

  saveHarness.advanceTime(600);
  assert.equal(fireHyperS().defaultPrevented, true);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(saveHarness.sentMessages.length, 1, "second Hyper+S >350ms while Save #1 is still in flight must not duplicate");

  pendingResolvers.shift()({ status: "saved", toast: getToastMessages("auto").SAVED });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(saveHarness.getToast()?.getAttribute("data-visible"), "true");

  saveHarness.advanceTime(2500);
  saveHarness.document.dispatch("mousedown", { button: 0, clientX: 200, clientY: 210, path: [] });
  saveHarness.document.dispatch("mouseup", { button: 0, clientX: 320, clientY: 210, detail: 1, path: [] });
  saveHarness.advanceTime(20);
  const pill = saveHarness.getPill();
  assert.equal(pill.getAttribute("data-state"), "ready");

  pill.dispatch("mousedown", { button: 0, path: [pill] });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "saving");
  assert.equal(saveHarness.sentMessages.length, 2);

  saveHarness.document.dispatch("keydown", { key: "Escape", code: "Escape" });
  assert.equal(pill.getAttribute("data-state"), "hidden");

  saveHarness.advanceTime(400);
  saveHarness.document.dispatch("mousedown", { button: 0, clientX: 200, clientY: 210, path: [] });
  saveHarness.document.dispatch("mouseup", { button: 0, clientX: 320, clientY: 210, detail: 1, path: [] });
  saveHarness.advanceTime(20);
  assert.equal(pill.getAttribute("data-state"), "ready");

  pill.dispatch("mousedown", { button: 0, path: [pill] });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "saving");
  assert.equal(saveHarness.sentMessages.length, 3);

  pendingResolvers[0]({ status: "saved", toast: getToastMessages("auto").SAVED });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(
    pill.getAttribute("data-state"),
    "saving",
    "stale Save #1 completion after Escape must not morph or hide Save #2's active saving pill"
  );

  pendingResolvers[1]({ status: "queued", toast: getToastMessages("auto").QUEUED });
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(pill.getAttribute("data-state"), "queued", "Save #2 completion morphs pill cleanly");

  const deadMsgRes = await saveHarness.sendRuntimeMessage({ type: "REWIND_TRIGGER_CAPTURE" });
  assert.equal(deadMsgRes, undefined);
});

test("extractors.mjs and memos_payload.mjs block control-char URL schemes, encode Markdown parens/brackets, and escape kbd HTML", () => {
  const html = `
    <div>
      <p><a href="java&#10;script:alert(1)">Bypass Link</a></p>
      <p><a href="&#1;vbscript:msgbox(1)">VB Link</a></p>
      <p><a href="https://en.wikipedia.org/wiki/Closure_(computer_programming)">[Closure] Guide](https://evil.example)[x</a></p>
      <p><a href="https://example.com/api"><code>items[0]</code></a></p>
      <p><img alt="[Diagram] [1]" src="https://example.com/my pic (1).png"></p>
      <p><img alt="xss" src="java&#9;script:alert(1)"><img alt="html" src="data:text/html;base64,PHNjcmlwdD4="></p>
      <p><kbd>&lt;img src=x onerror=alert(1)&gt; &amp; key</kbd></p>
    </div>
  `;
  const md = htmlToMarkdown(parseHtmlDocument(html, { url: "https://example.com/post" }).body, {
    baseUrl: "https://example.com/post"
  });

  assert.match(md, /^Bypass Link$/m);
  assert.match(md, /^VB Link$/m);
  assert.doesNotMatch(md, /javascript:|vbscript:|data:text\/html/i);
  assert.match(
    md,
    /\[\\\[Closure\\\] Guide\\\]\(https:\/\/evil\.example\)\\\[x\]\(https:\/\/en\.wikipedia\.org\/wiki\/Closure_%28computer_programming%29\)/
  );
  assert.match(md, /\[`items\[0\]`\]\(https:\/\/example\.com\/api\)/);
  assert.match(md, /!\[\\\[Diagram\\\] \\\[1\\\]\]\(https:\/\/example\.com\/my%20pic%20%281%29\.png\)/);
  assert.match(md, /<kbd>&lt;img src=x onerror=alert\(1\)&gt; &amp; key<\/kbd>/);

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

test("extractors.mjs preserves multi-line code across hljs-ln inside pre, token-line / cm-line wrappers, and Chroma lntable selections", () => {
  const hljsDoc = parseHtmlDocument(`
    <pre><code class="hljs language-javascript"><table class="hljs-ln"><tbody>
      <tr id="hl-r1"><td class="hljs-ln-numbers" data-line-number="1">1</td><td class="hljs-ln-code">const alpha = 1;</td></tr>
      <tr id="hl-r2"><td class="hljs-ln-numbers" data-line-number="2">2</td><td class="hljs-ln-code">const beta = 2;</td></tr>
    </tbody></table></code></pre>
  `);
  assert.equal(
    htmlToMarkdown(hljsDoc.body),
    "```javascript\nconst alpha = 1;\nconst beta = 2;\n```"
  );
  const hljsRowSelection = selectionToMarkdown(hljsDoc.createRangeFromNode(hljsDoc.querySelector("tbody")));
  assert.equal(hljsRowSelection, "```javascript\nconst alpha = 1;\nconst beta = 2;\n```");

  const prismCmDoc = parseHtmlDocument(`
    <div>
      <pre class="prism-code language-tsx"><div class="token-line"><span>const view = 1;</span></div><div class="token-line"><span>export default view;</span></div></pre>
      <pre data-language="sql"><div class="cm-line">SELECT id</div><div class="cm-line">FROM clips;</div></pre>
    </div>
  `);
  assert.equal(
    htmlToMarkdown(prismCmDoc.body),
    "```tsx\nconst view = 1;\nexport default view;\n```\n\n```sql\nSELECT id\nFROM clips;\n```"
  );

  const chromaDoc = parseHtmlDocument(`
    <div class="highlight">
      <table class="lntable"><tbody id="chroma-body"><tr>
        <td class="lntd"><pre><span class="lnt">1\n</span><span class="lnt">2\n</span></pre></td>
        <td class="lntd"><pre><code class="language-go"><span class="line">package main</span>\n<span class="line">func main() {}</span></code></pre></td>
      </tr></tbody></table>
    </div>
  `);
  assert.equal(
    selectionToMarkdown(chromaDoc.createRangeFromNode(chromaDoc.querySelector("#chroma-body"))),
    "```go\npackage main\nfunc main() {}\n```"
  );
});

test("options.html, options.js, and content.js normalize URL/IPv6 domains and persist pill preferences without requiring Memos URL", async () => {
  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const optionsHtml = fs.readFileSync(path.join(extensionDir, "options.html"), "utf8");
  const memosUrlTag = optionsHtml.match(/<input[^>]*id="memos-url"[^>]*>/)?.[0] || "";
  assert.ok(memosUrlTag, "expected #memos-url input in options.html");
  assert.doesNotMatch(memosUrlTag, /\brequired\b/, "#memos-url must not require non-empty URL to save pill preferences");

  assert.equal(normalizeDomainEntry("https://user:secret@internal.corp.com/docs?x=1#top"), "internal.corp.com");
  assert.equal(normalizeDomainEntry("[::1]:8080"), "[::1]");
  assert.equal(normalizeDomainEntry("::1"), "[::1]");
  assert.equal(normalizeDomainEntry("http://[::1]:8080/memos"), "[::1]");
  assert.equal(normalizeDomainEntry("*.Figma.com."), "figma.com");
  assert.equal(normalizeDomainEntry("http://"), "");
  assert.deepEqual(
    parseExcludedDomains("https://user:secret@internal.corp.com/docs\n[::1]:8080, ::1, *.figma.com"),
    ["internal.corp.com", "[::1]", "figma.com"]
  );

  const ipv6Harness = createContentScriptHarness({
    url: "http://[::1]:8080/workspace",
    storageData: { selectionPillScope: "all", showSelectionPill: true, excludedDomains: ["[::1]:8080"] }
  });
  ipv6Harness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 120, path: [] });
  ipv6Harness.document.dispatch("mouseup", { button: 0, clientX: 220, clientY: 120, detail: 1, path: [] });
  ipv6Harness.advanceTime(20);
  assert.equal(ipv6Harness.getPill(), null, "IPv6 host [::1] matches excludedDomains entry [::1]:8080");

  const corpHarness = createContentScriptHarness({
    url: "https://wiki.internal.corp.com/runbook",
    storageData: {
      selectionPillScope: "all",
      showSelectionPill: true,
      excludedDomains: ["https://user:secret@internal.corp.com/docs"]
    }
  });
  corpHarness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 120, path: [] });
  corpHarness.document.dispatch("mouseup", { button: 0, clientX: 220, clientY: 120, detail: 1, path: [] });
  corpHarness.advanceTime(20);
  assert.equal(corpHarness.getPill(), null, "URL with credentials normalizes to internal.corp.com and matches subdomain");

  const prevDoc = globalThis.document;
  const prevChrome = globalThis.chrome;
  try {
    const makeControl = (initialValue = "") => {
      const listeners = new Map();
      const attrs = {};
      return {
        value: initialValue,
        hidden: false,
        textContent: "",
        setAttribute(k, v) {
          attrs[k] = String(v);
        },
        getAttribute(k) {
          return attrs[k] ?? null;
        },
        addEventListener(type, fn) {
          if (!listeners.has(type)) listeners.set(type, []);
          listeners.get(type).push(fn);
        },
        async trigger(type) {
          for (const fn of listeners.get(type) || []) {
            await fn({ preventDefault() {} });
          }
        }
      };
    };

    const controls = {
      "ui-language": makeControl("auto"),
      "settings-form": makeControl(),
      "memos-url": makeControl(""),
      "memos-token": makeControl(""),
      "pill-scope": makeControl("all"),
      "excluded-domains": makeControl(""),
      "test-btn": makeControl(),
      "flush-btn": makeControl(),
      status: makeControl(),
      "outbox-count": makeControl()
    };

    const stored = {
      memosUrl: "",
      memosToken: "",
      selectionPillScope: "all",
      showSelectionPill: true,
      excludedDomains: DEFAULT_EXCLUDED_DOMAINS.slice(),
      outbox: []
    };

    globalThis.document = {
      documentElement: { lang: "zh-CN" },
      getElementById(id) {
        return controls[id] || null;
      },
      querySelectorAll() {
        return [];
      }
    };
    globalThis.chrome = {
      storage: {
        local: {
          async get() {
            return { ...stored };
          },
          async set(patch) {
            Object.assign(stored, patch);
          },
          async remove(keys) {
            for (const k of keys) delete stored[k];
          }
        },
        onChanged: { addListener() {} }
      },
      permissions: {
        async contains() {
          return true;
        },
        async request() {
          return true;
        }
      },
      runtime: {
        async sendMessage() {
          return { ok: true, flushed: 0, remaining: 0 };
        }
      }
    };

    await import("./options.js?independent-prefs-check");
    await new Promise((r) => setImmediate(r));

    controls["excluded-domains"].value = "https://user:pw@internal.corp.com/a\n[::1]:8080";
    await controls["excluded-domains"].trigger("change");
    assert.deepEqual(stored.excludedDomains, ["internal.corp.com", "[::1]"]);
    assert.equal(controls["excluded-domains"].value, "internal.corp.com\n[::1]");

    controls["pill-scope"].value = "chat";
    await controls["pill-scope"].trigger("change");
    assert.equal(stored.selectionPillScope, "chat");
    assert.equal(stored.showSelectionPill, undefined);

    controls["pill-scope"].value = "chat";
    controls["memos-url"].value = "";
    await controls["settings-form"].trigger("submit");
    assert.equal(stored.selectionPillScope, "chat");
    assert.equal(stored.showSelectionPill, undefined);
    assert.equal(stored.memosUrl, "");
    assert.match(controls.status.textContent, /(?:设置已保存|Settings saved)/);
    assert.equal(controls.status.getAttribute("data-kind"), "ok");

    controls["pill-scope"].value = "off";
    controls["excluded-domains"].value = "figma.com";
    controls["memos-url"].value = "not-a-valid-url";
    await controls["settings-form"].trigger("submit");
    assert.equal(stored.selectionPillScope, "off", "pill scope still saves even when Memos URL fails validation");
    assert.equal(stored.showSelectionPill, undefined);
    assert.deepEqual(stored.excludedDomains, ["figma.com"]);
    assert.equal(controls.status.getAttribute("data-kind"), "error");
  } finally {
    globalThis.document = prevDoc;
    globalThis.chrome = prevChrome;
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
  harness.document.dispatch("mousedown", { path: [] });
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

test("testMemosConnection, saveClipWithOutbox, and background context menu localize to English", async (t) => {
  const invalidUrl = await testMemosConnection({
    baseUrl: "not-a-url",
    token: "",
    fetchImpl: globalThis.fetch,
    locale: "en"
  });
  assert.equal(invalidUrl.ok, false);
  assert.equal(invalidUrl.message, "Please enter a valid Memos server URL");

  const httpFail = await testMemosConnection({
    baseUrl: "https://memos.internal.test",
    token: "tok",
    fetchImpl: async () => ({ ok: false, status: 401 }),
    locale: "en"
  });
  assert.equal(httpFail.ok, false);
  assert.equal(httpFail.message, "Connection failed (HTTP 401)");

  const okConn = await testMemosConnection({
    baseUrl: "https://memos.internal.test",
    token: "tok",
    fetchImpl: async () => ({ ok: true, status: 200, async json() { return { memos: [] }; } }),
    locale: "en"
  });
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

function createOptionsPageTestHarness({ persistedInit = {}, uiLanguage = "zh-CN", fetchImpl, tabsCreate, openImpl } = {}) {
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
    node.removeAttribute = (name) => {
      delete node.attributes[String(name).toLowerCase()];
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
    memosUrl: "",
    memosToken: "",
    selectionPillScope: "all",
    excludedDomains: DEFAULT_EXCLUDED_DOMAINS.slice(),
    uiLanguage: "auto",
    outbox: [],
    ...persistedInit
  };
  const setCalls = [];
  const removeCalls = [];
  const sentRuntimeMessages = [];
  let storageChangedListener = null;

  globalThis.document = parsed;
  if (fetchImpl) {
    globalThis.fetch = fetchImpl;
  }
  if (openImpl !== undefined) {
    globalThis.open = openImpl;
  }
  globalThis.chrome = {
    i18n: { getUILanguage: () => uiLanguage },
    permissions: { async request() { return true; } },
    tabs: tabsCreate ? { create: tabsCreate } : undefined,
    runtime: {
      async sendMessage(msg) {
        sentRuntimeMessages.push(msg);
        return { ok: true, flushed: persisted.outbox.length, remaining: 0 };
      }
    },
    storage: {
      local: {
        async get() { return { ...persisted }; },
        async set(patch) {
          setCalls.push(patch);
          Object.assign(persisted, patch);
        },
        async remove(keys) {
          removeCalls.push(keys);
          for (const k of keys) delete persisted[k];
        }
      },
      onChanged: {
        addListener(fn) {
          storageChangedListener = fn;
        }
      }
    }
  };

  return {
    parsed,
    optionsHtml,
    persisted,
    setCalls,
    removeCalls,
    sentRuntimeMessages,
    emitStorageChange(changes) {
      storageChangedListener?.(changes, "local");
    }
  };
}

test("options.html and initOptionsPage switch UI language live and persist uiLanguage immediately", async (t) => {
  const originalDocument = globalThis.document;
  const originalChrome = globalThis.chrome;
  const originalFetch = globalThis.fetch;
  t.after(() => {
    if (originalDocument === undefined) delete globalThis.document;
    else globalThis.document = originalDocument;
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (originalFetch === undefined) delete globalThis.fetch;
    else globalThis.fetch = originalFetch;
  });

  const fetchCalls = [];
  const { parsed, persisted, setCalls } = createOptionsPageTestHarness({
    persistedInit: {
      memosUrl: "https://memos.internal.test",
      memosToken: "tok-1",
      outbox: [{ clipId: "rw-1" }, { clipId: "rw-2" }]
    },
    fetchImpl: async (url, init) => {
      fetchCalls.push({ url, init });
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json; charset=utf-8" },
        async json() { return { memos: [] }; }
      };
    }
  });

  initOptionsPage();
  await new Promise((r) => setImmediate(r));

  assert.equal(parsed.title, "Coding Rewind 网页扩展设置");
  assert.equal(parsed.getElementById("connection-heading").textContent, "云端同步");
  assert.equal(parsed.getElementById("open-console-btn").textContent, "打开后台拿令牌 ↗");
  assert.equal(parsed.getElementById("open-console-btn").disabled, false);
  assert.equal(parsed.getElementById("memos-token").value, "");
  assert.equal(parsed.getElementById("memos-token").placeholder, "已保存，留空则保留现有令牌");
  assert.equal(parsed.getElementById("test-btn").textContent, "测试连接");
  assert.equal(parsed.getElementById("outbox-count").textContent, "待同步片段：2 条");

  const languageSelect = parsed.getElementById("ui-language");
  languageSelect.value = "en";
  await languageSelect.dispatch("change");

  assert.deepEqual(setCalls.at(-1), { uiLanguage: "en" });
  assert.equal(parsed.documentElement.lang, "en");
  assert.equal(parsed.title, "Coding Rewind Web Clipper Settings");
  assert.equal(parsed.getElementById("connection-heading").textContent, "Cloud Sync");
  assert.equal(parsed.getElementById("open-console-btn").textContent, "Get Token ↗");
  assert.equal(parsed.getElementById("memos-token").placeholder, "Saved; leave blank to keep existing token");
  assert.equal(parsed.getElementById("test-btn").textContent, "Test Connection");
  assert.equal(parsed.getElementById("memos-url").placeholder, "Enter Memos server URL");
  assert.equal(parsed.getElementById("outbox-count").textContent, "Pending clips: 2");
  assert.equal(parsed.getElementById("save-btn").textContent, "Save Settings");
  assert.equal(parsed.querySelector('label[for="pill-scope"]')?.textContent, "Stash Pill");
  assert.equal(parsed.querySelector('label[for="excluded-domains"]')?.textContent, "Excluded Domains");

  await parsed.getElementById("settings-form").dispatch("submit");
  assert.equal(parsed.getElementById("status").textContent, "Settings saved. Connected; clips can be read.");
  assert.equal(parsed.getElementById("status").getAttribute("data-kind"), "ok");
  assert.equal(persisted.uiLanguage, "en");
  assert.equal(persisted.memosToken, "tok-1");
  assert.equal(parsed.getElementById("memos-token").value, "");
  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].url, "https://memos.internal.test/api/memos?pageSize=1");
  assert.equal(fetchCalls[0].init.headers.Authorization, "Bearer tok-1");
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

  const createdCalls = [];
  let storageChangedListener;
  globalThis.chrome = {
    runtime: {
      onInstalled: { addListener() {} },
      onStartup: { addListener() {} },
      onMessage: { addListener() {} }
    },
    contextMenus: {
      removeAll(cb) {
        setTimeout(cb, 5);
      },
      create(item, cb) {
        createdCalls.push(item);
        if (cb) setTimeout(cb, 5);
      },
      update(_id, _patch, cb) {
        if (cb) setTimeout(cb, 5);
      },
      onClicked: { addListener() {} }
    },
    commands: { onCommand: { addListener() {} } },
    storage: {
      local: {
        async get() { return { uiLanguage: "zh-CN", outbox: [] }; },
        async set() {}
      },
      onChanged: { addListener(fn) { storageChangedListener = fn; } }
    }
  };
  globalThis.self = { addEventListener() {} };

  await import("./background.js?serialization-test");
  assert.ok(true);
});

test("content.js switches capsule language live from zh-CN to en on universal web selections", async () => {
  const harness = createContentScriptHarness({
    url: "https://example.com/universal-lang-switch",
    html: `<html><head><title>Universal Post</title></head><body><article><p id="picked">Live localized capsule switch verification on general web pages.</p></article></body></html>`,
    uiLanguage: "zh-CN",
    storageData: { selectionPillScope: "all" }
  });

  harness.document.dispatch("mousedown", { button: 0, clientX: 100, clientY: 100, path: [] });
  harness.document.dispatch("mouseup", { button: 0, clientX: 200, clientY: 100, detail: 1, path: [] });
  harness.advanceTime(20);

  const pill = harness.getPill();
  assert.ok(pill);
  assert.equal(pill.getAttribute("data-state"), "ready");
  assert.equal(pill.getAttribute("aria-label"), "暂存选中文本");
  assert.equal(harness.getPillLabel(), "暂存");

  harness.emitStorageChange({ uiLanguage: { oldValue: "zh-CN", newValue: "en" } });
  assert.equal(pill.getAttribute("aria-label"), "Stash selected text");
  assert.equal(harness.getPillLabel(), "Stash");

  harness.emitStorageChange({ uiLanguage: { oldValue: "en", newValue: "zh-CN" } });
  assert.equal(pill.getAttribute("aria-label"), "暂存选中文本");
  assert.equal(harness.getPillLabel(), "暂存");
});

test("Cloud Sync onboarding copy, deploy guide link, and i18n messages avoid em dashes and expose required attributes", () => {
  const extensionDir = path.dirname(fileURLToPath(import.meta.url));
  const optionsHtml = fs.readFileSync(path.join(extensionDir, "options.html"), "utf8");
  const parsed = parseHtmlDocument(optionsHtml);

  assert.equal(parsed.querySelector("#connection-heading")?.textContent.trim(), "云端同步");
  const introLine1 = parsed.querySelector('[data-i18n="cloudSyncIntroLine1"]')?.textContent.trim();
  const introLine2 = parsed.querySelector('[data-i18n="cloudSyncIntroLine2"]')?.textContent.trim();
  assert.ok(introLine1 && introLine1.length > 0);
  assert.ok(introLine2 && introLine2.length > 0);

  const guideLink = parsed.querySelector("#deploy-guide-link");
  assert.ok(guideLink, "expected #deploy-guide-link");
  assert.equal(
    guideLink.getAttribute("href"),
    "https://github.com/semantic-craft/coding-rewind/tree/main/deploy/vps"
  );
  assert.equal(guideLink.getAttribute("target"), "_blank");
  assert.equal(guideLink.getAttribute("rel"), "noopener noreferrer");

  const consoleBtn = parsed.querySelector("#open-console-btn");
  assert.ok(consoleBtn, "expected #open-console-btn");
  assert.equal(consoleBtn.disabled, true);
  assert.equal(parsed.querySelector("#memos-token")?.getAttribute("placeholder"), "请输入访问令牌");

  const i18n = globalThis.CodingRewindI18n;
  for (const locale of ["zh-CN", "en"]) {
    for (const [key, val] of Object.entries(i18n.MESSAGES[locale])) {
      assert.doesNotMatch(val, /\u2014/, `${locale}.${key} must not contain em dashes`);
    }
  }
});

test("testMemosConnection rejects HTML 200 pages, invalid JSON, and objects missing memos array", async () => {
  const htmlWithHeader = await testMemosConnection({
    baseUrl: "https://memos.internal.test",
    token: "tok",
    locale: "zh-CN",
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      headers: { get: (name) => (name.toLowerCase() === "content-type" ? "text/html; charset=utf-8" : null) },
      async text() { return "<!doctype html><html><body>Login</body></html>"; },
      async json() { return { memos: [] }; }
    })
  });
  assert.equal(htmlWithHeader.ok, false);
  assert.equal(htmlWithHeader.message, "服务返回的不是有效的 Memos 接口响应，请确认服务地址");

  const htmlWithoutHeader = await testMemosConnection({
    baseUrl: "https://memos.internal.test",
    token: "tok",
    locale: "en",
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() { throw new SyntaxError("Unexpected token '<'"); }
    })
  });
  assert.equal(htmlWithoutHeader.ok, false);
  assert.equal(
    htmlWithoutHeader.message,
    "Server did not return a valid Memos API response; verify the server URL"
  );

  for (const invalidPayload of [{ error: "unauthorized" }, { ok: true }, {}, [], "memos", null]) {
    const res = await testMemosConnection({
      baseUrl: "https://memos.internal.test",
      token: "tok",
      locale: "en",
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        async json() { return invalidPayload; }
      })
    });
    assert.equal(res.ok, false, `expected rejection for payload ${JSON.stringify(invalidPayload)}`);
  }
});

test("initOptionsPage handles dynamic token placeholders, blank save preservation, console button, and save-time auto-verify", async (t) => {
  const originalDocument = globalThis.document;
  const originalChrome = globalThis.chrome;
  const originalFetch = globalThis.fetch;
  const originalOpen = globalThis.open;
  t.after(() => {
    if (originalDocument === undefined) delete globalThis.document;
    else globalThis.document = originalDocument;
    if (originalChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = originalChrome;
    if (originalFetch === undefined) delete globalThis.fetch;
    else globalThis.fetch = originalFetch;
    if (originalOpen === undefined) delete globalThis.open;
    else globalThis.open = originalOpen;
  });

  const openedTabs = [];
  const fetchRequests = [];
  let nextFetchMode = "ok";

  const { parsed, persisted, sentRuntimeMessages } = createOptionsPageTestHarness({
    persistedInit: {
      memosUrl: "",
      memosToken: "",
      uiLanguage: "zh-CN",
      outbox: [{ clipId: "rw-pending-1" }]
    },
    uiLanguage: "zh-CN",
    tabsCreate: async (opts) => {
      openedTabs.push(opts);
    },
    fetchImpl: async (url, init) => {
      fetchRequests.push({ url, init });
      if (nextFetchMode === "html200") {
        return {
          ok: true,
          status: 200,
          headers: { get: () => "text/html" },
          async text() { return "<html><body>Portal</body></html>"; }
        };
      }
      if (nextFetchMode === "http401") {
        return { ok: false, status: 401 };
      }
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        async json() { return { memos: [] }; }
      };
    }
  });

  initOptionsPage();
  await new Promise((r) => setImmediate(r));

  const form = parsed.getElementById("settings-form");
  const urlInput = parsed.getElementById("memos-url");
  const tokenInput = parsed.getElementById("memos-token");
  const consoleBtn = parsed.getElementById("open-console-btn");
  const testBtn = parsed.getElementById("test-btn");
  const status = parsed.getElementById("status");

  assert.equal(tokenInput.value, "");
  assert.equal(tokenInput.placeholder, "请输入访问令牌");
  assert.equal(consoleBtn.disabled, true);

  urlInput.value = "ftp://memos.example.com";
  await urlInput.dispatch("input");
  assert.equal(consoleBtn.disabled, true);

  // Also check stripping via normalizeMemosBaseUrl for /api/v1/memos/ suffix
  urlInput.value = "https://memos.example.com/api/v1/memos/"; // checked via normalizeMemosBaseUrl
  await urlInput.dispatch("input");
  assert.equal(consoleBtn.disabled, false);

  await consoleBtn.dispatch("click");
  assert.deepEqual(openedTabs.at(-1), { url: "https://memos.example.com" });

  // Submit with valid URL and missing token skips network probe, sends flush, and does not claim connected
  urlInput.value = "https://memos.example.com/api/memos/";
  await urlInput.dispatch("input");
  await form.dispatch("submit");
  assert.equal(persisted.memosUrl, "https://memos.example.com");
  assert.equal(persisted.memosToken, "");
  assert.equal(fetchRequests.length, 0);
  assert.equal(sentRuntimeMessages.length, 1);
  assert.deepEqual(sentRuntimeMessages.at(-1), { type: "REWIND_FLUSH_OUTBOX" });
  assert.equal(status.textContent, "设置已保存。缺少访问令牌，尚未验证连接。");
  assert.equal(status.getAttribute("data-kind"), "info");
  assert.doesNotMatch(status.textContent, /已连接/);

  // Submit with new token saves, clears input, updates placeholder, flushes, and verifies connection
  tokenInput.value = "secret-tok-1";
  await form.dispatch("submit");
  assert.equal(persisted.memosToken, "secret-tok-1");
  assert.equal(tokenInput.value, "");
  assert.equal(tokenInput.placeholder, "已保存，留空则保留现有令牌");
  assert.equal(fetchRequests.length, 1);
  assert.equal(fetchRequests[0].url, "https://memos.example.com/api/memos?pageSize=1");
  assert.equal(fetchRequests[0].init.headers.Authorization, "Bearer secret-tok-1");
  assert.equal(status.textContent, "设置已保存，连接成功，可读取片段。");
  assert.equal(status.getAttribute("data-kind"), "ok");
  assert.equal(sentRuntimeMessages.length, 2);

  // Blank submit preserves existing token, flushes, and re-verifies with preserved token
  assert.equal(tokenInput.value, "");
  await form.dispatch("submit");
  assert.equal(persisted.memosToken, "secret-tok-1");
  assert.equal(fetchRequests.length, 2);
  assert.equal(fetchRequests[1].init.headers.Authorization, "Bearer secret-tok-1");
  assert.equal(sentRuntimeMessages.length, 3);

  // Manual Test Connection click with blank token uses savedToken
  await testBtn.dispatch("click");
  assert.equal(fetchRequests.length, 3);
  assert.equal(fetchRequests[2].init.headers.Authorization, "Bearer secret-tok-1");
  assert.equal(status.getAttribute("data-kind"), "ok");

  // HTML 200 failure on Save still dispatches idempotent outbox flush and reports inline error
  nextFetchMode = "html200";
  await form.dispatch("submit");
  assert.equal(fetchRequests.length, 4);
  assert.equal(status.getAttribute("data-kind"), "error");
  assert.match(status.textContent, /设置已保存，但连接验证失败/);
  assert.equal(sentRuntimeMessages.length, 4);

  // Clearing URL preserves savedToken, disables console button, and skips network probe and flush
  urlInput.value = "";
  await form.dispatch("submit");
  assert.equal(persisted.memosUrl, "");
  assert.equal(persisted.memosToken, "secret-tok-1");
  assert.equal(consoleBtn.disabled, true);
  assert.equal(fetchRequests.length, 4);
  assert.equal(sentRuntimeMessages.length, 4);
  assert.equal(status.textContent, "设置已保存。未填写服务地址，云端同步未启用。");
  assert.equal(status.getAttribute("data-kind"), "ok");

  // Fallback to globalThis.open when chrome.tabs is unavailable
  const fallbackOpened = [];
  globalThis.chrome.tabs = undefined;
  globalThis.open = (u, target, rel) => fallbackOpened.push({ u, target, rel });
  urlInput.value = "https://memos.example.com/notes/api/memos";
  await urlInput.dispatch("input");
  await consoleBtn.dispatch("click");
  assert.deepEqual(fallbackOpened, [
    { u: "https://memos.example.com/notes", target: "_blank", rel: "noopener,noreferrer" }
  ]);
});

test("extractChatSessionId and extractSessionOpening capture session provenance across >4-round AI chats", () => {
  assert.equal(extractChatSessionId("https://chatgpt.com/c/67f0a1b2-3344"), "67f0a1b2-3344");
  assert.equal(extractChatSessionId("https://chat.openai.com/g/g-swift-expert/c/gpt-sess-99?model=o3#bottom"), "gpt-sess-99");
  assert.equal(extractChatSessionId("https://chatgpt.com/g/g-swift-expert"), "");
  assert.equal(extractChatSessionId("https://claude.ai/chat/9b8c7d6e-1122-3344"), "9b8c7d6e-1122-3344");
  assert.equal(extractChatSessionId("https://claude.ai/new"), "");
  assert.equal(extractChatSessionId("https://gemini.google.com/app/4f5e6d7c"), "4f5e6d7c");
  assert.equal(extractChatSessionId("https://gemini.google.com/u/2/app/8a9b0c1d/"), "8a9b0c1d");
  assert.equal(extractChatSessionId("https://gemini.google.com/app"), "");
  assert.equal(extractChatSessionId("https://example.com/c/not-chatgpt"), "");
  assert.equal(extractChatSessionId("https://chatgpt.com/c/123", "claude"), "");

  assert.equal(
    extractSessionOpening([
      { role: "assistant", text: "Welcome banner" },
      { role: "user", text: "   " },
      { role: "user", text: `  ${"Design a non-activating NSPanel HUD. ".repeat(12)}  ` }
    ], 300).length,
    300
  );
  assert.equal(extractSessionOpening([{ role: "assistant", text: "Only assistant" }]), "");

  const openingGoal =
    "Build a zero-interruption macOS clip inspector that keeps the card list visible while inspecting long code excerpts and original session goals.";
  const url = "https://chatgpt.com/g/g-macos-appkit/c/sess-uuid-7788";
  const doc = parseHtmlDocument(
    `<html><head><title>Docked HUD Inspector - ChatGPT</title></head><body><main>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">${openingGoal}</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p>Round 1 answer</p></div></div>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Round 2 question</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p>Round 2 answer</p></div></div>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Round 3 question</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p>Round 3 answer</p></div></div>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Round 4 question</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p>Round 4 answer</p></div></div>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">Round 5 question</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p>Round 5 answer</p></div></div>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">How should Esc behave in Round 6?</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p id="r6-pick">Dismiss delete confirmation first, then close the inspector, then hide the panel.</p></div></div>
    </main></body></html>`,
    { url }
  );

  const clip = extractClipContext({
    doc,
    selectionRange: doc.createRangeFromNode(doc.querySelector("#r6-pick")),
    url
  });

  assert.equal(clip.sourcePlatform, "chatgpt");
  assert.equal(clip.sessionId, "sess-uuid-7788");
  assert.equal(clip.sessionOpening, openingGoal);
  assert.equal(clip.pageLead, "");
  assert.equal(clip.prompt, "How should Esc behave in Round 6?");
  assert.doesNotMatch(clip.recentTurns, /Round 1 answer/);
  assert.doesNotMatch(clip.recentTurns, /Round 2 answer/);
  assert.match(clip.recentTurns, /^User: Round 3 question/);

  const built = buildMemosWirePayloads(clip, {
    clipId: "rw-1794366666123-chatopen1",
    createdAt: "2026-11-16T10:00:00Z"
  });
  assert.equal(built.hasContext, true);
  assert.match(built.memoBody.content, /^#rewind\/pending #rewind\/has-ctx #source\/chatgpt\n\n/);
  assert.equal(
    built.commentBody.content,
    [
      "<!-- rewind-context-v1 -->",
      "Session Title: Docked HUD Inspector",
      "Session ID: sess-uuid-7788",
      "Prompt: How should Esc behave in Round 6?",
      "",
      "### Session Opening",
      openingGoal,
      "",
      "### Recent Turns",
      clip.recentTurns
    ].join("\n")
  );
});

test("extractPageLead composes distinct h1, preceding § section heading, meta description, and deduplicated prose blocks", () => {
  const url = "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html";
  const doc = parseHtmlDocument(
    `<html>
      <head>
        <title>Understanding Ownership - The Rust Book</title>
        <meta property="og:site_name" content="The Rust Book">
        <meta name="description" content="How Rust guarantees memory safety without garbage collection.">
      </head>
      <body>
        <header><h1>Rust Documentation Masthead</h1><nav><p>Navigation item</p></nav></header>
        <aside><p>Sidebar promo text</p></aside>
        <article>
          <h1>What Is Ownership?</h1>
          <p>How Rust guarantees memory safety without garbage collection.</p>
          <p>Ownership is a set of rules that govern how a Rust program manages memory.</p>
          <h2>The Stack and the Heap</h2>
          <p>Both the stack and the heap are parts of memory available to your code at runtime.</p>
          <h3>Ownership Rules</h3>
          <ul>
            <li>Each value in Rust has an owner.</li>
            <li id="selected-rule">There can only be one owner at a time.</li>
          </ul>
          <h2>Memory and Allocation</h2>
          <p>Later section below the selection must not become the preceding heading.</p>
        </article>
        <footer><p>Footer copyright</p></footer>
        <div data-coding-rewind-ui="1"><p>Stash pill overlay</p></div>
      </body>
    </html>`,
    { url }
  );

  const sessionTitle = extractSessionTitle(doc, url, "web");
  assert.equal(sessionTitle, "Understanding Ownership");

  const range = doc.createRangeFromNode(doc.querySelector("#selected-rule"));
  const lead = extractPageLead(doc, range, sessionTitle, 300);

  assert.ok(lead.length <= 300);
  const lines = lead.split("\n");
  assert.equal(lines[0], "What Is Ownership?");
  assert.equal(lines[1], "§ Ownership Rules");
  assert.equal(lines[2], "How Rust guarantees memory safety without garbage collection.");
  assert.equal(lines[3], "Ownership is a set of rules that govern how a Rust program manages memory.");
  assert.equal(
    lead.split("How Rust guarantees memory safety without garbage collection.").length - 1,
    1,
    "prose block identical to meta description is deduplicated"
  );
  assert.doesNotMatch(lead, /Masthead|Navigation item|Sidebar promo|Footer copyright|Stash pill|Memory and Allocation/);

  const sameH1Doc = parseHtmlDocument(
    `<html><head><title>Exact Same Title</title></head><body><main>
      <h1>Exact Same Title</h1>
      <blockquote>Quoted opening insight for readers.</blockquote>
    </main></body></html>`,
    { url: "https://example.com/same-h1" }
  );
  const sameH1Lead = extractPageLead(sameH1Doc, null, "Exact Same Title", 300);
  assert.equal(sameH1Lead, "Quoted opening insight for readers.");
});

test("buildTextFragmentUrl encodes W3C short, >120-char, and multi-block selections, preserves #hash, and stays idempotent", () => {
  const doc = parseHtmlDocument(
    `<html><body>
      <div data-coding-rewind-ui="1">Overlay noise before</div>
      <article>
        <p id="p-short">Introductory clause with enough words before target: <span id="short-sel">borrow-checking &amp; lifetimes (v1, v2)</span> prevent use-after-free bugs in safe systems code today.</p>
        <p id="p-long">Context lead-in words here. <span id="long-sel">Ownership is a compile-time set of rules that govern how a Rust program allocates and frees memory across stack frames and heap buffers without needing a tracing garbage collector.</span> Trailing words after long selection.</p>
        <div id="multi-sel">
          <p>First paragraph starts the multi-block selection cleanly with extra words so start snapping engages properly.</p>
          <p>Second paragraph concludes the multi-block selection cleanly with extra words at the tail end.</p>
        </div>
      </article>
      <div data-coding-rewind-ui="1">Overlay noise after</div>
    </body></html>`,
    { url: "https://example.com/spec" }
  );

  const shortRange = doc.createRangeFromNode(doc.querySelector("#short-sel"));
  const shortUrl = buildTextFragmentUrl("https://example.com/spec", shortRange, doc);
  assert.match(shortUrl, /^https:\/\/example\.com\/spec#:~:text=/);
  const shortDirective = shortUrl.split("#:~:text=")[1];
  assert.match(
    shortDirective,
    /^[^,]+-,borrow%2Dchecking%20%26%20lifetimes%20%28v1%2C%20v2%29,-[^,]+$/
  );
  assert.doesNotMatch(shortUrl, /Overlay%20noise/);

  const withHash = buildTextFragmentUrl("https://example.com/spec#memory-model", shortRange, doc);
  assert.equal(withHash, `https://example.com/spec#memory-model:~:text=${shortDirective}`);

  const reclippedSame = buildTextFragmentUrl(withHash, shortRange, doc);
  assert.equal(reclippedSame, withHash);

  const longRange = doc.createRangeFromNode(doc.querySelector("#long-sel"));
  const reclippedNew = buildTextFragmentUrl(withHash, longRange, doc);
  assert.match(reclippedNew, /^https:\/\/example\.com\/spec#memory-model:~:text=/);
  assert.doesNotMatch(reclippedNew, /borrow%2Dchecking/);
  const longDirective = reclippedNew.split(":~:text=")[1];
  const longParts = longDirective.split(",");
  assert.equal(longParts.length, 4, "expected prefix-, textStart, textEnd, -suffix");
  assert.ok(longParts[0].endsWith("-"));
  assert.ok(longParts[3].startsWith("-"));
  const decodedStart = decodeURIComponent(longParts[1]);
  const decodedEnd = decodeURIComponent(longParts[2]);
  assert.ok(decodedStart.length >= 40 && decodedStart.length <= 55, `textStart length ${decodedStart.length}`);
  assert.ok(decodedEnd.length >= 40 && decodedEnd.length <= 55, `textEnd length ${decodedEnd.length}`);
  assert.ok(decodedStart.startsWith("Ownership is a compile-time"));
  assert.ok(decodedEnd.endsWith("tracing garbage collector."));

  const reclippedPlainFragment = buildTextFragmentUrl(shortUrl, longRange, doc);
  assert.equal(reclippedPlainFragment, `https://example.com/spec#:~:text=${longDirective}`);

  const multiRange = doc.createRangeFromNode(doc.querySelector("#multi-sel"));
  const multiUrl = buildTextFragmentUrl("https://example.com/spec", multiRange, doc);
  const multiParts = multiUrl.split("#:~:text=")[1].split(",");
  assert.equal(multiParts.length, 2);
  assert.ok(decodeURIComponent(multiParts[0]).startsWith("First paragraph starts"));
  assert.ok(decodeURIComponent(multiParts[1]).endsWith("words at the tail end."));

  assert.equal(buildTextFragmentUrl("file:///Users/demo/notes.html", shortRange, doc), "file:///Users/demo/notes.html");
  assert.equal(buildTextFragmentUrl("https://example.com/spec#", null, doc), "https://example.com/spec#");
  const collapsedRange = {
    startContainer: doc.querySelector("#short-sel").childNodes[0],
    startOffset: 3,
    endContainer: doc.querySelector("#short-sel").childNodes[0],
    endOffset: 3
  };
  assert.equal(
    buildTextFragmentUrl("https://example.com/spec#broken-empty", collapsedRange, doc),
    "https://example.com/spec#broken-empty"
  );
});

test("prototype-less NodeList web clip populates pageLead, W3C text fragment URL, #rewind/has-ctx, and Page Lead comment", () => {
  function toNullProtoNodeList(node) {
    if (!node || typeof node !== "object") return node;
    const kids = Array.from(node.childNodes || []);
    for (const k of kids) toNullProtoNodeList(k);
    const list = Object.create(null);
    list.length = kids.length;
    kids.forEach((k, i) => {
      list[i] = k;
    });
    node.childNodes = Object.freeze(list);
    const origClone = typeof node.cloneNode === "function" ? node.cloneNode.bind(node) : null;
    if (origClone) {
      node.cloneNode = (deep = false) => toNullProtoNodeList(origClone(deep));
    }
    return node;
  }

  const baseUrl = "https://blog.example.org/systems/zero-copy#intro";
  const doc = parseHtmlDocument(
    `<html>
      <head>
        <title>Zero-Copy Framing | Example Systems Blog</title>
        <meta property="og:site_name" content="Example Systems Blog">
        <meta property="og:description" content="Designing zero-copy ring buffers for framed IPC.">
      </head>
      <body>
        <article>
          <h1>Zero-Copy Ring Buffers</h1>
          <h2> Scatter-Gather Descriptors </h2>
          <p>Ring buffers avoid per-message heap allocations: <span id="pick">use mmap(2) &amp; writev(2)</span> for framed batches.</p>
        </article>
      </body>
    </html>`,
    { url: baseUrl }
  );

  const pickEl = doc.querySelector("#pick");
  const rawRange = doc.createRangeFromNode(pickEl);
  const cloned = toNullProtoNodeList(rawRange.cloneContents());
  toNullProtoNodeList(doc);

  const range = {
    ...rawRange,
    cloneContents() {
      return cloned;
    }
  };

  const clip = extractClipContext({ doc, selectionRange: range, url: baseUrl });
  assert.equal(clip.sourcePlatform, "web");
  assert.equal(clip.sessionTitle, "Zero-Copy Framing");
  assert.equal(clip.sessionId, "");
  assert.equal(clip.sessionOpening, "");
  assert.match(clip.pageLead, /^Zero-Copy Ring Buffers\n§ Scatter-Gather Descriptors\nDesigning zero-copy ring buffers for framed IPC\./);
  assert.match(
    clip.sourceUrl,
    /^https:\/\/blog\.example\.org\/systems\/zero-copy#intro:~:text=.*use%20mmap%282%29%20%26%20writev%282%29.*$/
  );

  assert.equal(hasClipContext(clip), true);
  const wire = buildMemosWirePayloads(clip, {
    clipId: "rw-1794366666123-webctx01",
    createdAt: "2026-11-16T11:00:00Z"
  });
  assert.equal(wire.hasContext, true);
  assert.equal(
    wire.memoBody.content,
    `#rewind/pending #rewind/has-ctx #source/web\n\n` +
      `> **Source:** [Zero-Copy Framing](${clip.sourceUrl}) · 2026-11-16T11:00:00Z\n\n` +
      `use mmap(2) & writev(2)`
  );
  assert.equal(
    wire.commentBody.content,
    `<!-- rewind-context-v1 -->\nSession Title: Zero-Copy Framing\n\n### Page Lead\n${clip.pageLead}`
  );
  assert.doesNotMatch(wire.commentBody.content, /### Session Opening/);

  const textNodeDoc = parseHtmlDocument(`<article><p id="p">Prefix words before target, item#1, item#2, and trailing words after.</p></article>`, {
    url: "https://example.org/hash-comma"
  });
  const pText = textNodeDoc.querySelector("#p").childNodes[0];
  const subStart = pText.nodeValue.indexOf("item#1, item#2");
  const subRange = {
    startContainer: pText,
    startOffset: subStart,
    endContainer: pText,
    endOffset: subStart + "item#1, item#2".length,
    commonAncestorContainer: pText
  };
  const subUrl = buildTextFragmentUrl("https://example.org/hash-comma", subRange, textNodeDoc);
  assert.match(subUrl, /-,item%231%2C%20item%232,-/);

  const mutualWeb = buildMemosWirePayloads(
    {
      selectedMarkdown: "Body",
      sourcePlatform: "web",
      sessionTitle: "Article",
      sessionOpening: "Should be suppressed on web when pageLead exists",
      pageLead: "Authoritative web page lead"
    },
    { clipId: "rw-1794366666123-mutual01", createdAt: "2026-11-16T11:05:00Z" }
  );
  assert.match(mutualWeb.commentBody.content, /### Page Lead\nAuthoritative web page lead$/);
  assert.doesNotMatch(mutualWeb.commentBody.content, /### Session Opening/);
});

function hasBalancedCommonMarkFences(markdown) {
  let active = null;
  for (const line of String(markdown || "").replace(/\r\n?/g, "\n").split("\n")) {
    const match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (!match) continue;
    const ch = match[1][0];
    const len = match[1].length;
    const rest = match[2];
    if (!active) {
      if (ch === "`" && rest.includes("`")) continue;
      active = { ch, len };
    } else if (ch === active.ch && len >= active.len && /^[ \t]*$/.test(rest)) {
      active = null;
    }
  }
  return active === null;
}

test("truncated openings, prompts, turns, and wire payloads always close unbalanced CommonMark code fences", () => {
  assert.equal(closeUnbalancedCodeFence("   ```ts\nconst x = 1;"), "   ```ts\nconst x = 1;\n```");
  assert.equal(closeUnbalancedCodeFence("    ```ts\nconst x = 1;"), "    ```ts\nconst x = 1;");
  assert.equal(closeUnbalancedCodeFence("```inline`ticks```"), "```inline`ticks```");
  assert.equal(
    closeUnbalancedCodeFence("````md\n```js\nx()\n```"),
    "````md\n```js\nx()\n```\n````"
  );

  const longCodeOpening = `Review this worker:\n\`\`\`python\n${"def handle_batch(items):\n    return len(items)\n".repeat(12)}\`\`\``;
  const opening = extractSessionOpening([{ role: "user", text: longCodeOpening }], 300);
  assert.ok(opening.length <= 300, `opening length ${opening.length} must stay <= 300`);
  assert.equal(hasBalancedCommonMarkFences(opening), true);
  assert.match(opening, /\n```$/);

  const longTildeOpening = `Shell trace:\n~~~~bash\n${"printf '%s\\n' \"$item\"\n".repeat(20)}~~~~`;
  const tildeOpening = extractSessionOpening([{ role: "user", text: longTildeOpening }], 300);
  assert.ok(tildeOpening.length <= 300);
  assert.equal(hasBalancedCommonMarkFences(tildeOpening), true);
  assert.match(tildeOpening, /\n~~~~$/);

  const turnCode = `Here is the implementation:\n\`\`\`swift\n${"let state = ActorState(counter: 1)\n".repeat(40)}\`\`\``;
  const recent = formatRecentTurns(
    [
      { role: "user", text: turnCode },
      { role: "assistant", text: turnCode },
      { role: "user", text: "Unclosed user fence:\n```ts\nconst pending = true;" },
      { role: "assistant", text: turnCode }
    ],
    4000
  );
  assert.ok(recent.length <= 4000, `recentTurns length ${recent.length} must stay <= 4000`);
  for (const chunk of recent.split(/\n\n(?=(?:User|Assistant): )/)) {
    const body = chunk.replace(/^(?:User|Assistant): /, "");
    assert.equal(hasBalancedCommonMarkFences(body), true, `turn must have balanced fences: ${body.slice(-30)}`);
  }

  const longPromptHtml = `<p>Explain every line:</p><pre><code class="language-rust">${"let value = compute_next_frame_offset(index);\n".repeat(45)}</code></pre>`;
  const chatUrl = "https://chatgpt.com/c/fence-truncation";
  const chatDoc = parseHtmlDocument(
    `<html><body><main>
      <div data-message-author-role="user"><div class="whitespace-pre-wrap">${longPromptHtml}</div></div>
      <div data-message-author-role="assistant"><div class="markdown"><p id="ans">Summary reply.</p></div></div>
    </main></body></html>`,
    { url: chatUrl }
  );
  const clip = extractClipContext({
    doc: chatDoc,
    selectionRange: chatDoc.createRangeFromNode(chatDoc.querySelector("#ans")),
    url: chatUrl
  });
  assert.ok(clip.prompt.length <= 1500);
  assert.equal(hasBalancedCommonMarkFences(clip.prompt), true);
  assert.equal(hasBalancedCommonMarkFences(clip.sessionOpening), true);

  const leadDoc = parseHtmlDocument(
    `<html><head><title>Fence Lead</title></head><body><article>
      <p>\`\`\`ts</p>
      <p>${"Type-safe boundary validation keeps wire parsers resilient across partial truncations. ".repeat(6)}</p>
    </article></body></html>`,
    { url: "https://example.com/fence-lead" }
  );
  const lead = extractPageLead(leadDoc, null, "Fence Lead", 300);
  assert.ok(lead.length <= 300);
  assert.equal(hasBalancedCommonMarkFences(lead), true);

  const defensiveChat = buildMemosWirePayloads(
    {
      selectedMarkdown: "Selected snippet",
      sourcePlatform: "claude",
      sessionTitle: "Defensive Fence",
      sessionId: "sess-1",
      prompt: "Check:\n```python\nx = 1",
      sessionOpening: "Start:\n~~~sh\necho 1",
      recentTurns: "User: Follow-up\n\nAssistant: Selected snippet"
    },
    { clipId: "rw-1794366666123-deffence1", createdAt: "2026-11-16T12:00:00Z" }
  );
  assert.equal(hasBalancedCommonMarkFences(defensiveChat.commentBody.content), true);
  assert.match(
    defensiveChat.commentBody.content,
    /Prompt: Check:\n```python\nx = 1\n```\n\n### Session Opening\nStart:\n~~~sh\necho 1\n~~~\n\n### Recent Turns\nUser: Follow-up/
  );

  const defensiveWeb = buildMemosWirePayloads(
    {
      selectedMarkdown: "Selected web text",
      sourcePlatform: "web",
      sessionTitle: "Web Fence",
      pageLead: "```yaml\nmode: strict"
    },
    { clipId: "rw-1794366666123-deffence2", createdAt: "2026-11-16T12:01:00Z" }
  );
  assert.equal(hasBalancedCommonMarkFences(defensiveWeb.commentBody.content), true);
  assert.match(defensiveWeb.commentBody.content, /### Page Lead\n```yaml\nmode: strict\n```$/);
});

test("buildMemosWirePayloads isolates platform leads strictly and escapes backslashes in Source link labels", () => {
  for (const chatPlatform of ["chatgpt", "claude", "gemini"]) {
    const leakedLeadClip = {
      selectedMarkdown: "Chat excerpt",
      sourcePlatform: chatPlatform,
      sessionTitle: "Chat Thread",
      sessionOpening: "",
      pageLead: "Leaked web page lead that must never appear on chat platforms"
    };
    assert.equal(hasClipContext(leakedLeadClip), false);
    const built = buildMemosWirePayloads(leakedLeadClip, {
      clipId: `rw-1794366666123-iso-${chatPlatform.slice(0, 4)}`,
      createdAt: "2026-11-16T12:10:00Z"
    });
    assert.equal(built.hasContext, false);
    assert.equal(built.commentBody, null);
    assert.doesNotMatch(built.memoBody.content, /#rewind\/has-ctx/);
  }

  const leakedOpeningWebClip = {
    selectedMarkdown: "Web excerpt",
    sourcePlatform: "web",
    sessionTitle: "Docs Article",
    sessionOpening: "Leaked chat session opening that must never appear on web",
    pageLead: ""
  };
  assert.equal(hasClipContext(leakedOpeningWebClip), false);
  const builtWeb = buildMemosWirePayloads(leakedOpeningWebClip, {
    clipId: "rw-1794366666123-iso-web1",
    createdAt: "2026-11-16T12:11:00Z"
  });
  assert.equal(builtWeb.hasContext, false);
  assert.equal(builtWeb.commentBody, null);
  assert.doesNotMatch(builtWeb.memoBody.content, /#rewind\/has-ctx/);

  function parseWireSourceLine(memoContent) {
    const line = memoContent.split("\n").find((l) => l.startsWith("> **Source:** "));
    assert.ok(line, "missing Source line");
    const rest = line.slice("> **Source:** ".length);
    assert.equal(rest[0], "[");
    let idx = 1;
    let closeBracket = -1;
    while (idx < rest.length) {
      if (rest[idx] === "\\") {
        idx += 2;
        continue;
      }
      if (rest[idx] === "]" && rest[idx + 1] === "(") {
        closeBracket = idx;
        break;
      }
      idx += 1;
    }
    assert.notEqual(closeBracket, -1, `unparseable Markdown link in ${line}`);
    const rawLabel = rest.slice(1, closeBracket);
    const closeParen = rest.indexOf(")", closeBracket + 2);
    assert.notEqual(closeParen, -1);
    const title = rawLabel
      .replace(/\\\[/g, "[")
      .replace(/\\\]/g, "]")
      .replace(/\\\\/g, "\\");
    const url = rest.slice(closeBracket + 2, closeParen);
    return { title, url };
  }

  for (const trickyTitle of [
    "C:\\Users\\dev\\",
    "Spoof \\](https://evil.example/path) [v2]\\",
    "\\\\server\\share\\[docs]"
  ]) {
    const builtLink = buildMemosWirePayloads(
      {
        selectedMarkdown: "Snippet",
        sourcePlatform: "web",
        sessionTitle: trickyTitle,
        sourceUrl: "https://trusted.example.org/docs"
      },
      { clipId: "rw-1794366666123-bslash01", createdAt: "2026-11-16T12:12:00Z" }
    );
    const parsed = parseWireSourceLine(builtLink.memoBody.content);
    assert.equal(parsed.title, trickyTitle);
    assert.equal(parsed.url, "https://trusted.example.org/docs");
  }
});

test("extractChatSessionId and extractClipContext support Claude project chat URLs", () => {
  assert.equal(
    extractChatSessionId("https://claude.ai/project/0196abc-proj/chat/9b8c7d6e-1122-3344"),
    "9b8c7d6e-1122-3344"
  );
  assert.equal(
    extractChatSessionId("https://claude.ai/project/0196abc-proj/chat/9b8c7d6e-1122-3344/?q=1#top"),
    "9b8c7d6e-1122-3344"
  );
  assert.equal(extractChatSessionId("https://claude.ai/project/0196abc-proj"), "");
  assert.equal(extractChatSessionId("https://claude.ai/project/0196abc-proj/chat/"), "");

  const projectChatUrl = "https://claude.ai/project/proj-uuid-42/chat/chat-uuid-99";
  const doc = parseHtmlDocument(
    `<html><head><title>Project Architecture - Claude</title></head><body>
      <div data-testid="user-message"><p>Summarize the storage schema.</p></div>
      <div data-testid="assistant-message"><p id="proj-ans">Use append-only WAL segments.</p></div>
    </body></html>`,
    { url: projectChatUrl }
  );
  const clip = extractClipContext({
    doc,
    selectionRange: doc.createRangeFromNode(doc.querySelector("#proj-ans")),
    url: projectChatUrl
  });
  assert.equal(clip.sourcePlatform, "claude");
  assert.equal(clip.sessionId, "chat-uuid-99");
  assert.equal(clip.sessionOpening, "Summarize the storage schema.");
});

test("buildTextFragmentUrl separates code-line spans without fusing and snaps long URLs and identifiers on word boundaries", () => {
  const shikiDoc = parseHtmlDocument(
    `<html><body><article>
      <pre class="shiki"><code id="code-sel"><span class="line"><span>let x = 1</span></span><span class="line"><span>return x</span></span></code></pre>
      <div class="cm-content" id="cm-sel"><div class="cm-line">const a = 2</div><div class="cm-line">export default a</div></div>
    </article></body></html>`,
    { url: "https://example.com/code" }
  );
  const codeUrl = buildTextFragmentUrl(
    "https://example.com/code",
    shikiDoc.createRangeFromNode(shikiDoc.querySelector("#code-sel")),
    shikiDoc
  );
  assert.doesNotMatch(codeUrl, /1return/);
  assert.equal(codeUrl, "https://example.com/code#:~:text=let%20x%20%3D%201,return%20x");

  const cmUrl = buildTextFragmentUrl(
    "https://example.com/code",
    shikiDoc.createRangeFromNode(shikiDoc.querySelector("#cm-sel")),
    shikiDoc
  );
  assert.equal(cmUrl, "https://example.com/code#:~:text=const%20a%20%3D%202,export%20default%20a");

  const longApiUrl =
    "https://api.internal.example.com/v1/organizations/primary_tenant_workspace/settings/audit_logs/export?format=parquet&compression=zstd&limit=500";
  const urlDoc = parseHtmlDocument(
    `<html><body><article>
      <p><span id="url-sel">${longApiUrl}</span></p>
      <p><span id="ident-sel">super_long_identifier_name_that_exceeds_fifty_five_characters_without_any_punctuation_at_all is returned here and followed by another_extremely_long_identifier_name_at_the_tail_end_of_selection</span></p>
      <p><span id="blob-sel">${"a".repeat(200)}</span></p>
    </article></body></html>`,
    { url: "https://docs.example.com/api" }
  );

  const builtUrlFrag = buildTextFragmentUrl(
    "https://docs.example.com/api",
    urlDoc.createRangeFromNode(urlDoc.querySelector("#url-sel")),
    urlDoc
  );
  const [rawUrlStart, rawUrlEnd] = builtUrlFrag.split("#:~:text=")[1].split(",");
  const decodedUrlStart = decodeURIComponent(rawUrlStart);
  const decodedUrlEnd = decodeURIComponent(rawUrlEnd);
  assert.equal(decodedUrlStart, "https://api.internal.example.com/v1/organizations");
  assert.equal(decodedUrlEnd, "export?format=parquet&compression=zstd&limit=500");

  const builtIdentFrag = buildTextFragmentUrl(
    "https://docs.example.com/api",
    urlDoc.createRangeFromNode(urlDoc.querySelector("#ident-sel")),
    urlDoc
  );
  const [rawIdentStart, rawIdentEnd] = builtIdentFrag.split("#:~:text=")[1].split(",");
  assert.equal(
    decodeURIComponent(rawIdentStart),
    "super_long_identifier_name_that_exceeds_fifty_five_characters_without_any_punctuation_at_all"
  );
  assert.equal(
    decodeURIComponent(rawIdentEnd),
    "another_extremely_long_identifier_name_at_the_tail_end_of_selection"
  );

  const builtBlobFrag = buildTextFragmentUrl(
    "https://docs.example.com/api",
    urlDoc.createRangeFromNode(urlDoc.querySelector("#blob-sel")),
    urlDoc
  );
  assert.equal(builtBlobFrag, "https://docs.example.com/api");
});

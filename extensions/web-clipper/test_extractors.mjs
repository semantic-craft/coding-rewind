// SPDX-License-Identifier: MIT

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  detectPlatform,
  cleanSessionTitle,
  htmlToMarkdown,
  selectionToMarkdown,
  extractSessionTitle,
  extractConversationTurns,
  extractClipContext,
  parseHtmlDocument
} from "./extractors.mjs";

import {
  CLIP_ID_PATTERN,
  MAX_OUTBOX_ITEMS,
  TOAST_MESSAGES,
  generateClipId,
  normalizeMemosBaseUrl,
  buildMemosWirePayloads,
  parseServerMemoId,
  saveClipWithOutbox,
  flushOutbox
} from "./memos_payload.mjs";

import { testMemosConnection } from "./options.js";

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

test("selectionToMarkdown preserves ancestor fenced code block language on partial code selection", () => {
  const doc = parseHtmlDocument(
    `<pre><code class="language-swift"><span id="sel">let panel = NSPanel()</span>\npanel.isFloatingPanel = true</code></pre>`
  );
  const span = doc.querySelector("#sel");
  const range = doc.createRangeFromNode(span);
  const md = selectionToMarkdown(range, "https://chatgpt.com/c/1");
  assert.equal(md, "```swift\nlet panel = NSPanel()\n```");

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
  assert.equal(selectionToMarkdown(plainOnlySelection), "fallback plain text");
});

test("ChatGPT DOM extraction captures title, nearest preceding prompt, and up to 4 turns up to selection", () => {
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
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">How do I keep NSPanel from stealing focus?</div></div>
          <div data-message-author-role="assistant">
            <div class="markdown">
              <p>Use <code>.nonactivatingPanel</code> in your style mask:</p>
              <div id="picked">
                <pre><code class="language-swift">panel.styleMask.insert(.nonactivatingPanel)</code></pre>
              </div>
            </div>
          </div>
          <div data-message-author-role="user"><div class="whitespace-pre-wrap">Turn 4 later follow-up below selection</div></div>
          <div data-message-author-role="assistant"><div class="markdown"><p>Turn 4 later answer below selection</p></div></div>
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

  const turnBlocks = ctx.recentTurns.split(/\n\n(?=(?:User|Assistant): )/);
  assert.equal(turnBlocks.length, 4);
  assert.match(turnBlocks[0], /^User: Turn 2 user question$/);
  assert.match(turnBlocks[1], /^Assistant: Turn 2 assistant reply$/);
  assert.match(turnBlocks[2], /^User: How do I keep NSPanel from stealing focus\?$/);
  assert.match(turnBlocks[3], /^Assistant: Use `\.nonactivatingPanel` in your style mask:/);
  assert.doesNotMatch(ctx.recentTurns, /later follow-up below selection/);
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
            <p>Pass a deterministic <code>memoId</code> query parameter to <code>POST /api/v1/memos</code>.</p>
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
    "Pass a deterministic `memoId` query parameter to `POST /api/v1/memos`."
  );
  assert.match(ctx.recentTurns, /^User: How do we make MV3 retries idempotent against Memos\?\n\nAssistant: Pass a deterministic `memoId`/);
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
  assert.equal(withCtx.memoPath, `/api/v1/memos?memoId=${clipId}`);
  assert.deepEqual(withCtx.memoBody, {
    content:
      "#rewind/pending #rewind/has-ctx #source/chatgpt\n\n" +
      "> **Source:** [Swift Snippet](https://chatgpt.com/c/123) · 2026-11-11T03:15:00Z\n\n" +
      "```swift\nlet ok = true\n```",
    visibility: "PRIVATE"
  });
  assert.equal(withCtx.commentPathForServerId("9876"), `/api/v1/memos/9876/comments?commentId=${clipId}-ctx`);
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
    { clipId: "rw-1794366666123-plain001", createdAt: "2026-11-11T03:16:00Z" }
  );

  assert.equal(withoutCtx.hasContext, false);
  assert.equal(withoutCtx.commentBody, null);
  assert.doesNotMatch(withoutCtx.memoBody.content, /#rewind\/has-ctx/);
  assert.match(withoutCtx.memoBody.content, /^#rewind\/pending #source\/web\n\n> \*\*Source:\*\* \[web\]\(https:\/\/example\.org\/notes\) · 2026-11-11T03:16:00Z\n\nStandalone paragraph$/);
  assert.equal(parseServerMemoId({ name: "memos/abc999" }), "abc999");
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
  assert.equal(unconfiguredRes.toast, TOAST_MESSAGES.UNCONFIGURED);
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
  assert.equal(offlineRes.toast, TOAST_MESSAGES.QUEUED);
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
    (c) => c.url === `https://memos.internal.test/api/v1/memos?memoId=${encodeURIComponent(firstClipId)}`
  );
  assert.equal(retriedFirstMemoCall.length, 2);
  assert.equal(retriedFirstMemoCall[1].headers.Authorization, "Bearer test-token");

  const retriedFirstCommentCall = calls.find(
    (c) => c.url === `https://memos.internal.test/api/v1/memos/srv-${firstClipId}/comments?commentId=${encodeURIComponent(`${firstClipId}-ctx`)}`
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

test("options testMemosConnection calls GET /api/v1/memos?pageSize=1 and manifest.json is valid MV3", async () => {
  let seenUrl = "";
  let seenAuth = "";
  const conn = await testMemosConnection({
    baseUrl: "https://memos.internal.test/",
    token: "tok-abc",
    fetchImpl: async (url, init) => {
      seenUrl = url;
      seenAuth = init.headers.Authorization;
      return { ok: true, status: 200, async json() { return { memos: [] }; } };
    }
  });
  assert.equal(conn.ok, true);
  assert.equal(seenUrl, "https://memos.internal.test/api/v1/memos?pageSize=1");
  assert.equal(seenAuth, "Bearer tok-abc");

  assert.equal(normalizeMemosBaseUrl("https://memos.internal.test/api/v1/memos/"), "https://memos.internal.test");

  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  for (const perm of ["storage", "contextMenus", "activeTab", "scripting"]) {
    assert.ok(manifest.permissions.includes(perm), `missing permission ${perm}`);
  }
  for (const host of ["https://chatgpt.com/*", "https://claude.ai/*", "https://gemini.google.com/*"]) {
    assert.ok(manifest.host_permissions.includes(host), `missing host permission ${host}`);
  }
});

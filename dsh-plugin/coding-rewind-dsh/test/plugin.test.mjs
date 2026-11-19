// SPDX-License-Identifier: MIT

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

import {
  APPLE_EPOCH_OFFSET_SEC,
  DshPrivateStore,
  MAX_FILE_BYTES,
  MAX_PROMPT_BYTES,
  appleSecToUnixMs,
  extractSessionMessages,
  readPrivateJsonFile,
  resolveDataDir,
  unixMsToAppleSec,
  writePrivateJsonAtomic,
} from "../lib/handoff.js";
import * as hostPlugin from "../lib/index.js";

const PLUGIN_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLIENT_SOURCE = fs.readFileSync(path.join(PLUGIN_DIR, "client.js"), "utf8");

function makeTempDir(prefix = "coding-rewind-dsh-test-") {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function makeFakeNodeList(items) {
  const list = { length: items.length };
  for (let i = 0; i < items.length; i += 1) {
    list[i] = items[i];
  }
  list[Symbol.iterator] = function* () {
    for (let i = 0; i < items.length; i += 1) {
      yield items[i];
    }
  };
  return list;
}

class FakeNode {
  constructor(nodeType, ownerDocument) {
    this.nodeType = nodeType;
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.parentElement = null;
    this._children = [];
  }

  get childNodes() {
    return makeFakeNodeList(this._children);
  }

  appendChild(child) {
    if (child.parentNode && child.parentNode._children) {
      const idx = child.parentNode._children.indexOf(child);
      if (idx >= 0) child.parentNode._children.splice(idx, 1);
    }
    child.parentNode = this;
    child.parentElement = this.nodeType === 1 ? this : null;
    this._children.push(child);
    return child;
  }

  append(...nodes) {
    for (const n of nodes) this.appendChild(n);
  }

  remove() {
    if (this.parentNode && this.parentNode._children) {
      const idx = this.parentNode._children.indexOf(this);
      if (idx >= 0) this.parentNode._children.splice(idx, 1);
    }
    this.parentNode = null;
    this.parentElement = null;
    this.isConnected = false;
  }

  get textContent() {
    if (this.nodeType === 3) return this.nodeValue || "";
    return this._children.map((c) => c.textContent).join("");
  }

  set textContent(value) {
    if (this.nodeType === 3) {
      this.nodeValue = String(value);
      return;
    }
    this._children = [];
    if (value !== "" && value !== null && value !== undefined) {
      this.appendChild(new FakeText(String(value), this.ownerDocument));
    }
  }

  cloneNode(deep = false) {
    if (this.nodeType === 3) {
      return new FakeText(this.nodeValue, this.ownerDocument);
    }
    if (this.nodeType === 11) {
      const frag = new FakeFragment(this.ownerDocument);
      if (deep) {
        for (const c of this._children) frag.appendChild(c.cloneNode(true));
      }
      return frag;
    }
    const copy = new FakeElement(this.tagName, this.ownerDocument);
    copy.attributes = { ...this.attributes };
    copy.className = this.className;
    if (deep) {
      for (const c of this._children) copy.appendChild(c.cloneNode(true));
    }
    return copy;
  }
}

class FakeText extends FakeNode {
  constructor(value, ownerDocument) {
    super(3, ownerDocument);
    this.nodeValue = String(value);
  }
}

class FakeFragment extends FakeNode {
  constructor(ownerDocument) {
    super(11, ownerDocument);
  }
}

class FakeElement extends FakeNode {
  constructor(tagName, ownerDocument) {
    super(1, ownerDocument);
    this.tagName = String(tagName).toUpperCase();
    this.nodeName = this.tagName;
    this.attributes = {};
    this.className = "";
    this.style = {};
    this.hidden = false;
    this.isConnected = true;
    this.offsetWidth = 68;
    this.offsetHeight = 26;
    this._listeners = new Map();
    this._closedShadowRoot = null;
    this._rect = null;
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === "class") this.className = String(value);
    if (name === "lang") this.lang = String(value);
  }

  getAttribute(name) {
    if (name === "class" && this.className && !(name in this.attributes)) return this.className;
    return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
  }

  hasAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name);
  }

  removeAttribute(name) {
    delete this.attributes[name];
  }

  attachShadow(init) {
    const root = new FakeFragment(this.ownerDocument);
    root.mode = init?.mode || "open";
    root.host = this;
    this._closedShadowRoot = root;
    if (root.mode === "open") {
      this.shadowRoot = root;
    } else {
      this.shadowRoot = null;
    }
    return root;
  }

  getBoundingClientRect() {
    return this._rect || { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 };
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  querySelectorAll(selector) {
    const out = [];
    const selectors = selector.split(",").map((s) => s.trim());
    const visit = (node) => {
      for (const child of node._children) {
        if (child.nodeType === 1) {
          if (selectors.some((sel) => matchesSimpleSelector(child, sel))) {
            out.push(child);
          }
          visit(child);
        }
      }
    };
    visit(this);
    return makeFakeNodeList(out);
  }

  addEventListener(type, fn, capture = false) {
    const key = `${type}:${Boolean(capture)}`;
    const list = this._listeners.get(key) || [];
    list.push(fn);
    this._listeners.set(key, list);
  }

  removeEventListener(type, fn, capture = false) {
    const key = `${type}:${Boolean(capture)}`;
    const list = this._listeners.get(key);
    if (!list) return;
    const idx = list.indexOf(fn);
    if (idx >= 0) list.splice(idx, 1);
  }

  dispatchDirect(type, event, capture = false) {
    const key = `${type}:${Boolean(capture)}`;
    const list = (this._listeners.get(key) || []).slice();
    for (const fn of list) fn(event);
  }
}

function matchesSimpleSelector(el, sel) {
  if (sel === "code" || sel === "textarea") return el.tagName.toLowerCase() === sel;
  if (sel.startsWith(".")) return el.className.split(/\s+/).includes(sel.slice(1));
  const attrEq = sel.match(/^\[([^=\]]+)="([^"]*)"\]$/);
  if (attrEq) return el.getAttribute(attrEq[1]) === attrEq[2];
  const attrOnly = sel.match(/^\[([^\]]+)\]$/);
  if (attrOnly) return el.hasAttribute(attrOnly[1]);
  return false;
}

function createFakeDom({ lang = "zh-CN", innerWidth = 1280, innerHeight = 800 } = {}) {
  const doc = {
    nodeType: 9,
    _listeners: new Map(),
    documentElement: null,
    body: null,
    defaultView: null,
    createElement(tag) {
      return new FakeElement(tag, doc);
    },
    createTextNode(text) {
      return new FakeText(text, doc);
    },
    querySelectorAll(sel) {
      return doc.documentElement.querySelectorAll(sel);
    },
    addEventListener(type, fn, capture = false) {
      const key = `${type}:${Boolean(capture)}`;
      const list = doc._listeners.get(key) || [];
      list.push(fn);
      doc._listeners.set(key, list);
    },
    removeEventListener(type, fn, capture = false) {
      const key = `${type}:${Boolean(capture)}`;
      const list = doc._listeners.get(key);
      if (!list) return;
      const idx = list.indexOf(fn);
      if (idx >= 0) list.splice(idx, 1);
    },
    dispatchEvent(type, event, capture = false) {
      const key = `${type}:${Boolean(capture)}`;
      const list = (doc._listeners.get(key) || []).slice();
      for (const fn of list) fn(event);
    },
  };

  doc.documentElement = new FakeElement("html", doc);
  doc.documentElement.setAttribute("lang", lang);
  doc.body = new FakeElement("body", doc);
  doc.documentElement.appendChild(doc.body);

  let currentSelection = null;
  const win = {
    innerWidth,
    innerHeight,
    location: { origin: "dsh-app://app" },
    _listeners: new Map(),
    getSelection() {
      return currentSelection;
    },
    setSelection(sel) {
      currentSelection = sel;
    },
    getComputedStyle(el) {
      return { whiteSpace: el?.style?.whiteSpace || "normal" };
    },
    addEventListener(type, fn, capture = false) {
      const key = `${type}:${Boolean(capture)}`;
      const list = win._listeners.get(key) || [];
      list.push(fn);
      win._listeners.set(key, list);
    },
    removeEventListener(type, fn, capture = false) {
      const key = `${type}:${Boolean(capture)}`;
      const list = win._listeners.get(key);
      if (!list) return;
      const idx = list.indexOf(fn);
      if (idx >= 0) list.splice(idx, 1);
    },
  };
  doc.defaultView = win;

  return { doc, win };
}

function loadClientViaModuleLoader(extraGlobals = {}) {
  const registered = new Map();
  const sandbox = {
    URL,
    AbortController,
    Headers,
    crypto,
    setTimeout,
    clearTimeout,
    console,
    navigator: { language: "zh-CN" },
    ...extraGlobals,
  };
  sandbox.window = sandbox.window || {
    __ModuleLoader__: {
      load(reg) {
        registered.set(reg.id, reg);
      },
    },
  };
  if (!sandbox.window.__ModuleLoader__) {
    sandbox.window.__ModuleLoader__ = {
      load(reg) {
        registered.set(reg.id, reg);
      },
    };
  }
  sandbox.globalThis = sandbox;

  vm.runInNewContext(CLIENT_SOURCE, sandbox, { filename: "client.js" });
  assert.ok(registered.has("coding-rewind-dsh"), "client.js registers id 'coding-rewind-dsh' with __ModuleLoader__");
  const mod = registered.get("coding-rewind-dsh").factory(() => {
    throw new Error("unexpected require() in zero-dependency client plugin");
  });
  return { registered, mod };
}

async function startTestHttpServer(handler) {
  const server = http.createServer((req, res) => {
    if (req.url === "/coding-rewind/api") {
      Promise.resolve(handler(req, res)).catch((err) => {
        if (!res.writableEnded) {
          res.writeHead(500, { "content-type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: err?.message || "internal_error" }));
        }
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    server,
    port,
    baseOrigin: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

function sendRawRequest({ port, method = "POST", path: reqPath = "/coding-rewind/api", headers = {}, body = "" }) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, method, path: reqPath, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try {
          json = raw ? JSON.parse(raw) : null;
        } catch {
        }
        resolve({ status: res.statusCode, raw, json });
      });
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function waitUntil(predicate, { timeoutMs = 2000, intervalMs = 15 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return await predicate();
}

function createMockCordisClientCtx({
  sessionsById = {},
  workspacesItems = [],
  defaultWorkspaceId,
  draftResult = "applied",
  bindingAvailable = true,
  openWorkspaceSessionId = "session-new-1",
  localeActive = "zh",
  onRefresh,
} = {}) {
  let sessionsSnap = { byId: { ...sessionsById }, phase: "ready" };
  const sessionListeners = new Set();
  const localeListeners = new Set();
  let currentLocale = localeActive;
  const effects = [];

  const openWorkspaceCalls = [];
  const openSessionCalls = [];
  const draftInitCalls = [];
  let refreshCount = 0;

  const services = {
    sessions: {
      list: {
        getSnapshot: () => sessionsSnap,
        subscribe: (fn) => {
          sessionListeners.add(fn);
          return () => sessionListeners.delete(fn);
        },
      },
      binding: (sid) => (bindingAvailable ? { sessionId: sid, token: `bind-${sid}` } : undefined),
      refresh: async () => {
        refreshCount += 1;
        if (onRefresh) await onRefresh({ setSessionsById });
      },
    },
    workspaces: {
      list: {
        getSnapshot: () => ({
          items: workspacesItems,
          defaultWorkspaceId,
          phase: "ready",
        }),
      },
    },
    uiWorkspace: {
      openWorkspace: async (workspaceId, beforeOpen) => {
        openWorkspaceCalls.push(workspaceId);
        if (typeof beforeOpen === "function" && openWorkspaceSessionId) {
          beforeOpen(openWorkspaceSessionId);
        }
      },
      openSession: (sessionId) => {
        openSessionCalls.push(sessionId);
      },
    },
    conversation: {
      input: {
        requestDraftInitialization: (binding, options) => {
          draftInitCalls.push({ binding, options });
          return draftResult;
        },
      },
    },
    locale: {
      getSnapshot: () => ({ active: currentLocale }),
      subscribe: (fn) => {
        localeListeners.add(fn);
        return () => localeListeners.delete(fn);
      },
    },
  };

  function setSessionsById(nextById) {
    sessionsSnap = { byId: { ...nextById }, phase: "ready" };
    for (const fn of sessionListeners) fn();
  }

  function setLocale(nextLocale) {
    currentLocale = nextLocale;
    for (const fn of localeListeners) fn();
  }

  const ctx = {
    get: (key) => services[key],
    effect: (fn) => {
      const cleanup = fn();
      if (typeof cleanup === "function") effects.push(cleanup);
    },
    inject: (keys, cb) => {
      if (keys.every((k) => services[k] !== undefined)) {
        cb(ctx);
      }
    },
    disposeAll: () => {
      for (const fn of effects.splice(0)) fn();
    },
  };

  return {
    ctx,
    services,
    setSessionsById,
    setLocale,
    openWorkspaceCalls,
    openSessionCalls,
    draftInitCalls,
    getRefreshCount: () => refreshCount,
  };
}

test("package manifest, cordis patch, classic client loader, and headless host apply", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(PLUGIN_DIR, "package.json"), "utf8"));
  assert.equal(pkg.name, "coding-rewind-dsh");
  assert.equal(pkg.version, "0.1.0");
  assert.equal(pkg.license, "MIT");
  assert.equal(pkg.type, "module");
  assert.equal(pkg.main, "./lib/index.js");
  assert.deepEqual(pkg.exports, {
    ".": "./lib/index.js",
    "./client": "./client.js",
    "./cordis.patch.yml": "./cordis.patch.yml",
    "./package.json": "./package.json",
  });
  assert.equal(pkg.dsh.bundle.patch, "./cordis.patch.yml");
  assert.equal(pkg.dsh.client.platform, "web");
  assert.deepEqual(pkg.dsh.client.inject, [
    "@deepseek-ai/dsh-api-session-controller",
    "@deepseek-ai/dsh-api-workspace-controller",
    "@deepseek-ai/dsh-client-ui-workspace",
    "@deepseek-ai/dsh-client-ui-conversation",
    "@deepseek-ai/dsh-client-ui-session",
    "@deepseek-ai/dsh-client-locale",
  ]);
  assert.equal(pkg.peerDependencies["@deepseek-ai/cordis"], "^4.0.1");
  assert.equal(pkg.dependencies, undefined);

  const patch = fs.readFileSync(path.join(PLUGIN_DIR, "cordis.patch.yml"), "utf8");
  assert.match(patch, /id:\s*coding-rewind-dsh/);
  assert.match(patch, /name:\s*coding-rewind-dsh/);

  const { mod } = loadClientViaModuleLoader();
  assert.equal(mod.name, "coding-rewind-dsh-client");
  assert.equal(typeof mod.apply, "function");

  assert.equal(hostPlugin.name, "coding-rewind-dsh");
  let injectCalledWith = null;
  hostPlugin.apply({
    inject(deps) {
      injectCalledWith = deps;
    },
  });
  assert.deepEqual(injectCalledWith, ["webServer"]);
});

test("resolveDataDir respects env > runtime-config.json > default Application Support", () => {
  const tmpPluginDir = makeTempDir("cr-dsh-plugindir-");
  try {
    fs.writeFileSync(
      path.join(tmpPluginDir, "runtime-config.json"),
      JSON.stringify({ dataDir: "/opt/coding-rewind-configured" }),
      { mode: 0o600 },
    );

    assert.equal(
      resolveDataDir({
        env: { CODING_REWIND_DATA_DIR: "/var/tmp/cr-override" },
        pluginDir: tmpPluginDir,
        homedir: "/Users/alice",
      }),
      "/var/tmp/cr-override",
    );

    assert.equal(
      resolveDataDir({
        env: { CODING_REWIND_DATA_DIR: "relative/path/ignored" },
        pluginDir: tmpPluginDir,
        homedir: "/Users/alice",
      }),
      "/opt/coding-rewind-configured",
    );

    fs.unlinkSync(path.join(tmpPluginDir, "runtime-config.json"));
    assert.equal(
      resolveDataDir({
        env: {},
        pluginDir: tmpPluginDir,
        homedir: "/Users/alice",
      }),
      "/Users/alice/Library/Application Support/CodingRewind",
    );
  } finally {
    fs.rmSync(tmpPluginDir, { recursive: true, force: true });
  }
});

test("Swift Apple-epoch interop, private file security checks, validation, expiry, and startup recovery", () => {
  const dataDir = makeTempDir("cr-dsh-store-");
  try {
    const fixedNowMs = Date.UTC(2026, 10, 19, 12, 0, 0);
    const store = new DshPrivateStore(dataDir, { now: () => fixedNowMs });
    store.ensureDirectories();

    assert.equal(appleSecToUnixMs(0), Date.UTC(2001, 0, 1, 0, 0, 0));
    assert.equal(unixMsToAppleSec(Date.UTC(2001, 0, 1, 0, 0, 0)), 0);
    assert.equal(APPLE_EPOCH_OFFSET_SEC, 978307200);

    for (const dir of [
      store.paths.handoffDir,
      store.paths.handoffRequests,
      store.paths.handoffReceipts,
      store.paths.actionsDir,
      store.paths.actionsRequests,
      store.paths.actionsReceipts,
      store.paths.capturesDir,
      store.paths.capturesRequests,
      store.paths.capturesReceipts,
    ]) {
      const st = fs.lstatSync(dir);
      assert.equal(st.mode & 0o777, 0o700, `managed directory ${dir} must be 0o700`);
    }

    const nowApple = unixMsToAppleSec(fixedNowMs);

    const expiredId = "11111111-1111-4111-8111-111111111111";
    writePrivateJsonAtomic(store.handoffRequestPath(expiredId), {
      version: 1,
      requestId: expiredId,
      createdAt: nowApple - 50,
      expiresAt: nowApple - 5,
      prompt: "already expired",
    });

    const malformedId = "22222222-2222-4222-8222-222222222222";
    fs.writeFileSync(store.handoffRequestPath(malformedId), "{not valid json", { mode: 0o600 });

    const mismatchId = "33333333-3333-4333-8333-333333333333";
    writePrivateJsonAtomic(store.handoffRequestPath(mismatchId), {
      version: 1,
      requestId: "99999999-9999-4999-8999-999999999999",
      createdAt: nowApple - 5,
      expiresAt: nowApple + 30,
      prompt: "wrong id",
    });

    const nulPromptId = "44444444-4444-4444-8444-444444444444";
    writePrivateJsonAtomic(store.handoffRequestPath(nulPromptId), {
      version: 1,
      requestId: nulPromptId,
      createdAt: nowApple - 5,
      expiresAt: nowApple + 30,
      prompt: "bad\0prompt",
    });

    const tooLongLifetimeId = "55555555-5555-4555-8555-555555555555";
    writePrivateJsonAtomic(store.handoffRequestPath(tooLongLifetimeId), {
      version: 1,
      requestId: tooLongLifetimeId,
      createdAt: nowApple,
      expiresAt: nowApple + 60,
      prompt: "lifetime > 45s",
    });

    const hugePromptId = "66666666-6666-4666-8666-666666666666";
    writePrivateJsonAtomic(store.handoffRequestPath(hugePromptId), {
      version: 1,
      requestId: hugePromptId,
      createdAt: nowApple,
      expiresAt: nowApple + 30,
      prompt: "a".repeat(MAX_PROMPT_BYTES + 1),
    });

    const unsafeModeId = "77777777-7777-4777-8777-777777777777";
    fs.writeFileSync(
      store.handoffRequestPath(unsafeModeId),
      JSON.stringify({
        version: 1,
        requestId: unsafeModeId,
        createdAt: nowApple,
        expiresAt: nowApple + 30,
        prompt: "world readable",
      }),
      { mode: 0o644 },
    );
    fs.chmodSync(store.handoffRequestPath(unsafeModeId), 0o644);

    const symlinkTarget = path.join(dataDir, "outside.json");
    fs.writeFileSync(symlinkTarget, "{}", { mode: 0o600 });
    const symlinkId = "88888888-8888-4888-8888-888888888888";
    fs.symlinkSync(symlinkTarget, store.handoffRequestPath(symlinkId));

    const oversizedPath = path.join(dataDir, "oversized.json");
    fs.writeFileSync(oversizedPath, Buffer.alloc(MAX_FILE_BYTES + 16, 0x20), { mode: 0o600 });
    assert.equal(readPrivateJsonFile(oversizedPath).status, "unsafe");
    assert.equal(readPrivateJsonFile(store.handoffRequestPath(symlinkId)).status, "unsafe");
    assert.equal(readPrivateJsonFile(store.handoffRequestPath(unsafeModeId)).status, "unsafe");

    const validId = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
    writePrivateJsonAtomic(store.handoffRequestPath(validId), {
      version: 1,
      requestId: validId,
      createdAt: nowApple - 2,
      expiresAt: nowApple + 40,
      prompt: "Analyze my stashed clips",
    });

    const openDir = path.join(dataDir, "open-dir");
    fs.mkdirSync(openDir, { mode: 0o755 });
    fs.chmodSync(openDir, 0o755);
    assert.throws(() => {
      const badStore = new DshPrivateStore(openDir);
      fs.mkdirSync(path.join(openDir, "dsh-handoff"), { mode: 0o755 });
      fs.chmodSync(path.join(openDir, "dsh-handoff"), 0o755);
      badStore.ensureDirectories();
    }, /permissions too open/);

    const ready = store.scanHandoffRequests(fixedNowMs);
    assert.equal(ready.length, 1);
    assert.equal(ready[0].requestId, validId);
    assert.equal(ready[0].prompt, "Analyze my stashed clips");

    const expReceipt = store.readHandoffReceipt(expiredId);
    assert.equal(expReceipt.status, "ok");
    assert.equal(expReceipt.value.state, "expired");
    assert.ok(Math.abs(expReceipt.value.updatedAt - nowApple) < 0.001);
    assert.equal(fs.existsSync(store.handoffRequestPath(expiredId)), false);

    for (const badId of [malformedId, mismatchId, nulPromptId, tooLongLifetimeId, hugePromptId]) {
      const rec = store.readHandoffReceipt(badId);
      assert.equal(rec.status, "ok", `expected rejected receipt for ${badId}`);
      assert.equal(rec.value.state, "rejected");
      assert.equal(rec.value.requestId, badId);
      assert.equal(fs.existsSync(store.handoffRequestPath(badId)), false);
      const recStat = fs.lstatSync(store.handoffReceiptPath(badId));
      assert.equal(recStat.mode & 0o777, 0o600);
    }

    const staleDispatchId = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF";
    writePrivateJsonAtomic(store.handoffRequestPath(staleDispatchId), {
      version: 1,
      requestId: staleDispatchId,
      createdAt: nowApple - 5,
      expiresAt: nowApple + 30,
      prompt: "in flight before crash",
    });
    store.writeHandoffReceipt(staleDispatchId, "dispatching", { nowMs: fixedNowMs - 1000 });

    const recovered = store.recoverStartup(fixedNowMs);
    assert.deepEqual(recovered, [staleDispatchId]);
    const recoveredReceipt = store.readHandoffReceipt(staleDispatchId);
    assert.equal(recoveredReceipt.status, "ok");
    assert.equal(recoveredReceipt.value.state, "unknown");
    assert.equal(recoveredReceipt.value.requestId, staleDispatchId);
    assert.equal(fs.existsSync(store.handoffRequestPath(staleDispatchId)), false);

    writePrivateJsonAtomic(store.handoffRequestPath(staleDispatchId), {
      version: 1,
      requestId: staleDispatchId,
      createdAt: nowApple - 1,
      expiresAt: nowApple + 30,
      prompt: "must never re-dispatch unknown",
    });
    const afterRecoveryScan = store.scanHandoffRequests(fixedNowMs);
    assert.equal(afterRecoveryScan.some((r) => r.requestId === staleDispatchId), false);
    assert.equal(fs.existsSync(store.handoffRequestPath(staleDispatchId)), false);
  } finally {
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Host /coding-rewind/api enforces HTTP method, origin, sec-fetch-site, content-type, and 2 MiB limits", async () => {
  const dataDir = makeTempDir("cr-dsh-http-");
  const bridge = hostPlugin.createHostBridge({ dataDir, enableWatch: false });
  bridge.start();
  const srv = await startTestHttpServer(bridge.handleHttpRequest);

  try {
    const getRes = await sendRawRequest({
      port: srv.port,
      method: "GET",
      headers: { host: `127.0.0.1:${srv.port}`, origin: `http://127.0.0.1:${srv.port}` },
    });
    assert.equal(getRes.status, 405);

    const wrongType = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `127.0.0.1:${srv.port}`,
        origin: `http://127.0.0.1:${srv.port}`,
        "content-type": "text/plain",
      },
      body: JSON.stringify({ op: "poll", timeoutMs: 0 }),
    });
    assert.equal(wrongType.status, 415);

    for (const badHeaders of [
      { host: `127.0.0.1:${srv.port}`, origin: "https://evil.example", "content-type": "application/json" },
      { host: `127.0.0.1:${srv.port}`, origin: "http://127.0.0.1:9999", "content-type": "application/json" },
      { host: `127.0.0.1:${srv.port}`, origin: "null", "content-type": "application/json" },
      { host: `127.0.0.1:${srv.port}`, origin: "dsh-app://evil", "content-type": "application/json" },
      {
        host: `127.0.0.1:${srv.port}`,
        origin: `http://127.0.0.1:${srv.port}`,
        "sec-fetch-site": "cross-site",
        "content-type": "application/json",
      },
      {
        host: `127.0.0.1:${srv.port}`,
        origin: `http://127.0.0.1:${srv.port}`,
        "sec-fetch-site": "same-site",
        "content-type": "application/json",
      },
    ]) {
      const res = await sendRawRequest({
        port: srv.port,
        headers: badHeaders,
        body: JSON.stringify({ op: "poll", timeoutMs: 0 }),
      });
      assert.equal(res.status, 403, `expected 403 for ${JSON.stringify(badHeaders)}`);
    }

    const allowedDesktop = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `127.0.0.1:${srv.port}`,
        origin: "dsh-app://app",
        "content-type": "application/json",
      },
      body: JSON.stringify({ op: "poll", clientId: "c-desktop", timeoutMs: 0 }),
    });
    assert.equal(allowedDesktop.status, 200);
    assert.deepEqual(allowedDesktop.json, { ok: true, command: null });

    const allowedLoopback = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `localhost:${srv.port}`,
        origin: `http://localhost:${srv.port}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ op: "poll", clientId: "c-web", timeoutMs: 0 }),
    });
    assert.equal(allowedLoopback.status, 200);

    const allowedIpv6 = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `[::1]:${srv.port}`,
        origin: `http://[::1]:${srv.port}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ op: "poll", clientId: "c-v6", timeoutMs: 0 }),
    });
    assert.equal(allowedIpv6.status, 200);

    const allowedElectronProxy = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `127.0.0.1:${srv.port}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ op: "poll", clientId: "c-proxy", timeoutMs: 0 }),
    });
    assert.equal(allowedElectronProxy.status, 200);

    const tooLarge = await sendRawRequest({
      port: srv.port,
      headers: {
        host: `127.0.0.1:${srv.port}`,
        origin: "dsh-app://app",
        "content-type": "application/json",
      },
      body: JSON.stringify({ op: "capture", text: "x".repeat(MAX_FILE_BYTES + 1024) }),
    });
    assert.equal(tooLarge.status, 413);
  } finally {
    bridge.dispose();
    await srv.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Client workspace resolution follows active -> recent -> default -> first -> null priority", () => {
  const { mod } = loadClientViaModuleLoader();

  assert.equal(
    mod.resolveTargetWorkspaceId(
      {
        byId: {
          "s-active": { id: "s-active", updatedAt: 100, retainedBy: { mainView: 1 } },
          "s-recent": { id: "s-recent", updatedAt: 900, retainedBy: {} },
        },
      },
      {
        defaultWorkspaceId: "ws-default",
        items: [
          { workspaceId: "ws-active", sessionIds: ["s-active"], updatedAt: "2026-01-01T00:00:00Z" },
          { workspaceId: "ws-recent", sessionIds: ["s-recent"], updatedAt: "2026-11-01T00:00:00Z" },
          { workspaceId: "ws-default", sessionIds: [], updatedAt: "2025-01-01T00:00:00Z" },
        ],
      },
    ),
    "ws-active",
  );

  assert.equal(
    mod.resolveTargetWorkspaceId(
      {
        byId: {
          "s-old": { id: "s-old", updatedAt: 100, retainedBy: {} },
          "s-new": { id: "s-new", updatedAt: 500, retainedBy: {} },
        },
      },
      {
        defaultWorkspaceId: "ws-old",
        items: [
          { workspaceId: "ws-old", sessionIds: ["s-old"] },
          { workspaceId: "ws-new", sessionIds: ["s-new"] },
        ],
      },
    ),
    "ws-new",
  );

  assert.equal(
    mod.resolveTargetWorkspaceId(
      { byId: {} },
      {
        defaultWorkspaceId: "ws-default",
        items: [
          { workspaceId: "ws-first", sessionIds: [] },
          { workspaceId: "ws-default", sessionIds: [] },
        ],
      },
    ),
    "ws-default",
  );

  assert.equal(
    mod.resolveTargetWorkspaceId(
      { byId: {} },
      { items: [{ workspaceId: "ws-only", sessionIds: [] }] },
    ),
    "ws-only",
  );

  assert.equal(mod.resolveTargetWorkspaceId({ byId: {} }, { items: [] }), null);
});

test("End-to-end prefillDraft over Host + Client: applied succeeds, blocked rejects, no-client rejects, disconnect becomes unknown", async () => {
  const dataDir = makeTempDir("cr-dsh-prefill-");
  const bridge = hostPlugin.createHostBridge({
    dataDir,
    scanIntervalMs: 25,
    clientConnectWaitMs: 180,
    commandTimeoutMs: 500,
    enableWatch: false,
  });
  bridge.start();
  const srv = await startTestHttpServer(bridge.handleHttpRequest);
  const { mod } = loadClientViaModuleLoader();
  const activeHandles = [];

  try {
    const mockOk = createMockCordisClientCtx({
      sessionsById: { "s-active": { id: "s-active", displayTitle: "Main Chat", updatedAt: 100, retainedBy: { mainView: 1 } } },
      workspacesItems: [{ workspaceId: "ws-main", sessionIds: ["s-active"] }],
      draftResult: "applied",
      openWorkspaceSessionId: "session-created-42",
    });

    const handleOk = mod.apply(mockOk.ctx, {
      baseOrigin: srv.baseOrigin,
      fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
      pollTimeoutMs: 2000,
    });
    activeHandles.push(handleOk);

    await new Promise((r) => setTimeout(r, 50));

    const reqId1 = "10000000-0000-4000-8000-000000000001";
    const nowApple = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId1), {
      version: 1,
      requestId: reqId1,
      createdAt: nowApple,
      expiresAt: nowApple + 45,
      prompt: "Synthesize card #1",
    });

    const receipt1 = await waitUntil(() => {
      const r = bridge.store.readHandoffReceipt(reqId1);
      return r.status === "ok" && r.value.state !== "dispatching" ? r.value : null;
    });
    assert.ok(receipt1);
    assert.equal(receipt1.state, "succeeded");
    assert.equal(receipt1.conversationId, "session-created-42");
    assert.equal(receipt1.requestId, reqId1);
    assert.equal(fs.existsSync(bridge.store.handoffRequestPath(reqId1)), false);
    assert.deepEqual(mockOk.openWorkspaceCalls, ["ws-main"]);
    assert.equal(mockOk.draftInitCalls.length, 1);
    assert.equal(mockOk.draftInitCalls[0].options.prompt, "Synthesize card #1");
    assert.equal(mockOk.draftInitCalls[0].options.whenDraftExists, "append");

    handleOk.dispose();

    const mockBlocked = createMockCordisClientCtx({
      workspacesItems: [{ workspaceId: "ws-1", sessionIds: [] }],
      draftResult: "blocked",
      openWorkspaceSessionId: "session-blocked",
    });
    const handleBlocked = mod.apply(mockBlocked.ctx, {
      baseOrigin: srv.baseOrigin,
      fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
      pollTimeoutMs: 2000,
    });
    activeHandles.push(handleBlocked);
    await new Promise((r) => setTimeout(r, 50));

    const reqId2 = "10000000-0000-4000-8000-000000000002";
    const nowApple2 = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId2), {
      version: 1,
      requestId: reqId2,
      createdAt: nowApple2,
      expiresAt: nowApple2 + 45,
      prompt: "Should be blocked",
    });

    const receipt2 = await waitUntil(() => {
      const r = bridge.store.readHandoffReceipt(reqId2);
      return r.status === "ok" && r.value.state !== "dispatching" ? r.value : null;
    });
    assert.ok(receipt2);
    assert.equal(receipt2.state, "rejected");
    assert.equal(receipt2.conversationId, null);
    assert.equal(fs.existsSync(bridge.store.handoffRequestPath(reqId2)), false);
    handleBlocked.dispose();

    const mockPreserved = createMockCordisClientCtx({
      workspacesItems: [{ workspaceId: "ws-1", sessionIds: [] }],
      draftResult: "preserved",
      openWorkspaceSessionId: "session-preserved",
    });
    const handlePreserved = mod.apply(mockPreserved.ctx, {
      baseOrigin: srv.baseOrigin,
      fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
      pollTimeoutMs: 2000,
    });
    activeHandles.push(handlePreserved);
    await new Promise((r) => setTimeout(r, 50));

    const reqId2b = "10000000-0000-4000-8000-00000000002b";
    const nowApple2b = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId2b), {
      version: 1,
      requestId: reqId2b,
      createdAt: nowApple2b,
      expiresAt: nowApple2b + 45,
      prompt: "Preserved is not applied",
    });
    const receipt2b = await waitUntil(() => {
      const r = bridge.store.readHandoffReceipt(reqId2b);
      return r.status === "ok" && r.value.state !== "dispatching" ? r.value : null;
    });
    assert.ok(receipt2b);
    assert.equal(receipt2b.state, "rejected");
    handlePreserved.dispose();

    const mockNoWs = createMockCordisClientCtx({ workspacesItems: [] });
    const handleNoWs = mod.apply(mockNoWs.ctx, {
      baseOrigin: srv.baseOrigin,
      fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
      pollTimeoutMs: 2000,
    });
    activeHandles.push(handleNoWs);
    await new Promise((r) => setTimeout(r, 50));

    const reqId2c = "10000000-0000-4000-8000-00000000002c";
    const nowApple2c = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId2c), {
      version: 1,
      requestId: reqId2c,
      createdAt: nowApple2c,
      expiresAt: nowApple2c + 45,
      prompt: "No workspace exists",
    });
    const receipt2c = await waitUntil(() => {
      const r = bridge.store.readHandoffReceipt(reqId2c);
      return r.status === "ok" && r.value.state !== "dispatching" ? r.value : null;
    });
    assert.ok(receipt2c);
    assert.equal(receipt2c.state, "rejected");
    handleNoWs.dispose();

    await new Promise((r) => setTimeout(r, 40));

    const reqId3 = "10000000-0000-4000-8000-000000000003";
    const nowApple3 = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId3), {
      version: 1,
      requestId: reqId3,
      createdAt: nowApple3,
      expiresAt: nowApple3 + 45,
      prompt: "No client connected",
    });

    const receipt3 = await waitUntil(() => {
      const r = bridge.store.readHandoffReceipt(reqId3);
      return r.status === "ok" ? r.value : null;
    });
    assert.ok(receipt3);
    assert.equal(receipt3.state, "rejected");
    assert.equal(fs.existsSync(bridge.store.handoffRequestPath(reqId3)), false);

    let deliveredMidFlight = 0;
    const pollPromise = fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({ op: "poll", clientId: "flaky-client", timeoutMs: 2000 }),
    }).then((r) => r.json());

    await new Promise((r) => setTimeout(r, 40));

    const reqId4 = "10000000-0000-4000-8000-000000000004";
    const nowApple4 = unixMsToAppleSec(Date.now());
    writePrivateJsonAtomic(bridge.store.handoffRequestPath(reqId4), {
      version: 1,
      requestId: reqId4,
      createdAt: nowApple4,
      expiresAt: nowApple4 + 45,
      prompt: "Disconnect after dispatch",
    });

    const delivered = await pollPromise;
    assert.equal(delivered.ok, true);
    assert.equal(delivered.command.requestId, reqId4);
    deliveredMidFlight += 1;

    const midReceipt = bridge.store.readHandoffReceipt(reqId4);
    assert.equal(midReceipt.status, "ok");
    assert.equal(midReceipt.value.state, "dispatching");

    await fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({ op: "disconnect", clientId: "flaky-client" }),
    });

    const finalReceipt4 = bridge.store.readHandoffReceipt(reqId4);
    assert.equal(finalReceipt4.status, "ok");
    assert.equal(finalReceipt4.value.state, "unknown");
    assert.equal(fs.existsSync(bridge.store.handoffRequestPath(reqId4)), false);

    const nextClientPoll = await fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({ op: "poll", clientId: "healthy-client", timeoutMs: 0 }),
    }).then((r) => r.json());
    assert.equal(nextClientPoll.command, null);
    assert.equal(deliveredMidFlight, 1);
  } finally {
    for (const h of activeHandles) h.dispose();
    bridge.dispose();
    await srv.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("End-to-end openSession action handles existing, refreshed, missing, and expired requests", async () => {
  const dataDir = makeTempDir("cr-dsh-actions-");
  const bridge = hostPlugin.createHostBridge({
    dataDir,
    scanIntervalMs: 25,
    clientConnectWaitMs: 200,
    enableWatch: false,
  });
  bridge.start();
  const srv = await startTestHttpServer(bridge.handleHttpRequest);
  const { mod } = loadClientViaModuleLoader();

  const mock = createMockCordisClientCtx({
    sessionsById: { "sess-existing": { id: "sess-existing", displayTitle: "Existing", retainedBy: {} } },
    onRefresh: async ({ setSessionsById }) => {
      setSessionsById({
        "sess-existing": { id: "sess-existing", displayTitle: "Existing", retainedBy: {} },
        "sess-refreshed": { id: "sess-refreshed", displayTitle: "Refreshed", retainedBy: {} },
      });
    },
  });

  const handle = mod.apply(mock.ctx, {
    baseOrigin: srv.baseOrigin,
    fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
    pollTimeoutMs: 2000,
  });

  try {
    await new Promise((r) => setTimeout(r, 40));

    const nowMs = Date.now();
    writePrivateJsonAtomic(bridge.store.actionRequestPath("act-1"), {
      version: 1,
      requestId: "act-1",
      action: "openSession",
      sessionId: "sess-existing",
      createdAtMs: nowMs,
      expiresAtMs: nowMs + 10_000,
    });
    const rec1 = await waitUntil(() => {
      const r = bridge.store.readActionReceipt("act-1");
      return r.status === "ok" ? r.value : null;
    });
    assert.equal(rec1.state, "succeeded");
    assert.equal(rec1.sessionId, "sess-existing");
    assert.equal(rec1.error, null);
    assert.deepEqual(mock.openSessionCalls, ["sess-existing"]);

    writePrivateJsonAtomic(bridge.store.actionRequestPath("act-2"), {
      version: 1,
      requestId: "act-2",
      action: "openSession",
      sessionId: "sess-refreshed",
      createdAtMs: nowMs,
      expiresAtMs: nowMs + 10_000,
    });
    const rec2 = await waitUntil(() => {
      const r = bridge.store.readActionReceipt("act-2");
      return r.status === "ok" ? r.value : null;
    });
    assert.equal(rec2.state, "succeeded");
    assert.equal(mock.getRefreshCount(), 1);
    assert.deepEqual(mock.openSessionCalls, ["sess-existing", "sess-refreshed"]);

    writePrivateJsonAtomic(bridge.store.actionRequestPath("act-3"), {
      version: 1,
      requestId: "act-3",
      action: "openSession",
      sessionId: "sess-missing",
      createdAtMs: nowMs,
      expiresAtMs: nowMs + 10_000,
    });
    const rec3 = await waitUntil(() => {
      const r = bridge.store.readActionReceipt("act-3");
      return r.status === "ok" ? r.value : null;
    });
    assert.equal(rec3.state, "failed");
    assert.equal(rec3.error, "session_not_found");

    writePrivateJsonAtomic(bridge.store.actionRequestPath("act-expired"), {
      version: 1,
      requestId: "act-expired",
      action: "openSession",
      sessionId: "sess-existing",
      createdAtMs: nowMs - 20_000,
      expiresAtMs: nowMs - 1000,
    });
    const recExp = await waitUntil(() => {
      const r = bridge.store.readActionReceipt("act-expired");
      return r.status === "ok" ? r.value : null;
    });
    assert.equal(recExp.state, "expired");
  } finally {
    handle.dispose();
    bridge.dispose();
    await srv.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("activeSession projects user/assistant messages from sessionQuery and writes 0o600 dsh-active-session.json", async () => {
  const dataDir = makeTempDir("cr-dsh-active-");
  const sessionQuery = {
    async readSession(sessionId) {
      assert.equal(sessionId, "session-proj-1");
      return {
        events: [
          {
            type: "user/message",
            data: {
              source: { kind: "user" },
              content: [
                { type: "text", text: "Explain Rust lifetimes" },
                { type: "image", url: "ignored" },
                { type: "text", text: "with a short example." },
              ],
            },
          },
          {
            type: "user/message",
            data: {
              source: { kind: "compaction" },
              content: [{ type: "text", text: "internal summary should be ignored" }],
            },
          },
          {
            type: "tool/call",
            data: { name: "bash", args: "ls" },
          },
          {
            type: "assistant/message",
            data: {
              message: {
                content: [
                  { type: "tool_use", name: "read_file" },
                  { type: "text", text: "Lifetimes ensure references remain valid." },
                ],
              },
            },
          },
        ],
      };
    },
    async readTitleSnapshots(ids) {
      return ids.map((id) => ({
        sessionId: id,
        status: "fulfilled",
        value: { title: { title: "Rust Lifetimes Deep Dive" } },
      }));
    },
  };

  assert.deepEqual(extractSessionMessages((await sessionQuery.readSession("session-proj-1")).events), [
    { role: "user", text: "Explain Rust lifetimes\nwith a short example." },
    { role: "assistant", text: "Lifetimes ensure references remain valid." },
  ]);

  let registeredRoute = null;
  let disposedEffect = false;
  const hostCtx = {
    inject(deps, cb) {
      assert.deepEqual(deps, ["webServer"]);
      cb({
        get: (key) => (key === "sessionQuery" ? sessionQuery : undefined),
        webServer: {
          register(route) {
            registeredRoute = route;
            return () => {
              disposedEffect = true;
            };
          },
        },
        effect(fn) {
          const cleanup = fn();
          hostCtx._cleanups.push(cleanup);
        },
      });
    },
    _cleanups: [],
  };

  hostPlugin.apply(hostCtx, { dataDir, enableWatch: false });
  assert.ok(registeredRoute);
  assert.equal(registeredRoute.kind, "exact");
  assert.equal(registeredRoute.path, "/coding-rewind/api");

  const srv = await startTestHttpServer(registeredRoute.handler);
  const { mod } = loadClientViaModuleLoader();
  const mockClient = createMockCordisClientCtx({
    sessionsById: {
      "session-proj-1": {
        id: "session-proj-1",
        displayTitle: "Fallback Client Title",
        retainedBy: { mainView: 1 },
      },
    },
  });

  const handle = mod.apply(mockClient.ctx, {
    baseOrigin: srv.baseOrigin,
    fetch: (url, init) => fetch(url, { ...init, headers: { ...init.headers, origin: "dsh-app://app" } }),
    disablePolling: true,
  });

  try {
    const activePath = path.join(dataDir, "dsh-active-session.json");
    const written = await waitUntil(() => {
      const res = readPrivateJsonFile(activePath);
      return res.status === "ok" ? res.value : null;
    });
    assert.ok(written);
    assert.equal(written.version, 1);
    assert.equal(written.sessionId, "session-proj-1");
    assert.equal(written.sessionTitle, "Rust Lifetimes Deep Dive");
    assert.equal(typeof written.updatedAtMs, "number");
    assert.deepEqual(written.messages, [
      { role: "user", text: "Explain Rust lifetimes\nwith a short example." },
      { role: "assistant", text: "Lifetimes ensure references remain valid." },
    ]);
    assert.equal(fs.lstatSync(activePath).mode & 0o777, 0o600);
  } finally {
    handle.dispose();
    for (const fn of hostCtx._cleanups) fn?.();
    assert.equal(disposedEffect, true);
    await srv.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Selection pill capture bridge handles saved, queued_offline, coding_rewind_not_running, and >60s cleanup", async () => {
  const dataDir = makeTempDir("cr-dsh-capture-");
  const sessionQuery = {
    async readSession() {
      return {
        events: [
          { type: "user/message", data: { source: { kind: "user" }, content: [{ type: "text", text: "Q1" }] } },
          { type: "assistant/message", data: { message: { content: [{ type: "text", text: "A1" }] } } },
        ],
      };
    },
    async readTitleSnapshots(ids) {
      return [{ sessionId: ids[0], status: "fulfilled", value: { title: { title: "Resolved Capture Title" } } }];
    },
  };

  const bridge = hostPlugin.createHostBridge({
    dataDir,
    getSessionQuery: () => sessionQuery,
    captureTimeoutMs: 220,
    capturePollIntervalMs: 20,
    enableWatch: false,
  });
  bridge.start();
  const srv = await startTestHttpServer(bridge.handleHttpRequest);

  try {
    const staleReqPath = bridge.store.captureRequestPath("stale-capture-id");
    writePrivateJsonAtomic(staleReqPath, {
      version: 1,
      captureId: "stale-capture-id",
      text: "old",
      createdAtMs: Date.now() - 120_000,
      expiresAtMs: Date.now() - 90_000,
    });

    const savedPromise = fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({
        op: "capture",
        text: "Selected insight",
        sessionId: "sess-cap-1",
        sessionTitle: "Client Title",
      }),
    }).then((r) => r.json());

    const capReq = await waitUntil(() => {
      const files = fs.readdirSync(bridge.store.paths.capturesRequests).filter((f) => f.endsWith(".json"));
      for (const f of files) {
        const res = readPrivateJsonFile(path.join(bridge.store.paths.capturesRequests, f));
        if (res.status === "ok" && res.value.captureId !== "stale-capture-id") return res.value;
      }
      return null;
    });
    assert.ok(capReq);
    assert.equal(capReq.version, 1);
    assert.equal(capReq.text, "Selected insight");
    assert.equal(capReq.sessionId, "sess-cap-1");
    assert.equal(capReq.sessionTitle, "Resolved Capture Title");
    assert.equal(capReq.expiresAtMs - capReq.createdAtMs, 30_000);
    assert.deepEqual(capReq.messages, [
      { role: "user", text: "Q1" },
      { role: "assistant", text: "A1" },
    ]);
    assert.equal(fs.existsSync(staleReqPath), false, "expired >60s capture request cleaned up");

    writePrivateJsonAtomic(bridge.store.captureReceiptPath(capReq.captureId), {
      captureId: capReq.captureId,
      state: "saved",
      clipId: "memo-123",
      error: null,
      updatedAtMs: Date.now(),
    });
    const savedResp = await savedPromise;
    assert.deepEqual(savedResp, { ok: true, state: "saved", clipId: "memo-123" });

    const queuedPromise = fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({ op: "capture", text: "Offline clip", sessionId: null, sessionTitle: "" }),
    }).then((r) => r.json());

    const capReq2 = await waitUntil(() => {
      const files = fs.readdirSync(bridge.store.paths.capturesRequests).filter((f) => f.endsWith(".json"));
      for (const f of files) {
        const res = readPrivateJsonFile(path.join(bridge.store.paths.capturesRequests, f));
        if (res.status === "ok" && res.value.text === "Offline clip") return res.value;
      }
      return null;
    });
    assert.equal(capReq2.sessionTitle, "DeepSeek Harness");
    writePrivateJsonAtomic(bridge.store.captureReceiptPath(capReq2.captureId), {
      captureId: capReq2.captureId,
      state: "queued_offline",
      clipId: "local-9",
      error: null,
      updatedAtMs: Date.now(),
    });
    const queuedResp = await queuedPromise;
    assert.deepEqual(queuedResp, { ok: true, state: "queued_offline", clipId: "local-9" });

    const notRunningResp = await fetch(`${srv.baseOrigin}/coding-rewind/api`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "dsh-app://app" },
      body: JSON.stringify({ op: "capture", text: "No app listening" }),
    }).then((r) => r.json());
    assert.deepEqual(notRunningResp, { ok: false, error: "coding_rewind_not_running" });
  } finally {
    bridge.dispose();
    await srv.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Client markdown extraction preserves code fence blank lines/indentation and uses non-Array NodeList safely", () => {
  const { doc } = createFakeDom();
  const { mod } = loadClientViaModuleLoader();

  const message = doc.createElement("div");
  message.setAttribute("data-text-interaction-source", "assistant");

  const p1 = doc.createElement("p");
  p1.appendChild(doc.createTextNode("Use "));
  const inlineCode = doc.createElement("code");
  inlineCode.appendChild(doc.createTextNode("ctx.effect()"));
  p1.appendChild(inlineCode);
  p1.appendChild(doc.createTextNode(" cleanly."));

  const pre = doc.createElement("pre");
  const copyBtn = doc.createElement("button");
  copyBtn.appendChild(doc.createTextNode("Copy"));
  const code = doc.createElement("code");
  code.setAttribute("class", "language-ts");
  code.appendChild(doc.createTextNode("function run() {\n    const a = 1;\n\n    return a;\n}"));
  pre.append(copyBtn, code);

  const ul = doc.createElement("ul");
  const li1 = doc.createElement("li");
  li1.appendChild(doc.createTextNode("First item"));
  const li2 = doc.createElement("li");
  li2.appendChild(doc.createTextNode("Second item"));
  ul.append(li1, li2);

  message.append(p1, pre, ul);
  doc.body.appendChild(message);

  assert.equal(typeof message.childNodes.some, "undefined", "fixture must use non-Array NodeList");

  const mixedRange = {
    startContainer: p1.childNodes[0],
    startOffset: 0,
    endContainer: li2.childNodes[0],
    endOffset: 11,
    commonAncestorContainer: message,
    cloneContents: () => {
      const frag = new FakeFragment(doc);
      frag.appendChild(p1.cloneNode(true));
      frag.appendChild(pre.cloneNode(true));
      frag.appendChild(ul.cloneNode(true));
      return frag;
    },
  };

  const md = mod.extractSelectionMarkdown(mixedRange, "fallback");
  assert.equal(
    md,
    [
      "Use `ctx.effect()` cleanly.",
      "",
      "```ts",
      "function run() {",
      "    const a = 1;",
      "",
      "    return a;",
      "}",
      "```",
      "",
      "- First item",
      "- Second item",
    ].join("\n"),
  );

  const innerCodeRange = {
    startContainer: code.childNodes[0],
    startOffset: 0,
    endContainer: code.childNodes[0],
    endOffset: 30,
    commonAncestorContainer: code,
    cloneContents: () => {
      const frag = new FakeFragment(doc);
      frag.appendChild(doc.createTextNode("    const a = 1;\n\n    return a;"));
      return frag;
    },
  };
  const partialCodeMd = mod.extractSelectionMarkdown(innerCodeRange, "fallback");
  assert.equal(partialCodeMd, "```ts\n    const a = 1;\n\n    return a;\n```");
});

test("Closed Shadow DOM pill anchors 8px below selection, ignores editable/sidebar, handles closed capture-phase click and feedback", async () => {
  const { doc, win } = createFakeDom({ lang: "zh-CN", innerWidth: 1200, innerHeight: 800 });
  const { mod } = loadClientViaModuleLoader({ window: win, document: doc });

  const msg = doc.createElement("div");
  msg.setAttribute("data-text-interaction-source", "assistant");
  const msgText = doc.createTextNode("Important architecture takeaway");
  msg.appendChild(msgText);

  const composer = doc.createElement("div");
  composer.setAttribute("class", "LexicalEditor");
  composer.setAttribute("contenteditable", "true");
  composer._rect = { left: 100, top: 700, width: 800, height: 80, right: 900, bottom: 780 };
  const composerText = doc.createTextNode("draft text");
  composer.appendChild(composerText);

  const sidebar = doc.createElement("nav");
  const navText = doc.createTextNode("Sidebar session title");
  sidebar.appendChild(navText);

  doc.body.append(msg, composer, sidebar);

  const editableSel = {
    isCollapsed: false,
    rangeCount: 1,
    toString: () => "draft text",
    getRangeAt: () => ({ startContainer: composerText, endContainer: composerText }),
  };
  assert.equal(mod.isValidChatSelection(editableSel), false);

  const navSel = {
    isCollapsed: false,
    rangeCount: 1,
    toString: () => "Sidebar session title",
    getRangeAt: () => ({ startContainer: navText, endContainer: navText }),
  };
  assert.equal(mod.isValidChatSelection(navSel), false);

  const validRange = {
    startContainer: msgText,
    startOffset: 0,
    endContainer: msgText,
    endOffset: 31,
    commonAncestorContainer: msg,
    getClientRects: () =>
      makeFakeNodeList([
        { left: 200, top: 180, width: 220, height: 20, right: 420, bottom: 200 },
        { left: 200, top: 204, width: 160, height: 20, right: 360, bottom: 224 },
      ]),
    cloneContents: () => {
      const frag = new FakeFragment(doc);
      frag.appendChild(doc.createTextNode("Important architecture takeaway"));
      return frag;
    },
  };

  const belowPos = mod.computePillPosition({
    range: validRange,
    pillWidth: 68,
    pillHeight: 26,
    viewportWidth: 1200,
    viewportHeight: 800,
    doc,
  });
  assert.equal(belowPos.placement, "below");
  assert.equal(belowPos.top, 232, "anchors 8px below bottom-most rect (224 + 8)");

  const nearComposerRange = {
    ...validRange,
    getClientRects: () =>
      makeFakeNodeList([{ left: 200, top: 660, width: 200, height: 20, right: 400, bottom: 680 }]),
  };
  const flippedPos = mod.computePillPosition({
    range: nearComposerRange,
    pillWidth: 68,
    pillHeight: 26,
    viewportWidth: 1200,
    viewportHeight: 800,
    doc,
  });
  assert.equal(flippedPos.placement, "above");
  assert.equal(flippedPos.top, 626, "flips 8px above selection (660 - 26 - 8) when blocked by composer");

  const capturePosts = [];
  let resolveCapture;
  const mockFetch = async (_url, init) => {
    const body = JSON.parse(init.body);
    if (body.op === "capture") {
      capturePosts.push(body);
      const reply = await new Promise((r) => {
        resolveCapture = r;
      });
      return { ok: true, status: 200, text: async () => JSON.stringify(reply) };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };

  const mockCtx = createMockCordisClientCtx({
    sessionsById: {
      "s-chat-1": { id: "s-chat-1", displayTitle: "Architecture Notes", retainedBy: { mainView: 1 } },
    },
    localeActive: "zh",
  });

  const handle = mod.apply(mockCtx.ctx, {
    document: doc,
    window: win,
    fetch: mockFetch,
    disablePolling: true,
    feedbackHoldMs: 60,
  });

  try {
    win.setSelection({
      isCollapsed: false,
      rangeCount: 1,
      toString: () => "Important architecture takeaway",
      getRangeAt: () => validRange,
    });

    handle.updatePillFromSelection();
    const debug = handle.getPillDebugState();
    assert.equal(debug.state, "ready");
    assert.equal(debug.label, "暂存");
    assert.equal(debug.host.shadowRoot, null, "Shadow root must be closed");
    assert.match(debug.host.style.cssText, /width:0 !important;height:0 !important/);
    assert.match(debug.host.style.cssText, /pointer-events:none !important/);
    assert.equal(debug.pill.style.top, "232px");

    mockCtx.setLocale("en");
    assert.equal(handle.getPillDebugState().label, "Stash");
    mockCtx.setLocale("zh");
    assert.equal(handle.getPillDebugState().label, "暂存");

    doc.dispatchEvent(
      "mousedown",
      { button: 0, target: debug.host, composedPath: () => [debug.host, doc.documentElement, doc] },
      true,
    );
    assert.equal(handle.getPillDebugState().state, "ready", "capture-phase mousedown on shadow host must not hide pill");

    let prevented = false;
    let stopped = false;
    debug.pill.dispatchDirect("mousedown", {
      button: 0,
      target: debug.pill,
      preventDefault: () => {
        prevented = true;
      },
      stopPropagation: () => {
        stopped = true;
      },
    });
    assert.equal(prevented, true);
    assert.equal(stopped, true);
    assert.equal(handle.getPillDebugState().state, "saving");
    assert.equal(handle.getPillDebugState().label, "暂存中…");

    doc.dispatchEvent("mouseup", { button: 0, target: msg, composedPath: () => [msg, doc.body, doc] }, false);
    assert.equal(handle.getPillDebugState().state, "saving", "paired mouseup on document must be absorbed");

    assert.equal(capturePosts.length, 1);
    assert.equal(capturePosts[0].text, "Important architecture takeaway");
    assert.equal(capturePosts[0].sessionId, "s-chat-1");
    assert.equal(capturePosts[0].sessionTitle, "Architecture Notes");

    resolveCapture({ ok: true, state: "saved", clipId: "clip-1" });
    await waitUntil(() => handle.getPillDebugState().state === "saved");
    assert.equal(handle.getPillDebugState().label, "已暂存");

    await waitUntil(() => handle.getPillDebugState().state === "hidden");

    handle.updatePillFromSelection();
    assert.equal(handle.getPillDebugState().state, "ready");
    doc.dispatchEvent(
      "mousedown",
      { button: 0, target: msg, composedPath: () => [msg, doc.body, doc] },
      true,
    );
    assert.equal(handle.getPillDebugState().state, "hidden", "outside mousedown hides pill");

    handle.updatePillFromSelection();
    debug.pill.dispatchDirect("mousedown", { button: 0, target: debug.pill });
    resolveCapture({ ok: true, state: "queued_offline", clipId: "clip-off" });
    await waitUntil(() => handle.getPillDebugState().state === "queued");
    assert.equal(handle.getPillDebugState().label, "已离线暂存");
    await waitUntil(() => handle.getPillDebugState().state === "hidden");

    handle.updatePillFromSelection();
    debug.pill.dispatchDirect("mousedown", { button: 0, target: debug.pill });
    resolveCapture({ ok: false, error: "coding_rewind_not_running" });
    await waitUntil(() => handle.getPillDebugState().state === "not_running");
    assert.equal(handle.getPillDebugState().label, "请先打开 Coding Rewind");
    await waitUntil(() => handle.getPillDebugState().state === "hidden");

    handle.updatePillFromSelection();
    debug.pill.dispatchDirect("mousedown", { button: 0, target: debug.pill });
    resolveCapture({ ok: false, error: "disk_full" });
    await waitUntil(() => handle.getPillDebugState().state === "error");
    assert.equal(handle.getPillDebugState().label, "暂存失败");
    await waitUntil(() => handle.getPillDebugState().state === "hidden");

    const crossBoundarySel = {
      isCollapsed: false,
      rangeCount: 1,
      toString: () => "crossed",
      getRangeAt: () => ({ startContainer: msgText, endContainer: navText }),
    };
    assert.equal(mod.isValidChatSelection(crossBoundarySel), false);
  } finally {
    handle.dispose();
  }
});

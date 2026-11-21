// SPDX-License-Identifier: MIT

import crypto from "node:crypto";
import fs from "node:fs";
import {
  DshPrivateStore,
  MAX_FILE_BYTES,
  MAX_PROMPT_BYTES,
  readSessionContext,
  resolveDataDir,
} from "./handoff.js";

export const name = "coding-rewind-dsh";

const API_PATH = "/coding-rewind/api";
const DEFAULT_POLL_TIMEOUT_MS = 20_000;
const MAX_POLL_TIMEOUT_MS = 20_000;
const DEFAULT_SCAN_INTERVAL_MS = 200;
const DEFAULT_CLIENT_CONNECT_WAIT_MS = 15_000;
const DEFAULT_COMMAND_TIMEOUT_MS = 15_000;
const DEFAULT_CAPTURE_TIMEOUT_MS = 5_000;
const DEFAULT_CAPTURE_POLL_INTERVAL_MS = 50;
const LOOPBACK_HOST_RE = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;

export function validateApiRequest(req) {
  if (!req || req.method !== "POST") {
    return { ok: false, status: 405, error: "method_not_allowed" };
  }

  const headers = req.headers || {};
  const host = typeof headers.host === "string" ? headers.host.trim() : "";
  const hostLocal = LOOPBACK_HOST_RE.test(host);
  const site = String(headers["sec-fetch-site"] || "").trim().toLowerCase();
  const origin = headers.origin;

  if (site === "cross-site" || site === "same-site") {
    return { ok: false, status: 403, error: "forbidden_origin" };
  }

  let originAllowed = false;
  if (origin === "dsh-app://app") {
    originAllowed = host === "" || hostLocal;
  } else if (origin === undefined || origin === "") {
    originAllowed = hostLocal && (site === "" || site === "none" || site === "same-origin");
  } else if (typeof origin === "string") {
    try {
      const parsed = new URL(origin);
      originAllowed =
        (parsed.protocol === "http:" || parsed.protocol === "https:") &&
        hostLocal &&
        parsed.host.toLowerCase() === host.toLowerCase();
    } catch {
      originAllowed = false;
    }
  }

  if (!originAllowed) {
    return { ok: false, status: 403, error: "forbidden_origin" };
  }

  const contentType = String(headers["content-type"] || "")
    .split(";")[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    return { ok: false, status: 415, error: "unsupported_media_type" };
  }

  return { ok: true };
}

function sendJson(res, statusCode, body) {
  if (!res || res.writableEnded || res.destroyed) return;
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readJsonBody(req, maxBytes = MAX_FILE_BYTES) {
  return new Promise((resolve) => {
    const contentLengthHeader = req.headers?.["content-length"];
    if (contentLengthHeader !== undefined) {
      const declared = Number(contentLengthHeader);
      if (Number.isFinite(declared) && declared > maxBytes) {
        req.resume?.();
        resolve({ ok: false, status: 413, error: "payload_too_large" });
        return;
      }
    }

    const chunks = [];
    let total = 0;
    let settled = false;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    req.on("data", (chunk) => {
      if (settled) return;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > maxBytes) {
        req.resume?.();
        finish({ ok: false, status: 413, error: "payload_too_large" });
        return;
      }
      chunks.push(buf);
    });

    req.on("end", () => {
      if (settled) return;
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw.trim()) {
        finish({ ok: true, body: {} });
        return;
      }
      try {
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
          finish({ ok: false, status: 400, error: "invalid_json" });
          return;
        }
        finish({ ok: true, body: parsed });
      } catch {
        finish({ ok: false, status: 400, error: "invalid_json" });
      }
    });

    req.on("error", () => {
      finish({ ok: false, status: 400, error: "request_stream_error" });
    });

    req.on("aborted", () => {
      finish({ ok: false, status: 400, error: "request_aborted" });
    });
  });
}

function makeUnrefTimer(fn, ms) {
  const id = setTimeout(fn, ms);
  id.unref?.();
  return id;
}

export function createHostBridge({
  dataDir = resolveDataDir(),
  getSessionQuery = () => undefined,
  now = () => Date.now(),
  scanIntervalMs = DEFAULT_SCAN_INTERVAL_MS,
  clientConnectWaitMs = DEFAULT_CLIENT_CONNECT_WAIT_MS,
  commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
  captureTimeoutMs = DEFAULT_CAPTURE_TIMEOUT_MS,
  capturePollIntervalMs = DEFAULT_CAPTURE_POLL_INTERVAL_MS,
  enableWatch = true,
} = {}) {
  const store = new DshPrivateStore(dataDir, { now });

  let started = false;
  let disposed = false;
  let scanTimer = null;
  const watchers = [];
  const activeTimers = new Set();

  const clients = new Map();
  const pendingWaiters = [];
  const inFlightCommands = new Map();
  const trackedHandoffs = new Set();
  const trackedActions = new Set();

  let activeSessionChain = Promise.resolve();
  const captureAbortControllers = new Set();

  function trackTimer(fn, ms) {
    const id = setTimeout(() => {
      activeTimers.delete(id);
      if (!disposed) fn();
    }, ms);
    id.unref?.();
    activeTimers.add(id);
    return id;
  }

  function clearTrackedTimer(id) {
    if (id !== null && id !== undefined) {
      activeTimers.delete(id);
      clearTimeout(id);
    }
  }

  function removeWaiter(waiter) {
    const idx = pendingWaiters.indexOf(waiter);
    if (idx >= 0) pendingWaiters.splice(idx, 1);
  }

  function findAvailablePollClient() {
    for (const entry of clients.values()) {
      if (entry.activePoll && !entry.activePoll.settled) {
        return entry;
      }
    }
    return null;
  }

  function settleInFlightHandoff(requestId, state, conversationId = null) {
    const entry = inFlightCommands.get(requestId);
    if (!entry || entry.kind !== "prefillDraft") return false;
    inFlightCommands.delete(requestId);
    clearTrackedTimer(entry.timer);
    trackedHandoffs.delete(entry.fileStem);
    try {
      store.writeHandoffReceipt(entry.requestId, state, {
        conversationId,
        nowMs: now(),
        fileStem: entry.fileStem,
      });
      store.removeHandoffRequest(entry.fileStem);
    } catch {
    }
    return true;
  }

  function settleInFlightAction(requestId, state, error = null) {
    const entry = inFlightCommands.get(requestId);
    if (!entry || entry.kind !== "openSession") return false;
    inFlightCommands.delete(requestId);
    clearTrackedTimer(entry.timer);
    trackedActions.delete(entry.requestId);
    try {
      store.writeActionReceipt(entry.requestId, state, entry.sessionId, {
        error,
        nowMs: now(),
      });
      store.removeActionRequest(entry.requestId);
    } catch {
    }
    return true;
  }

  function handleClientDisconnected(clientId) {
    const client = clients.get(clientId);
    if (client) {
      if (client.activePoll && !client.activePoll.settled) {
        clearTrackedTimer(client.activePoll.timer);
        client.activePoll.settled = true;
        client.activePoll = null;
      }
      clients.delete(clientId);
    }

    for (const [requestId, entry] of Array.from(inFlightCommands.entries())) {
      if (entry.clientId !== clientId) continue;
      if (entry.kind === "prefillDraft") {
        settleInFlightHandoff(requestId, "unknown", null);
      } else if (entry.kind === "openSession") {
        settleInFlightAction(requestId, "failed", "client_disconnected");
      }
    }
  }

  function dispatchHandoffToClient(request, client) {
    const poll = client.activePoll;
    if (!poll || poll.settled) return false;

    const currentMs = now();
    if (request.expiresAtMs <= currentMs) {
      trackedHandoffs.delete(request.fileStem);
      store.writeHandoffReceipt(request.requestId, "expired", {
        conversationId: null,
        nowMs: currentMs,
        fileStem: request.fileStem,
      });
      store.removeHandoffRequest(request.fileStem);
      return false;
    }

    store.writeHandoffReceipt(request.requestId, "dispatching", {
      conversationId: null,
      nowMs: currentMs,
      fileStem: request.fileStem,
    });

    const remainingMs = Math.max(100, request.expiresAtMs - currentMs);
    const timeoutMs = Math.min(remainingMs, commandTimeoutMs);
    const inFlight = {
      kind: "prefillDraft",
      requestId: request.requestId,
      fileStem: request.fileStem,
      clientId: client.clientId,
      timer: null,
    };
    inFlight.timer = trackTimer(() => {
      settleInFlightHandoff(request.requestId, "unknown", null);
    }, timeoutMs);
    inFlightCommands.set(request.requestId, inFlight);

    poll.deliver({
      kind: "prefillDraft",
      requestId: request.requestId,
      prompt: request.prompt,
    });
    return true;
  }

  function dispatchActionToClient(request, client) {
    const poll = client.activePoll;
    if (!poll || poll.settled) return false;

    const currentMs = now();
    if (request.expiresAtMs <= currentMs) {
      trackedActions.delete(request.requestId);
      store.writeActionReceipt(request.requestId, "expired", request.sessionId, {
        error: "expired",
        nowMs: currentMs,
      });
      store.removeActionRequest(request.requestId);
      return false;
    }

    const remainingMs = Math.max(100, request.expiresAtMs - currentMs);
    const timeoutMs = Math.min(remainingMs, commandTimeoutMs);
    const inFlight = {
      kind: "openSession",
      requestId: request.requestId,
      sessionId: request.sessionId,
      clientId: client.clientId,
      timer: null,
    };
    inFlight.timer = trackTimer(() => {
      settleInFlightAction(request.requestId, "failed", "command_timeout");
    }, timeoutMs);
    inFlightCommands.set(request.requestId, inFlight);

    poll.deliver({
      kind: "openSession",
      requestId: request.requestId,
      sessionId: request.sessionId,
    });
    return true;
  }

  function enqueueHandoffRequest(request) {
    if (trackedHandoffs.has(request.fileStem)) return;
    trackedHandoffs.add(request.fileStem);

    const liveClient = findAvailablePollClient();
    if (liveClient) {
      dispatchHandoffToClient(request, liveClient);
      return;
    }

    const remainingMs = Math.max(0, request.expiresAtMs - now());
    const waitMs = Math.min(remainingMs, clientConnectWaitMs);

    const waiter = {
      kind: "prefillDraft",
      timer: null,
      tryDeliver(client) {
        clearTrackedTimer(waiter.timer);
        return dispatchHandoffToClient(request, client);
      },
      cancel() {
        clearTrackedTimer(waiter.timer);
        trackedHandoffs.delete(request.fileStem);
      },
    };

    waiter.timer = trackTimer(() => {
      removeWaiter(waiter);
      trackedHandoffs.delete(request.fileStem);
      const currentMs = now();
      const state = currentMs >= request.expiresAtMs ? "expired" : "rejected";
      try {
        store.writeHandoffReceipt(request.requestId, state, {
          conversationId: null,
          nowMs: currentMs,
          fileStem: request.fileStem,
        });
        store.removeHandoffRequest(request.fileStem);
      } catch {
      }
    }, waitMs);

    pendingWaiters.push(waiter);
  }

  function enqueueActionRequest(request) {
    if (trackedActions.has(request.requestId)) return;
    trackedActions.add(request.requestId);

    const liveClient = findAvailablePollClient();
    if (liveClient) {
      dispatchActionToClient(request, liveClient);
      return;
    }

    const remainingMs = Math.max(0, request.expiresAtMs - now());
    const waitMs = Math.min(remainingMs, clientConnectWaitMs);

    const waiter = {
      kind: "openSession",
      timer: null,
      tryDeliver(client) {
        clearTrackedTimer(waiter.timer);
        return dispatchActionToClient(request, client);
      },
      cancel() {
        clearTrackedTimer(waiter.timer);
        trackedActions.delete(request.requestId);
      },
    };

    waiter.timer = trackTimer(() => {
      removeWaiter(waiter);
      trackedActions.delete(request.requestId);
      const currentMs = now();
      const expired = currentMs >= request.expiresAtMs;
      try {
        store.writeActionReceipt(
          request.requestId,
          expired ? "expired" : "failed",
          request.sessionId,
          {
            error: expired ? "expired" : "no_client_connected",
            nowMs: currentMs,
          },
        );
        store.removeActionRequest(request.requestId);
      } catch {
      }
    }, waitMs);

    pendingWaiters.push(waiter);
  }

  function scanPendingRequests() {
    if (disposed) return;
    try {
      const handoffs = store.scanHandoffRequests(now());
      for (const req of handoffs) {
        enqueueHandoffRequest(req);
      }
    } catch {
    }
    try {
      const actions = store.scanActionRequests(now());
      for (const req of actions) {
        enqueueActionRequest(req);
      }
    } catch {
    }
  }

  function handlePoll(req, res, body) {
    const clientId = typeof body.clientId === "string" && body.clientId.trim().length > 0
      ? body.clientId.trim().slice(0, 128)
      : crypto.randomUUID();
    const requestedTimeout = Number(body.timeoutMs);
    const timeoutMs = Number.isFinite(requestedTimeout)
      ? Math.max(0, Math.min(MAX_POLL_TIMEOUT_MS, requestedTimeout))
      : DEFAULT_POLL_TIMEOUT_MS;

    let client = clients.get(clientId);
    if (!client) {
      client = { clientId, activePoll: null, lastSeenMs: now() };
      clients.set(clientId, client);
    } else {
      client.lastSeenMs = now();
      if (client.activePoll && !client.activePoll.settled) {
        client.activePoll.respond({ ok: true, command: null });
      }
    }

    const poll = {
      settled: false,
      timer: null,
      respond(payload) {
        if (poll.settled) return;
        poll.settled = true;
        clearTrackedTimer(poll.timer);
        if (client.activePoll === poll) client.activePoll = null;
        sendJson(res, 200, payload);
      },
      deliver(command) {
        poll.respond({ ok: true, command });
      },
    };
    client.activePoll = poll;

    while (pendingWaiters.length > 0 && !poll.settled) {
      const waiter = pendingWaiters.shift();
      waiter.tryDeliver(client);
    }

    if (poll.settled) return;

    if (timeoutMs === 0) {
      poll.respond({ ok: true, command: null });
      return;
    }

    poll.timer = trackTimer(() => {
      poll.respond({ ok: true, command: null });
    }, timeoutMs);

    const onClose = () => {
      if (poll.settled || res.writableEnded) return;
      poll.settled = true;
      clearTrackedTimer(poll.timer);
      if (client.activePoll === poll) client.activePoll = null;
      handleClientDisconnected(clientId);
    };

    req.once("aborted", onClose);
    res.once("close", onClose);
  }

  function handleCompleteCommand(res, body) {
    const requestId = typeof body.requestId === "string" ? body.requestId : "";
    const kind = typeof body.kind === "string" ? body.kind : "";
    const ok = body.ok === true;
    const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
    const error = typeof body.error === "string" ? body.error : null;

    if (!requestId) {
      sendJson(res, 400, { ok: false, error: "missing_request_id" });
      return;
    }

    const inFlight = inFlightCommands.get(requestId);
    if (!inFlight) {
      sendJson(res, 200, { ok: true, alreadySettled: true });
      return;
    }

    if (kind && inFlight.kind !== kind) {
      sendJson(res, 400, { ok: false, error: "command_kind_mismatch" });
      return;
    }

    if (inFlight.kind === "prefillDraft") {
      if (ok && sessionId.trim().length > 0) {
        settleInFlightHandoff(requestId, "succeeded", sessionId.trim());
      } else {
        settleInFlightHandoff(requestId, "rejected", null);
      }
    } else if (inFlight.kind === "openSession") {
      settleInFlightAction(requestId, ok ? "succeeded" : "failed", ok ? null : (error || "failed"));
    }

    sendJson(res, 200, { ok: true });
  }

  function serializeActiveSessionWrite(sessionId, sessionTitle) {
    const task = activeSessionChain.then(async () => {
      if (disposed) return null;
      const context = await readSessionContext(getSessionQuery(), sessionId, sessionTitle);
      if (disposed) return null;
      return store.writeActiveSession({
        sessionId,
        sessionTitle: context.sessionTitle || sessionTitle || "",
        messages: context.messages,
        nowMs: now(),
      });
    });
    activeSessionChain = task.catch(() => {});
    return task;
  }

  async function handleActiveSession(res, body) {
    const sessionId = typeof body.sessionId === "string" ? body.sessionId.trim() : "";
    const sessionTitle = typeof body.sessionTitle === "string" ? body.sessionTitle : "";

    if (!sessionId) {
      sendJson(res, 400, { ok: false, error: "missing_session_id" });
      return;
    }

    try {
      const written = await serializeActiveSessionWrite(sessionId, sessionTitle);
      sendJson(res, 200, {
        ok: true,
        sessionId,
        sessionTitle: written?.sessionTitle ?? sessionTitle,
        messageCount: written?.messages?.length ?? 0,
      });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error?.message || "active_session_write_failed" });
    }
  }

  function waitForCaptureReceipt(captureId, signal) {
    return new Promise((resolve) => {
      const deadline = now() + captureTimeoutMs;
      let done = false;
      let pollTimer = null;
      let watcher = null;

      const finish = (result) => {
        if (done) return;
        done = true;
        if (pollTimer) clearTimeout(pollTimer);
        if (watcher) {
          try {
            watcher.close();
          } catch {
          }
        }
        signal?.removeEventListener("abort", onAbort);
        resolve(result);
      };

      const onAbort = () => {
        finish({ ok: false, error: "host_disposed" });
      };

      if (signal?.aborted) {
        onAbort();
        return;
      }
      signal?.addEventListener("abort", onAbort, { once: true });

      const check = () => {
        if (done) return;
        let receiptRes;
        try {
          receiptRes = store.readCaptureReceipt(captureId);
        } catch (error) {
          finish({ ok: false, error: error?.message || "capture_receipt_error" });
          return;
        }

        if (receiptRes.status === "ok") {
          const receipt = receiptRes.value;
          if (receipt.state === "saved" || receipt.state === "queued_offline") {
            finish({
              ok: true,
              state: receipt.state,
              clipId: receipt.clipId ?? null,
            });
          } else {
            finish({
              ok: false,
              error: typeof receipt.error === "string" && receipt.error ? receipt.error : "capture_failed",
            });
          }
          return;
        }

        if (now() >= deadline) {
          finish({ ok: false, error: "coding_rewind_not_running" });
          return;
        }

        const delay = Math.min(capturePollIntervalMs, Math.max(5, deadline - now()));
        pollTimer = makeUnrefTimer(check, delay);
      };

      if (enableWatch) {
        try {
          watcher = fs.watch(store.paths.capturesReceipts, () => {
            check();
          });
          watcher.on("error", () => {});
        } catch {
        }
      }

      check();
    });
  }

  async function handleCapture(res, body) {
    const text = typeof body.text === "string" ? body.text : "";
    const sessionId = typeof body.sessionId === "string" && body.sessionId.trim().length > 0
      ? body.sessionId.trim()
      : null;
    const clientTitle = typeof body.sessionTitle === "string" ? body.sessionTitle.trim() : "";

    if (!text.trim() || text.includes("\0") || Buffer.byteLength(text, "utf8") > MAX_PROMPT_BYTES) {
      sendJson(res, 400, { ok: false, error: "invalid_capture_text" });
      return;
    }

    const abortController = new AbortController();
    captureAbortControllers.add(abortController);

    try {
      store.cleanupExpiredCaptures(now());
      let messages = [];
      let resolvedTitle = clientTitle;

      if (sessionId) {
        const context = await readSessionContext(getSessionQuery(), sessionId, clientTitle);
        messages = context.messages;
        resolvedTitle = context.sessionTitle || clientTitle;
        await serializeActiveSessionWrite(sessionId, resolvedTitle);
      }

      if (disposed) {
        sendJson(res, 503, { ok: false, error: "host_disposed" });
        return;
      }

      const captureId = crypto.randomUUID().toUpperCase();
      store.writeCaptureRequest({
        captureId,
        text,
        sessionId,
        sessionTitle: resolvedTitle || "DeepSeek Harness",
        messages,
        nowMs: now(),
      });

      const result = await waitForCaptureReceipt(captureId, abortController.signal);
      store.cleanupExpiredCaptures(now());
      sendJson(res, 200, result);
    } catch (error) {
      sendJson(res, 500, { ok: false, error: error?.message || "capture_failed" });
    } finally {
      captureAbortControllers.delete(abortController);
    }
  }

  async function handleHttpRequest(req, res) {
    const guard = validateApiRequest(req);
    if (!guard.ok) {
      sendJson(res, guard.status, { ok: false, error: guard.error });
      return;
    }

    const parsed = await readJsonBody(req, MAX_FILE_BYTES);
    if (!parsed.ok) {
      sendJson(res, parsed.status, { ok: false, error: parsed.error });
      return;
    }

    const body = parsed.body;
    const op = typeof body.op === "string" ? body.op : "";

    if (op === "poll") {
      handlePoll(req, res, body);
      return;
    }
    if (op === "completeCommand") {
      handleCompleteCommand(res, body);
      return;
    }
    if (op === "activeSession") {
      await handleActiveSession(res, body);
      return;
    }
    if (op === "capture") {
      await handleCapture(res, body);
      return;
    }
    if (op === "disconnect") {
      const clientId = typeof body.clientId === "string" ? body.clientId.trim() : "";
      if (clientId) handleClientDisconnected(clientId);
      sendJson(res, 200, { ok: true });
      return;
    }

    sendJson(res, 400, { ok: false, error: "unknown_op" });
  }

  function start() {
    if (started || disposed) return;
    started = true;
    store.recoverStartup(now());
    scanPendingRequests();

    scanTimer = setInterval(scanPendingRequests, scanIntervalMs);
    scanTimer.unref?.();

    if (enableWatch) {
      for (const watchDir of [store.paths.handoffRequests, store.paths.actionsRequests]) {
        try {
          const w = fs.watch(watchDir, () => {
            scanPendingRequests();
          });
          w.on("error", () => {});
          watchers.push(w);
        } catch {
        }
      }
    }
  }

  function dispose() {
    if (disposed) return;
    disposed = true;

    if (scanTimer) {
      clearInterval(scanTimer);
      scanTimer = null;
    }

    for (const w of watchers) {
      try {
        w.close();
      } catch {
      }
    }
    watchers.length = 0;

    for (const waiter of pendingWaiters.splice(0)) {
      waiter.cancel();
    }

    for (const [requestId, entry] of Array.from(inFlightCommands.entries())) {
      if (entry.kind === "prefillDraft") {
        settleInFlightHandoff(requestId, "unknown", null);
      } else if (entry.kind === "openSession") {
        settleInFlightAction(requestId, "failed", "host_disposed");
      }
    }

    for (const client of clients.values()) {
      if (client.activePoll && !client.activePoll.settled) {
        client.activePoll.respond({ ok: false, error: "host_disposed" });
      }
    }
    clients.clear();

    for (const ctrl of captureAbortControllers) {
      ctrl.abort();
    }
    captureAbortControllers.clear();

    for (const timerId of activeTimers) {
      clearTimeout(timerId);
    }
    activeTimers.clear();
  }

  return {
    store,
    start,
    dispose,
    scanPendingRequests,
    handleHttpRequest,
    handleClientDisconnected,
  };
}

export function apply(ctx, config = {}) {
  if (!ctx) return;

  const mountWithWebServer = (webCtx) => {
    const webServer = webCtx?.webServer ?? webCtx?.get?.("webServer");
    if (!webServer || typeof webServer.register !== "function") return;

    const bridge = createHostBridge({
      dataDir: config?.dataDir || resolveDataDir(),
      getSessionQuery: () => {
        if (typeof webCtx?.get === "function") {
          const found = webCtx.get("sessionQuery");
          if (found !== undefined) return found;
        }
        if (typeof ctx?.get === "function") {
          return ctx.get("sessionQuery");
        }
        return webCtx?.sessionQuery ?? ctx?.sessionQuery;
      },
      ...(config || {}),
    });

    bridge.start();

    if (typeof webCtx.effect === "function") {
      webCtx.effect(() =>
        webServer.register({
          kind: "exact",
          path: API_PATH,
          handler: bridge.handleHttpRequest,
        }),
      );
      webCtx.effect(() => () => {
        bridge.dispose();
      });
    } else {
      const unregister = webServer.register({
        kind: "exact",
        path: API_PATH,
        handler: bridge.handleHttpRequest,
      });
      const cleanup = () => {
        try {
          unregister?.();
        } catch {
        }
        bridge.dispose();
      };
      if (typeof ctx.on === "function") {
        ctx.on("dispose", cleanup);
      }
    }
  };

  if (typeof ctx.inject === "function") {
    ctx.inject(["webServer"], mountWithWebServer);
  } else if (ctx.webServer) {
    mountWithWebServer(ctx);
  }
}

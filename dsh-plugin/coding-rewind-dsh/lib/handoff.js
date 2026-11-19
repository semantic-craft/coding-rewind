// SPDX-License-Identifier: MIT

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const APPLE_EPOCH_OFFSET_SEC = 978307200;
export const MAX_FILE_BYTES = 2 * 1024 * 1024;
export const MAX_PROMPT_BYTES = 262144;
export const HANDOFF_MAX_LIFETIME_SEC = 45;
export const CAPTURE_LIFETIME_MS = 30_000;
export const CAPTURE_CLEANUP_AGE_MS = 60_000;
export const TEMP_FILE_CLEANUP_AGE_MS = 120_000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE_ID_RE = /^[A-Za-z0-9._-]{1,128}$/;

const MANAGED_RELATIVE_DIRS = Object.freeze([
  "dsh-handoff",
  path.join("dsh-handoff", "requests"),
  path.join("dsh-handoff", "receipts"),
  "dsh-actions",
  path.join("dsh-actions", "requests"),
  path.join("dsh-actions", "receipts"),
  "dsh-captures",
  path.join("dsh-captures", "requests"),
  path.join("dsh-captures", "receipts"),
]);

const DEFAULT_PLUGIN_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export function appleSecToUnixMs(appleSec) {
  return (appleSec + APPLE_EPOCH_OFFSET_SEC) * 1000;
}

export function unixMsToAppleSec(unixMs) {
  return unixMs / 1000 - APPLE_EPOCH_OFFSET_SEC;
}

export function isValidUuid(value) {
  return typeof value === "string" && UUID_RE.test(value);
}

export function isSafeRequestId(value) {
  return typeof value === "string" && SAFE_ID_RE.test(value) && value !== "." && value !== "..";
}

function getCurrentUid() {
  return typeof process.getuid === "function" ? process.getuid() : 0;
}

function isPrivateMode(mode) {
  return (mode & 0o077) === 0;
}

export function resolveDataDir({
  env = process.env,
  pluginDir = DEFAULT_PLUGIN_DIR,
  homedir = os.homedir(),
} = {}) {
  const fromEnv = typeof env?.CODING_REWIND_DATA_DIR === "string"
    ? env.CODING_REWIND_DATA_DIR.trim()
    : "";
  if (fromEnv && path.isAbsolute(fromEnv)) {
    return path.resolve(fromEnv);
  }

  const runtimeConfigPath = path.join(pluginDir, "runtime-config.json");
  try {
    const st = fs.lstatSync(runtimeConfigPath);
    if (!st.isSymbolicLink() && st.isFile() && st.uid === getCurrentUid() && st.size <= MAX_FILE_BYTES) {
      const raw = JSON.parse(fs.readFileSync(runtimeConfigPath, "utf8"));
      const configured = typeof raw?.dataDir === "string" ? raw.dataDir.trim() : "";
      if (configured && path.isAbsolute(configured)) {
        return path.resolve(configured);
      }
    }
  } catch {
  }

  return path.join(homedir, "Library", "Application Support", "CodingRewind");
}

export function validatePrivateDir(dirPath) {
  const st = fs.lstatSync(dirPath);
  if (st.isSymbolicLink() || !st.isDirectory()) {
    throw new Error(`Expected private directory: ${dirPath}`);
  }
  if (st.uid !== getCurrentUid()) {
    throw new Error(`Directory owner mismatch: ${dirPath}`);
  }
  if (!isPrivateMode(st.mode)) {
    throw new Error(`Directory permissions too open: ${dirPath}`);
  }
  return st;
}

export function ensurePrivateDir(dirPath) {
  try {
    fs.mkdirSync(dirPath, { mode: 0o700 });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  return validatePrivateDir(dirPath);
}

function ensureRootDataDir(dataDir) {
  const resolved = path.resolve(dataDir);
  try {
    const existing = fs.lstatSync(resolved);
    if (existing.isSymbolicLink() || !existing.isDirectory()) {
      throw new Error(`Unsafe data directory: ${resolved}`);
    }
    if (existing.uid !== getCurrentUid()) {
      throw new Error(`Data directory owner mismatch: ${resolved}`);
    }
    return fs.realpathSync(resolved);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }

  fs.mkdirSync(resolved, { recursive: true, mode: 0o700 });
  const created = fs.lstatSync(resolved);
  if (created.isSymbolicLink() || !created.isDirectory()) {
    throw new Error(`Unsafe data directory: ${resolved}`);
  }
  if (created.uid !== getCurrentUid()) {
    throw new Error(`Data directory owner mismatch: ${resolved}`);
  }
  return fs.realpathSync(resolved);
}

function fsyncDirectoryBestEffort(dirPath) {
  let fd;
  try {
    const flags = fs.constants.O_RDONLY
      | (fs.constants.O_DIRECTORY || 0)
      | (fs.constants.O_NOFOLLOW || 0);
    fd = fs.openSync(dirPath, flags);
    fs.fsyncSync(fd);
  } catch {
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
      }
    }
  }
}

export function readPrivateJsonFile(filePath, { maxBytes = MAX_FILE_BYTES } = {}) {
  let st;
  try {
    st = fs.lstatSync(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { status: "missing" };
    }
    return { status: "unsafe", error: error?.message || "lstat failed" };
  }

  const uid = getCurrentUid();
  if (
    st.isSymbolicLink() ||
    !st.isFile() ||
    st.uid !== uid ||
    !isPrivateMode(st.mode) ||
    st.nlink > 1 ||
    st.size > maxBytes
  ) {
    return { status: "unsafe", error: `Unsafe private file: ${filePath}` };
  }

  let fd;
  try {
    const flags = fs.constants.O_RDONLY
      | (fs.constants.O_NOFOLLOW || 0)
      | (fs.constants.O_NONBLOCK || 0);
    fd = fs.openSync(filePath, flags);
    const fst = fs.fstatSync(fd);
    if (
      !fst.isFile() ||
      fst.uid !== uid ||
      !isPrivateMode(fst.mode) ||
      fst.nlink > 1 ||
      fst.size > maxBytes
    ) {
      return { status: "unsafe", error: `Unsafe private file descriptor: ${filePath}` };
    }
    const buf = Buffer.alloc(fst.size);
    let offset = 0;
    while (offset < fst.size) {
      const read = fs.readSync(fd, buf, offset, fst.size - offset, offset);
      if (read <= 0) break;
      offset += read;
    }
    const text = buf.subarray(0, offset).toString("utf8");
    try {
      return { status: "ok", value: JSON.parse(text), mtimeMs: fst.mtimeMs };
    } catch (parseErr) {
      return { status: "malformed", error: parseErr?.message || "invalid json" };
    }
  } catch (error) {
    if (error?.code === "ENOENT") return { status: "missing" };
    return { status: "unsafe", error: error?.message || "read failed" };
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
      }
    }
  }
}

export function writePrivateJsonAtomic(filePath, value) {
  const dir = path.dirname(filePath);
  const uid = getCurrentUid();

  try {
    const existing = fs.lstatSync(filePath);
    if (
      existing.isSymbolicLink() ||
      !existing.isFile() ||
      existing.uid !== uid ||
      existing.nlink > 1
    ) {
      throw new Error(`Refusing to overwrite unsafe target: ${filePath}`);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }

  const tempPath = path.join(dir, `.write-${crypto.randomUUID()}.tmp`);
  const flags = fs.constants.O_WRONLY
    | fs.constants.O_CREAT
    | fs.constants.O_EXCL
    | (fs.constants.O_NOFOLLOW || 0);
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  if (payload.length > MAX_FILE_BYTES) {
    throw new Error(`Payload exceeds ${MAX_FILE_BYTES} bytes`);
  }

  let fd;
  let renamed = false;
  try {
    fd = fs.openSync(tempPath, flags, 0o600);
    let written = 0;
    while (written < payload.length) {
      written += fs.writeSync(fd, payload, written, payload.length - written);
    }
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(tempPath, filePath);
    renamed = true;
    fsyncDirectoryBestEffort(dir);
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
      }
    }
    if (!renamed) {
      try {
        fs.unlinkSync(tempPath);
      } catch {
      }
    }
  }
}

export function removePrivateFile(filePath) {
  try {
    const st = fs.lstatSync(filePath);
    if (st.isSymbolicLink() || !st.isFile() || st.uid !== getCurrentUid()) {
      return false;
    }
    fs.unlinkSync(filePath);
    fsyncDirectoryBestEffort(path.dirname(filePath));
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export function validateHandoffRequest(raw, fileStem) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { valid: false, error: "not_an_object" };
  }
  if (raw.version !== 1) {
    return { valid: false, error: "unsupported_version" };
  }
  if (
    typeof raw.requestId !== "string" ||
    !isValidUuid(raw.requestId) ||
    raw.requestId.toLowerCase() !== fileStem.toLowerCase()
  ) {
    return { valid: false, error: "request_id_mismatch" };
  }
  if (typeof raw.prompt !== "string" || raw.prompt.length === 0) {
    return { valid: false, error: "empty_prompt" };
  }
  if (raw.prompt.includes("\0")) {
    return { valid: false, error: "prompt_contains_nul" };
  }
  if (Buffer.byteLength(raw.prompt, "utf8") > MAX_PROMPT_BYTES) {
    return { valid: false, error: "prompt_too_large" };
  }
  if (typeof raw.createdAt !== "number" || !Number.isFinite(raw.createdAt)) {
    return { valid: false, error: "invalid_created_at" };
  }
  if (typeof raw.expiresAt !== "number" || !Number.isFinite(raw.expiresAt)) {
    return { valid: false, error: "invalid_expires_at" };
  }
  if (raw.expiresAt <= raw.createdAt) {
    return { valid: false, error: "invalid_lifetime" };
  }
  if (raw.expiresAt - raw.createdAt > HANDOFF_MAX_LIFETIME_SEC) {
    return { valid: false, error: "lifetime_exceeded" };
  }

  return {
    valid: true,
    request: {
      version: 1,
      requestId: raw.requestId,
      createdAt: raw.createdAt,
      expiresAt: raw.expiresAt,
      createdAtMs: appleSecToUnixMs(raw.createdAt),
      expiresAtMs: appleSecToUnixMs(raw.expiresAt),
      prompt: raw.prompt,
    },
  };
}

export function validateActionRequest(raw, fileStem) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { valid: false, error: "not_an_object" };
  }
  if (raw.version !== 1) {
    return { valid: false, error: "unsupported_version" };
  }
  if (
    typeof raw.requestId !== "string" ||
    !isSafeRequestId(raw.requestId) ||
    raw.requestId !== fileStem
  ) {
    return { valid: false, error: "request_id_mismatch" };
  }
  if (raw.action !== "openSession") {
    return { valid: false, error: "unsupported_action" };
  }
  if (
    typeof raw.sessionId !== "string" ||
    raw.sessionId.trim().length === 0 ||
    raw.sessionId.includes("\0")
  ) {
    return { valid: false, error: "invalid_session_id" };
  }
  if (typeof raw.createdAtMs !== "number" || !Number.isFinite(raw.createdAtMs)) {
    return { valid: false, error: "invalid_created_at" };
  }
  if (typeof raw.expiresAtMs !== "number" || !Number.isFinite(raw.expiresAtMs)) {
    return { valid: false, error: "invalid_expires_at" };
  }
  if (raw.expiresAtMs <= raw.createdAtMs) {
    return { valid: false, error: "invalid_lifetime" };
  }

  return {
    valid: true,
    request: {
      version: 1,
      requestId: raw.requestId,
      action: "openSession",
      sessionId: raw.sessionId,
      createdAtMs: raw.createdAtMs,
      expiresAtMs: raw.expiresAtMs,
    },
  };
}

export function extractSessionMessages(events) {
  if (!Array.isArray(events)) return [];
  const messages = [];
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    if (event.type === "user/message" && event.data?.source?.kind === "user") {
      const blocks = Array.isArray(event.data?.content) ? event.data.content : [];
      const text = blocks
        .filter((b) => b && b.type === "text" && typeof b.text === "string")
        .map((b) => b.text)
        .join("\n");
      if (text.trim().length > 0) {
        messages.push({ role: "user", text });
      }
    } else if (event.type === "assistant/message") {
      const blocks = Array.isArray(event.data?.message?.content) ? event.data.message.content : [];
      const text = blocks
        .filter((b) => b && b.type === "text" && typeof b.text === "string")
        .map((b) => b.text)
        .join("\n");
      if (text.trim().length > 0) {
        messages.push({ role: "assistant", text });
      }
    }
  }
  return messages;
}

export async function readSessionContext(sessionQuery, sessionId, fallbackTitle = "") {
  let messages = [];
  let resolvedTitle = typeof fallbackTitle === "string" ? fallbackTitle.trim() : "";

  if (!sessionId || typeof sessionId !== "string" || !sessionQuery) {
    return { messages, sessionTitle: resolvedTitle };
  }

  if (typeof sessionQuery.readSession === "function") {
    try {
      const snapshot = await sessionQuery.readSession(sessionId);
      messages = extractSessionMessages(snapshot?.events ?? []);
    } catch {
      messages = [];
    }
  }

  if (typeof sessionQuery.readTitleSnapshots === "function") {
    try {
      const results = await sessionQuery.readTitleSnapshots([sessionId]);
      const first = Array.isArray(results) ? results[0] : null;
      const titleFromSnapshot = first?.status === "fulfilled"
        ? first?.value?.title?.title
        : (typeof first?.title === "string" ? first.title : first?.title?.title);
      if (typeof titleFromSnapshot === "string" && titleFromSnapshot.trim().length > 0) {
        resolvedTitle = titleFromSnapshot.trim();
      }
    } catch {
    }
  }

  return { messages, sessionTitle: resolvedTitle };
}

export class DshPrivateStore {
  constructor(dataDir, { now = () => Date.now() } = {}) {
    this.dataDir = path.resolve(dataDir);
    this.now = now;
    this.paths = {
      handoffDir: path.join(this.dataDir, "dsh-handoff"),
      handoffRequests: path.join(this.dataDir, "dsh-handoff", "requests"),
      handoffReceipts: path.join(this.dataDir, "dsh-handoff", "receipts"),
      actionsDir: path.join(this.dataDir, "dsh-actions"),
      actionsRequests: path.join(this.dataDir, "dsh-actions", "requests"),
      actionsReceipts: path.join(this.dataDir, "dsh-actions", "receipts"),
      capturesDir: path.join(this.dataDir, "dsh-captures"),
      capturesRequests: path.join(this.dataDir, "dsh-captures", "requests"),
      capturesReceipts: path.join(this.dataDir, "dsh-captures", "receipts"),
      activeSessionFile: path.join(this.dataDir, "dsh-active-session.json"),
    };
  }

  ensureDirectories() {
    ensureRootDataDir(this.dataDir);
    for (const rel of MANAGED_RELATIVE_DIRS) {
      ensurePrivateDir(path.join(this.dataDir, rel));
    }
  }

  handoffRequestPath(requestId) {
    return path.join(this.paths.handoffRequests, `${requestId}.json`);
  }

  handoffReceiptPath(requestId) {
    return path.join(this.paths.handoffReceipts, `${requestId}.json`);
  }

  actionRequestPath(requestId) {
    return path.join(this.paths.actionsRequests, `${requestId}.json`);
  }

  actionReceiptPath(requestId) {
    return path.join(this.paths.actionsReceipts, `${requestId}.json`);
  }

  captureRequestPath(captureId) {
    return path.join(this.paths.capturesRequests, `${captureId}.json`);
  }

  captureReceiptPath(captureId) {
    return path.join(this.paths.capturesReceipts, `${captureId}.json`);
  }

  writeHandoffReceipt(
    requestId,
    state,
    { conversationId = null, nowMs = this.now(), fileStem = requestId } = {},
  ) {
    validatePrivateDir(this.paths.handoffReceipts);
    const receipt = {
      requestId,
      state,
      updatedAt: unixMsToAppleSec(nowMs),
      conversationId: conversationId ?? null,
    };
    writePrivateJsonAtomic(this.handoffReceiptPath(fileStem), receipt);
    return receipt;
  }

  readHandoffReceipt(requestId) {
    validatePrivateDir(this.paths.handoffReceipts);
    return readPrivateJsonFile(this.handoffReceiptPath(requestId));
  }

  removeHandoffRequest(requestId) {
    validatePrivateDir(this.paths.handoffRequests);
    return removePrivateFile(this.handoffRequestPath(requestId));
  }

  writeActionReceipt(requestId, state, sessionId, { error = null, nowMs = this.now() } = {}) {
    validatePrivateDir(this.paths.actionsReceipts);
    const receipt = {
      requestId,
      state,
      sessionId,
      error: error ?? null,
      updatedAtMs: Math.round(nowMs),
    };
    writePrivateJsonAtomic(this.actionReceiptPath(requestId), receipt);
    return receipt;
  }

  readActionReceipt(requestId) {
    validatePrivateDir(this.paths.actionsReceipts);
    return readPrivateJsonFile(this.actionReceiptPath(requestId));
  }

  removeActionRequest(requestId) {
    validatePrivateDir(this.paths.actionsRequests);
    return removePrivateFile(this.actionRequestPath(requestId));
  }

  recoverStartup(nowMs = this.now()) {
    this.ensureDirectories();
    const uid = getCurrentUid();

    for (const rel of MANAGED_RELATIVE_DIRS) {
      const dir = path.join(this.dataDir, rel);
      for (const entry of fs.readdirSync(dir)) {
        if (!entry.startsWith(".write-")) continue;
        const full = path.join(dir, entry);
        try {
          const st = fs.lstatSync(full);
          if (!st.isSymbolicLink() && st.isFile() && st.uid === uid && nowMs - st.mtimeMs > TEMP_FILE_CLEANUP_AGE_MS) {
            removePrivateFile(full);
          }
        } catch {
        }
      }
    }

    const recovered = [];
    for (const entry of fs.readdirSync(this.paths.handoffReceipts)) {
      if (!entry.endsWith(".json")) continue;
      const stem = entry.slice(0, -5);
      if (!isValidUuid(stem)) continue;
      const readRes = readPrivateJsonFile(path.join(this.paths.handoffReceipts, entry));
      if (readRes.status !== "ok") continue;
      const receipt = readRes.value;
      if (receipt?.state === "dispatching") {
        const preservedId = typeof receipt.requestId === "string" && isValidUuid(receipt.requestId)
          ? receipt.requestId
          : stem;
        this.writeHandoffReceipt(preservedId, "unknown", {
          conversationId: null,
          nowMs,
          fileStem: stem,
        });
        this.removeHandoffRequest(stem);
        recovered.push(preservedId);
      } else if (
        receipt?.state === "succeeded" ||
        receipt?.state === "rejected" ||
        receipt?.state === "expired" ||
        receipt?.state === "unknown"
      ) {
        this.removeHandoffRequest(stem);
      }
    }

    this.cleanupExpiredCaptures(nowMs);
    return recovered;
  }

  scanHandoffRequests(nowMs = this.now()) {
    validatePrivateDir(this.paths.handoffRequests);
    validatePrivateDir(this.paths.handoffReceipts);

    const ready = [];
    let entries;
    try {
      entries = fs.readdirSync(this.paths.handoffRequests);
    } catch {
      return ready;
    }

    for (const entry of entries) {
      if (!entry.endsWith(".json") || entry.startsWith(".write-")) continue;
      const stem = entry.slice(0, -5);
      if (!isValidUuid(stem)) continue;

      const receiptRes = this.readHandoffReceipt(stem);
      if (receiptRes.status === "ok") {
        if (receiptRes.value?.state !== "dispatching") {
          this.removeHandoffRequest(stem);
        }
        continue;
      }
      if (receiptRes.status === "unsafe") {
        continue;
      }

      const filePath = path.join(this.paths.handoffRequests, entry);
      const readRes = readPrivateJsonFile(filePath);
      if (readRes.status === "missing") continue;
      if (readRes.status === "unsafe") continue;

      if (readRes.status === "malformed") {
        this.writeHandoffReceipt(stem, "rejected", { conversationId: null, nowMs });
        this.removeHandoffRequest(stem);
        continue;
      }

      const validated = validateHandoffRequest(readRes.value, stem);
      if (!validated.valid) {
        this.writeHandoffReceipt(stem, "rejected", { conversationId: null, nowMs });
        this.removeHandoffRequest(stem);
        continue;
      }

      if (validated.request.expiresAtMs <= nowMs) {
        writePrivateJsonAtomic(this.handoffReceiptPath(stem), {
          requestId: validated.request.requestId,
          state: "expired",
          updatedAt: unixMsToAppleSec(nowMs),
          conversationId: null,
        });
        this.removeHandoffRequest(stem);
        continue;
      }

      ready.push({
        fileStem: stem,
        ...validated.request,
      });
    }

    ready.sort((a, b) => a.createdAt - b.createdAt);
    return ready;
  }

  scanActionRequests(nowMs = this.now()) {
    validatePrivateDir(this.paths.actionsRequests);
    validatePrivateDir(this.paths.actionsReceipts);

    const ready = [];
    let entries;
    try {
      entries = fs.readdirSync(this.paths.actionsRequests);
    } catch {
      return ready;
    }

    for (const entry of entries) {
      if (!entry.endsWith(".json") || entry.startsWith(".write-")) continue;
      const stem = entry.slice(0, -5);
      if (!isSafeRequestId(stem)) continue;

      const receiptRes = this.readActionReceipt(stem);
      if (receiptRes.status === "ok") {
        this.removeActionRequest(stem);
        continue;
      }
      if (receiptRes.status === "unsafe") continue;

      const filePath = path.join(this.paths.actionsRequests, entry);
      const readRes = readPrivateJsonFile(filePath);
      if (readRes.status === "missing" || readRes.status === "unsafe") continue;

      if (readRes.status === "malformed") {
        this.writeActionReceipt(stem, "failed", "", { error: "malformed_json", nowMs });
        this.removeActionRequest(stem);
        continue;
      }

      const validated = validateActionRequest(readRes.value, stem);
      if (!validated.valid) {
        const sessionId = typeof readRes.value?.sessionId === "string" ? readRes.value.sessionId : "";
        this.writeActionReceipt(stem, "failed", sessionId, { error: validated.error, nowMs });
        this.removeActionRequest(stem);
        continue;
      }

      if (validated.request.expiresAtMs <= nowMs) {
        this.writeActionReceipt(stem, "expired", validated.request.sessionId, { error: "expired", nowMs });
        this.removeActionRequest(stem);
        continue;
      }

      ready.push(validated.request);
    }

    ready.sort((a, b) => a.createdAtMs - b.createdAtMs);
    return ready;
  }

  writeActiveSession({ sessionId, sessionTitle, messages, nowMs = this.now() }) {
    ensureRootDataDir(this.dataDir);
    const payload = {
      version: 1,
      sessionId,
      sessionTitle: typeof sessionTitle === "string" ? sessionTitle : "",
      updatedAtMs: Math.round(nowMs),
      messages: Array.isArray(messages) ? messages : [],
    };
    writePrivateJsonAtomic(this.paths.activeSessionFile, payload);
    return payload;
  }

  writeCaptureRequest({
    captureId = crypto.randomUUID().toUpperCase(),
    text,
    sessionId = null,
    sessionTitle = "DeepSeek Harness",
    messages = [],
    nowMs = this.now(),
  }) {
    validatePrivateDir(this.paths.capturesRequests);
    const createdAtMs = Math.round(nowMs);
    const payload = {
      version: 1,
      captureId,
      text,
      sessionId: sessionId || null,
      sessionTitle: sessionTitle || "DeepSeek Harness",
      messages: Array.isArray(messages) ? messages : [],
      createdAtMs,
      expiresAtMs: createdAtMs + CAPTURE_LIFETIME_MS,
    };
    writePrivateJsonAtomic(this.captureRequestPath(captureId), payload);
    return payload;
  }

  readCaptureReceipt(captureId) {
    validatePrivateDir(this.paths.capturesReceipts);
    const res = readPrivateJsonFile(this.captureReceiptPath(captureId));
    if (res.status !== "ok") return res;
    const raw = res.value;
    if (
      !raw ||
      typeof raw !== "object" ||
      typeof raw.captureId !== "string" ||
      raw.captureId.toLowerCase() !== captureId.toLowerCase() ||
      !["saved", "queued_offline", "failed"].includes(raw.state)
    ) {
      return { status: "malformed", error: "invalid_capture_receipt" };
    }
    return res;
  }

  cleanupExpiredCaptures(nowMs = this.now()) {
    const uid = getCurrentUid();
    for (const dir of [this.paths.capturesRequests, this.paths.capturesReceipts]) {
      let entries;
      try {
        validatePrivateDir(dir);
        entries = fs.readdirSync(dir);
      } catch {
        continue;
      }
      for (const entry of entries) {
        if (!entry.endsWith(".json")) continue;
        const full = path.join(dir, entry);
        try {
          const st = fs.lstatSync(full);
          if (st.isSymbolicLink() || !st.isFile() || st.uid !== uid) continue;
          if (nowMs - st.mtimeMs > CAPTURE_CLEANUP_AGE_MS) {
            removePrivateFile(full);
            continue;
          }
          const readRes = readPrivateJsonFile(full);
          if (readRes.status === "ok") {
            const val = readRes.value;
            const expiredByRequest = typeof val?.createdAtMs === "number"
              && nowMs - val.createdAtMs > CAPTURE_CLEANUP_AGE_MS;
            const expiredByReceipt = typeof val?.updatedAtMs === "number"
              && nowMs - val.updatedAtMs > CAPTURE_CLEANUP_AGE_MS;
            if (expiredByRequest || expiredByReceipt) {
              removePrivateFile(full);
            }
          }
        } catch {
        }
      }
    }
  }
}

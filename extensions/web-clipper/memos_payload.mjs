// SPDX-License-Identifier: MIT

import "./i18n.js";
import { closeUnbalancedCodeFence } from "./extractors.mjs";

export const CLIP_ID_PATTERN = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$/;
export const MAX_OUTBOX_ITEMS = 50;

const CAPTURE_TAG_EDGE_SPACE = /^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu;
const RESERVED_CAPTURE_TAG = /^(?:rewind|source|project|topic|person)(?:\/|$)/i;
const DEFAULT_CAPTURE_PREFERENCES = normalizeCapturePreferences();

export function parseCaptureTags(input) {
  const tokens = typeof input === "string" ? input.split(/[,\r\n]+/) : input;
  const tags = [];
  const seen = new Set();
  let hasInvalidTag = false;
  for (const token of Array.isArray(tokens) ? tokens : []) {
    if (typeof token !== "string") {
      hasInvalidTag = true;
      continue;
    }
    const trimmed = token.replace(/\0/g, "").replace(CAPTURE_TAG_EDGE_SPACE, "");
    if (!trimmed) continue;
    const tag = trimmed.replace(/^#+/, "");
    if (!tag || /[\p{White_Space}\p{Cc}\p{Cf}]/u.test(tag) || RESERVED_CAPTURE_TAG.test(tag)) {
      hasInvalidTag = true;
      continue;
    }
    const key = tag.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      tags.push(tag);
    }
  }
  return { tags, hasInvalidTag };
}

export function normalizeCapturePreferences(raw) {
  return Object.freeze({
    defaultTags: Object.freeze(parseCaptureTags(raw?.defaultTags).tags),
    includeContext: raw?.includeContext === undefined || raw.includeContext === true,
    enrichWithAI: raw?.enrichWithAI === undefined || raw.enrichWithAI === true
  });
}

export function getToastMessages(locale = "auto") {
  const i18n = globalThis.CodingRewindI18n;
  const resolved = i18n.resolveLocale(locale);
  return Object.freeze({
    SAVED: i18n.t(resolved, "toastSaved"),
    QUEUED: i18n.t(resolved, "toastQueued"),
    UNCONFIGURED: i18n.t(resolved, "toastUnconfigured")
  });
}

const ALPHANUM = "abcdefghijklmnopqrstuvwxyz0123456789";

export function generateClipId(nowMs = Date.now(), randomFn = Math.random) {
  const ts = Math.max(0, Math.floor(Number(nowMs) || Date.now())).toString(10);
  let suffix = "";
  for (let i = 0; i < 8; i += 1) {
    const idx = Math.floor(randomFn() * ALPHANUM.length) % ALPHANUM.length;
    suffix += ALPHANUM[idx];
  }
  const clipId = `rw-${ts}-${suffix}`.slice(0, 32);
  if (!CLIP_ID_PATTERN.test(clipId)) {
    throw new Error(`Invalid generated clipId: ${clipId}`);
  }
  return clipId;
}

function isLoopbackMemosHostname(hostname) {
  const h = String(hostname || "").toLowerCase();
  if (!h) return false;
  if (h === "localhost" || h === "localhost." || h.endsWith(".localhost") || h.endsWith(".localhost.")) {
    return true;
  }
  if (h === "[::1]") {
    return true;
  }
  return /^127(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$/.test(h);
}

export function normalizeMemosBaseUrl(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return "";
  const trimmed = rawUrl.trim();
  if (!trimmed) return "";
  try {
    const parsed = new URL(trimmed);
    if (parsed.username || parsed.password) {
      return "";
    }
    if (parsed.protocol === "https:") {
      if (!parsed.hostname) return "";
    } else if (parsed.protocol === "http:") {
      if (!isLoopbackMemosHostname(parsed.hostname)) {
        return "";
      }
    } else {
      return "";
    }
    const cleanPath = parsed.pathname
      .replace(/\/+$/, "")
      .replace(/\/api(?:\/v1)?(?:\/memos)?$/i, "");
    return `${parsed.origin}${cleanPath}`;
  } catch {
    return "";
  }
}

export function normalizePlatform(rawPlatform) {
  const p = String(rawPlatform || "").trim().toLowerCase();
  if (p === "chatgpt" || p === "claude" || p === "gemini" || p === "web") {
    return p;
  }
  return "web";
}

export function hasClipContext(clip = {}) {
  const hasExplicitPlatform =
    clip && clip.sourcePlatform !== undefined && clip.sourcePlatform !== null && String(clip.sourcePlatform).trim() !== "";
  const platform = hasExplicitPlatform ? normalizePlatform(clip.sourcePlatform) : null;
  const allowSessionOpening = platform === null || platform !== "web";
  const allowPageLead = platform === null || platform === "web";
  return Boolean(
    (clip.sessionId && String(clip.sessionId).trim()) ||
    (allowSessionOpening && clip.sessionOpening && String(clip.sessionOpening).trim()) ||
    (allowPageLead && clip.pageLead && String(clip.pageLead).trim()) ||
    (clip.prompt && String(clip.prompt).trim()) ||
    (clip.recentTurns && String(clip.recentTurns).trim())
  );
}

function cleanSingleLine(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function escapeMarkdownLinkLabel(label) {
  return cleanSingleLine(label)
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
}

const ALLOWED_SOURCE_PROTOCOLS = new Set(["http:", "https:", "file:", "conversation:"]);

function sanitizeMarkdownUrl(rawUrl) {
  const cleaned = String(rawUrl || "")
    .replace(/[\u0000-\u001f\u007f-\u009f]+/g, "")
    .trim();
  if (!cleaned) return "";
  try {
    const parsed = new URL(cleaned);
    const protocol = parsed.protocol.toLowerCase();
    if (!ALLOWED_SOURCE_PROTOCOLS.has(protocol)) {
      return "";
    }
    if (protocol === "file:") {
      const host = parsed.hostname.toLowerCase();
      const lower = cleaned.toLowerCase();
      if (
        (host && host !== "localhost") ||
        (!lower.startsWith("file:///") && !lower.startsWith("file://localhost/")) ||
        !parsed.pathname
      ) {
        return "";
      }
    } else if (protocol === "conversation:") {
      const rest = cleaned.slice("conversation:".length).replace(/^\/+|\/+$/g, "");
      if (!rest) return "";
    } else if (!parsed.hostname) {
      return "";
    }
  } catch {
    return "";
  }
  return cleaned
    .replace(/\s+/g, "%20")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29");
}

function formatUtcIso(createdAt) {
  const date = createdAt instanceof Date
    ? createdAt
    : createdAt
      ? new Date(createdAt)
      : new Date();
  const validDate = Number.isNaN(date.getTime()) ? new Date() : date;
  return validDate.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function formatContextComment(clip, platform, sessionTitle) {
  const sessionId = cleanSingleLine(clip?.sessionId);
  const prompt = closeUnbalancedCodeFence(String(clip?.prompt || "").trim());
  const pageLead = platform === "web" ? closeUnbalancedCodeFence(String(clip?.pageLead || "").trim()) : "";
  const sessionOpening = platform === "web" ? "" : closeUnbalancedCodeFence(String(clip?.sessionOpening || "").trim());
  const recentTurns = String(clip?.recentTurns || "").trim();
  if (!hasClipContext({ sessionId, sessionOpening, pageLead, prompt, recentTurns })) return null;

  const headerLines = ["<!-- rewind-context-v1 -->"];
  if (sessionTitle) headerLines.push(`Session Title: ${sessionTitle}`);
  if (sessionId) headerLines.push(`Session ID: ${sessionId}`);
  if (prompt) headerLines.push(`Prompt: ${prompt}`);
  const sections = [headerLines.join("\n")];
  if (sessionOpening) sections.push(`### Session Opening\n${sessionOpening}`);
  else if (pageLead) sections.push(`### Page Lead\n${pageLead}`);
  if (recentTurns) sections.push(`### Recent Turns\n${recentTurns}`);
  return { content: sections.join("\n\n"), visibility: "PRIVATE" };
}

export function buildMemosWirePayloads(clip, options = {}) {
  const selectedMarkdown = String(clip?.selectedMarkdown ?? "");
  if (!selectedMarkdown.trim()) {
    throw new Error("selectedMarkdown must not be empty");
  }

  const clipId = options.clipId || clip?.clipId || generateClipId(options.nowMs, options.randomFn);
  if (!CLIP_ID_PATTERN.test(clipId)) {
    throw new Error(`clipId violates Memos resource ID format: ${clipId}`);
  }
  const commentId = `${clipId}-ctx`;
  if (!CLIP_ID_PATTERN.test(commentId)) {
    throw new Error(`commentId violates Memos resource ID format: ${commentId}`);
  }

  const platform = normalizePlatform(clip?.sourcePlatform);
  const sessionTitle = cleanSingleLine(clip?.sessionTitle);
  const sourceUrl = sanitizeMarkdownUrl(clip?.sourceUrl);
  const createdAtIso = formatUtcIso(options.createdAt ?? clip?.createdAt);

  const { defaultTags, includeContext, enrichWithAI } = options.capturePreferences ?? DEFAULT_CAPTURE_PREFERENCES;
  const commentBody = includeContext ? formatContextComment(clip, platform, sessionTitle) : null;
  const tags = [enrichWithAI ? "#rewind/pending" : "#rewind/ready"];
  if (commentBody && enrichWithAI) tags.push("#rewind/has-ctx");
  tags.push(`#source/${platform}`, ...defaultTags.map((tag) => `#${tag}`));

  const i18n = globalThis.CodingRewindI18n;
  const resolvedLocale = i18n.resolveLocale(options.locale ?? "auto");
  const fallbackTitle = i18n.t(resolvedLocale, "untitledSession");
  const linkLabel = escapeMarkdownLinkLabel(sessionTitle || fallbackTitle);
  const sourceLine = sourceUrl
    ? `> **Source:** [${linkLabel}](${sourceUrl}) · ${createdAtIso}`
    : `> **Source:** ${linkLabel} · ${createdAtIso}`;

  const memoBody = {
    content: `${tags.join(" ")}\n\n${sourceLine}\n\n${selectedMarkdown}`,
    visibility: "PRIVATE"
  };

  return {
    clipId,
    commentId,
    hasContext: commentBody !== null,
    createdAt: createdAtIso,
    memoPath: `/api/memos?memoId=${encodeURIComponent(clipId)}`,
    memoBody,
    commentBody,
    commentPathForServerId(serverId) {
      if (!serverId) throw new Error("serverId is required for comment path");
      return `/api/memos/${encodeURIComponent(serverId)}/comments?commentId=${encodeURIComponent(commentId)}`;
    }
  };
}

export function parseServerMemoId(memoResponse) {
  const name = memoResponse && typeof memoResponse.name === "string" ? memoResponse.name : "";
  const parts = name.split("/");
  if (parts.length < 2 || parts[0] !== "memos" || !parts[1]) {
    throw new Error(`Unexpected Memos response name: ${name}`);
  }
  return parts[1];
}

export function createOutboxEnvelope(clip, options = {}) {
  const built = buildMemosWirePayloads(clip, options);
  return {
    clipId: built.clipId,
    commentId: built.commentId,
    hasContext: built.hasContext,
    createdAt: built.createdAt,
    memoBody: built.memoBody,
    commentBody: built.commentBody,
    serverId: clip?.serverId || null
  };
}

export function enqueueOutboxItem(existingOutbox, envelope, maxItems = MAX_OUTBOX_ITEMS) {
  const list = Array.isArray(existingOutbox) ? existingOutbox.slice() : [];
  const existingIdx = list.findIndex((item) => item && item.clipId === envelope.clipId);
  if (existingIdx >= 0) {
    list[existingIdx] = envelope;
  } else {
    list.push(envelope);
  }
  if (list.length > maxItems) {
    return list.slice(list.length - maxItems);
  }
  return list;
}

function isRetryableStatus(status) {
  return status >= 500 || status === 408 || status === 429;
}

export function buildAuthHeaders(token, { includeJsonContentType = true } = {}) {
  const headers = includeJsonContentType ? { "Content-Type": "application/json" } : {};
  const cleanToken = String(token || "").trim();
  if (cleanToken) {
    headers.Authorization = `Bearer ${cleanToken}`;
  }
  return headers;
}

export async function deliverEnvelopeToMemos({
  baseUrl,
  token = "",
  envelope,
  fetchImpl = globalThis.fetch
}) {
  const normalizedUrl = normalizeMemosBaseUrl(baseUrl);
  if (!normalizedUrl) {
    return { ok: false, retryable: false, unconfigured: true, serverId: envelope?.serverId || null };
  }

  const headers = buildAuthHeaders(token);
  let serverId = envelope.serverId || null;

  if (!serverId) {
    let memoResp;
    try {
      memoResp = await fetchImpl(
        `${normalizedUrl}/api/memos?memoId=${encodeURIComponent(envelope.clipId)}`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(envelope.memoBody)
        }
      );
    } catch (err) {
      return { ok: false, retryable: true, serverId: null, error: String(err) };
    }

    if (memoResp.status === 409) {
      try {
        const getResp = await fetchImpl(
          `${normalizedUrl}/api/memos/${encodeURIComponent(envelope.clipId)}`,
          { method: "GET", headers }
        );
        if (getResp.ok) {
          try {
            const existingJson = await getResp.json();
            serverId = parseServerMemoId(existingJson);
          } catch (err) {
            return { ok: false, retryable: true, serverId: null, error: String(err) };
          }
        } else {
          serverId = envelope.clipId;
        }
      } catch {
        serverId = envelope.clipId;
      }
    } else if (!memoResp.ok) {
      return {
        ok: false,
        retryable: isRetryableStatus(memoResp.status),
        status: memoResp.status,
        serverId: null
      };
    } else {
      try {
        const memoJson = await memoResp.json();
        serverId = parseServerMemoId(memoJson);
      } catch (err) {
        return { ok: false, retryable: true, serverId: null, error: String(err) };
      }
    }
  }

  if (envelope.hasContext && envelope.commentBody) {
    let commentResp;
    try {
      commentResp = await fetchImpl(
        `${normalizedUrl}/api/memos/${encodeURIComponent(serverId)}/comments?commentId=${encodeURIComponent(envelope.commentId)}`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(envelope.commentBody)
        }
      );
    } catch (err) {
      return { ok: false, retryable: true, serverId, error: String(err) };
    }

    if (!commentResp.ok && commentResp.status !== 409) {
      return {
        ok: false,
        retryable: isRetryableStatus(commentResp.status),
        status: commentResp.status,
        serverId
      };
    }
  }

  return { ok: true, retryable: false, serverId, clipId: envelope.clipId };
}

export async function flushOutbox({
  baseUrl,
  token = "",
  storage,
  fetchImpl = globalThis.fetch
}) {
  const normalizedUrl = normalizeMemosBaseUrl(baseUrl);
  const current = await storage.getOutbox();
  if (!normalizedUrl || !Array.isArray(current) || current.length === 0) {
    return { flushed: 0, remaining: Array.isArray(current) ? current.length : 0 };
  }

  const remaining = [];
  let flushed = 0;
  let networkBlocked = false;

  for (const item of current) {
    if (networkBlocked) {
      remaining.push(item);
      continue;
    }
    const result = await deliverEnvelopeToMemos({
      baseUrl: normalizedUrl,
      token,
      envelope: item,
      fetchImpl
    });
    if (result.ok) {
      flushed += 1;
    } else if (result.retryable) {
      remaining.push({ ...item, serverId: result.serverId || item.serverId || null });
      networkBlocked = true;
    } else {
      remaining.push({ ...item, serverId: result.serverId || item.serverId || null });
      break;
    }
  }

  if (remaining.length < current.length - flushed) {
    const processedCount = flushed + remaining.length;
    for (let i = processedCount; i < current.length; i += 1) {
      remaining.push(current[i]);
    }
  }

  await storage.setOutbox(remaining.slice(-MAX_OUTBOX_ITEMS));
  return { flushed, remaining: Math.min(remaining.length, MAX_OUTBOX_ITEMS) };
}

export async function saveClipWithOutbox({
  clip,
  baseUrl,
  token = "",
  storage,
  fetchImpl = globalThis.fetch,
  nowMs,
  randomFn,
  locale = "auto",
  capturePreferences,
  maximumMemoBytes
}) {
  const toasts = getToastMessages(locale);
  const envelope = createOutboxEnvelope(clip, { nowMs, randomFn, locale, capturePreferences });
  if (maximumMemoBytes !== undefined && new TextEncoder().encode(envelope.memoBody.content).byteLength > maximumMemoBytes) {
    const i18n = globalThis.CodingRewindI18n;
    return { status: "error", queued: false, toast: i18n.t(i18n.resolveLocale(locale), "toastPageReadingTooLarge") };
  }
  const normalizedUrl = normalizeMemosBaseUrl(baseUrl);

  if (!normalizedUrl) {
    const updated = enqueueOutboxItem(await storage.getOutbox(), envelope);
    await storage.setOutbox(updated);
    return {
      status: "unconfigured",
      toast: toasts.UNCONFIGURED,
      clipId: envelope.clipId,
      queued: true,
      outboxSize: updated.length
    };
  }

  await flushOutbox({ baseUrl: normalizedUrl, token, storage, fetchImpl });

  const delivery = await deliverEnvelopeToMemos({
    baseUrl: normalizedUrl,
    token,
    envelope,
    fetchImpl
  });

  if (delivery.ok) {
    return {
      status: "saved",
      toast: toasts.SAVED,
      clipId: envelope.clipId,
      serverId: delivery.serverId,
      queued: false
    };
  }

  const updatedEnvelope = { ...envelope, serverId: delivery.serverId || null };
  const updated = enqueueOutboxItem(await storage.getOutbox(), updatedEnvelope);
  await storage.setOutbox(updated);

  if (!delivery.retryable && (delivery.status === 401 || delivery.status === 403)) {
    return {
      status: "unconfigured",
      toast: toasts.UNCONFIGURED,
      clipId: envelope.clipId,
      queued: true,
      outboxSize: updated.length
    };
  }

  return {
    status: "queued",
    toast: toasts.QUEUED,
    clipId: envelope.clipId,
    queued: true,
    outboxSize: updated.length
  };
}

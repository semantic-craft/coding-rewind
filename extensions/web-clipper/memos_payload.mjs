// SPDX-License-Identifier: MIT

export const CLIP_ID_PATTERN = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$/;
export const MAX_OUTBOX_ITEMS = 50;

export const TOAST_MESSAGES = Object.freeze({
  SAVED: "已存入 Rewind 热池 · AI 正在定锚脉络",
  QUEUED: "离线已暂存队列",
  UNCONFIGURED: "请先配置 Memos 地址"
});

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

export function normalizeMemosBaseUrl(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return "";
  const trimmed = rawUrl.trim();
  if (!trimmed) return "";
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
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
  return Boolean(
    (clip.sessionTitle && String(clip.sessionTitle).trim()) ||
    (clip.prompt && String(clip.prompt).trim()) ||
    (clip.recentTurns && String(clip.recentTurns).trim())
  );
}

function cleanSingleLine(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function escapeMarkdownLinkLabel(label) {
  return cleanSingleLine(label).replace(/\[/g, "\\[").replace(/\]/g, "\\]");
}

function sanitizeMarkdownUrl(rawUrl) {
  return String(rawUrl || "")
    .trim()
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

export function buildMemosWirePayloads(clip, options = {}) {
  const selectedMarkdown = String(clip?.selectedMarkdown || "").trim();
  if (!selectedMarkdown) {
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
  const prompt = String(clip?.prompt || "").trim();
  const recentTurns = String(clip?.recentTurns || "").trim();
  const sourceUrl = sanitizeMarkdownUrl(clip?.sourceUrl);
  const createdAtIso = formatUtcIso(options.createdAt ?? clip?.createdAt);

  const hasContext = hasClipContext({ sessionTitle, prompt, recentTurns });
  const tagsLine = hasContext
    ? `#rewind/pending #rewind/has-ctx #source/${platform}`
    : `#rewind/pending #source/${platform}`;

  const linkLabel = escapeMarkdownLinkLabel(sessionTitle || platform);
  const sourceLine = sourceUrl
    ? `> **Source:** [${linkLabel}](${sourceUrl}) · ${createdAtIso}`
    : `> **Source:** ${linkLabel} · ${createdAtIso}`;

  const memoBody = {
    content: `${tagsLine}\n\n${sourceLine}\n\n${selectedMarkdown}`,
    visibility: "PRIVATE"
  };

  const commentBody = hasContext
    ? {
        content: `<!-- rewind-context-v1 -->\nSession Title: ${sessionTitle}\nPrompt: ${prompt}\n\n### Recent Turns\n${recentTurns}`,
        visibility: "PRIVATE"
      }
    : null;

  return {
    clipId,
    commentId,
    hasContext,
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

export const buildMemoPayload = buildMemosWirePayloads;

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

function buildAuthHeaders(token) {
  const headers = { "Content-Type": "application/json" };
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
          const existingJson = await getResp.json();
          serverId = parseServerMemoId(existingJson);
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
      const memoJson = await memoResp.json();
      serverId = parseServerMemoId(memoJson);
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
  randomFn
}) {
  const envelope = createOutboxEnvelope(clip, { nowMs, randomFn });
  const normalizedUrl = normalizeMemosBaseUrl(baseUrl);

  if (!normalizedUrl) {
    const updated = enqueueOutboxItem(await storage.getOutbox(), envelope);
    await storage.setOutbox(updated);
    return {
      status: "unconfigured",
      toast: TOAST_MESSAGES.UNCONFIGURED,
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
      toast: TOAST_MESSAGES.SAVED,
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
      toast: TOAST_MESSAGES.UNCONFIGURED,
      clipId: envelope.clipId,
      queued: true,
      outboxSize: updated.length
    };
  }

  return {
    status: "queued",
    toast: TOAST_MESSAGES.QUEUED,
    clipId: envelope.clipId,
    queued: true,
    outboxSize: updated.length
  };
}

// SPDX-License-Identifier: MIT

import { normalizeMemosBaseUrl } from "./memos_payload.mjs";

export async function testMemosConnection({ baseUrl, token, fetchImpl = globalThis.fetch }) {
  const normalized = normalizeMemosBaseUrl(baseUrl);
  if (!normalized) {
    return { ok: false, message: "请输入合法的 Memos 地址" };
  }
  const headers = {};
  if (token && token.trim()) {
    headers.Authorization = `Bearer ${token.trim()}`;
  }
  try {
    const resp = await fetchImpl(`${normalized}/api/memos?pageSize=1`, {
      method: "GET",
      headers
    });
    if (!resp.ok) {
      return { ok: false, status: resp.status, message: `连接失败 (HTTP ${resp.status})` };
    }
    await resp.json();
    return { ok: true, message: "连接成功 · 已验证读取，尚未验证保存" };
  } catch (err) {
    return { ok: false, message: `网络请求失败: ${err?.message || String(err)}` };
  }
}

async function requestOriginPermission(normalizedUrl) {
  if (typeof chrome === "undefined" || !chrome.permissions?.request) return true;
  try {
    const originPattern = `${new URL(normalizedUrl).origin}/*`;
    return await chrome.permissions.request({ origins: [originPattern] });
  } catch {
    return false;
  }
}

function initOptionsPage() {
  if (typeof document === "undefined") return;
  const formEl = document.getElementById("settings-form");
  const urlInput = document.getElementById("memos-url");
  const tokenInput = document.getElementById("memos-token");
  const pillCheckbox = document.getElementById("show-pill");
  const testBtn = document.getElementById("test-btn");
  const flushBtn = document.getElementById("flush-btn");
  const statusEl = document.getElementById("status");
  const outboxCountEl = document.getElementById("outbox-count");
  if (!formEl) return;

  function setStatus(message, kind = "info") {
    statusEl.textContent = message;
    statusEl.setAttribute("data-kind", kind);
  }

  function renderOutboxCount(outbox) {
    const count = Array.isArray(outbox) ? outbox.length : 0;
    outboxCountEl.textContent = `离线待同步队列: ${count} 条`;
    flushBtn.hidden = count === 0;
  }

  async function loadInitialState() {
    if (typeof chrome === "undefined" || !chrome.storage?.local) return;
    const items = await chrome.storage.local.get(["memosUrl", "memosToken", "showSelectionPill", "outbox"]);
    if (typeof items.memosUrl === "string") urlInput.value = items.memosUrl;
    if (typeof items.memosToken === "string") tokenInput.value = items.memosToken;
    pillCheckbox.checked = items.showSelectionPill !== false;
    renderOutboxCount(items.outbox);
  }

  void loadInitialState();

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area === "local" && changes.outbox) {
      renderOutboxCount(changes.outbox.newValue);
    }
  });

  formEl.addEventListener("submit", async (event) => {
    event.preventDefault();
    const normalized = normalizeMemosBaseUrl(urlInput.value);
    if (!normalized) {
      setStatus("请输入合法的 HTTP/HTTPS Memos 地址", "error");
      return;
    }
    const granted = await requestOriginPermission(normalized);
    if (!granted) {
      setStatus("未授予该域名网络访问权限，无法直连 Memos", "error");
      return;
    }

    urlInput.value = normalized;
    await chrome.storage.local.set({
      memosUrl: normalized,
      memosToken: tokenInput.value.trim(),
      showSelectionPill: pillCheckbox.checked
    });
    setStatus("设置已保存", "ok");
    chrome.runtime?.sendMessage?.({ type: "REWIND_FLUSH_OUTBOX" });
  });

  testBtn?.addEventListener("click", async () => {
    const normalized = normalizeMemosBaseUrl(urlInput.value);
    if (!normalized) {
      setStatus("请输入合法的 HTTP/HTTPS Memos 地址", "error");
      return;
    }
    const granted = await requestOriginPermission(normalized);
    if (!granted) {
      setStatus("未授予该域名网络访问权限", "error");
      return;
    }
    setStatus("正在测试连接…", "info");
    const res = await testMemosConnection({
      baseUrl: normalized,
      token: tokenInput.value.trim()
    });
    setStatus(res.message, res.ok ? "ok" : "error");
  });

  flushBtn?.addEventListener("click", async () => {
    setStatus("正在同步离线队列…", "info");
    const resp = await chrome.runtime.sendMessage({ type: "REWIND_FLUSH_OUTBOX" });
    if (resp && resp.ok) {
      setStatus(`已同步 ${resp.flushed} 条，剩余 ${resp.remaining} 条`, resp.remaining === 0 ? "ok" : "info");
    } else {
      setStatus("同步失败，请检查网络或配置", "error");
    }
  });
}

initOptionsPage();

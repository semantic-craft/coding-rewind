// SPDX-License-Identifier: MIT

import "./i18n.js";
import { buildAuthHeaders, normalizeMemosBaseUrl } from "./memos_payload.mjs";

export async function probeMemosConnection(
  rawUrl,
  token = "",
  fetchImpl = globalThis.fetch,
  locale = "zh-CN"
) {
  const i18n = globalThis.CodingRewindI18n;
  const resolvedLocale = i18n.resolveLocale(locale);
  const normalized = normalizeMemosBaseUrl(rawUrl);
  if (!normalized) {
    return { ok: false, message: i18n.t(resolvedLocale, "connInvalidUrl") };
  }
  const headers = buildAuthHeaders(token, { includeJsonContentType: false });
  try {
    const resp = await fetchImpl(`${normalized}/api/memos?pageSize=1`, {
      method: "GET",
      headers
    });
    if (!resp.ok) {
      return {
        ok: false,
        status: resp.status,
        message: i18n.t(resolvedLocale, "connHttpFailed", { status: resp.status })
      };
    }
    await resp.json();
    return { ok: true, message: i18n.t(resolvedLocale, "connSuccessReadOnly") };
  } catch (err) {
    return {
      ok: false,
      message: i18n.t(resolvedLocale, "connNetworkError", { error: err?.message || String(err) })
    };
  }
}

export async function testMemosConnection({
  baseUrl,
  token = "",
  fetchImpl = globalThis.fetch,
  locale = "zh-CN"
} = {}) {
  return probeMemosConnection(baseUrl, token, fetchImpl, locale);
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

function detectBrowserLanguage() {
  return globalThis.CodingRewindI18n.detectBrowserLanguage();
}

function normalizeUiLanguagePreference(value) {
  if (value === "zh-CN" || value === "en" || value === "auto") {
    return value;
  }
  return "auto";
}

export function initOptionsPage() {
  if (typeof document === "undefined") return;
  const i18n = globalThis.CodingRewindI18n;
  const formEl = document.getElementById("settings-form");
  const urlInput = document.getElementById("memos-url");
  const tokenInput = document.getElementById("memos-token");
  const pillCheckbox = document.getElementById("show-pill");
  const languageSelect = document.getElementById("ui-language");
  const testBtn = document.getElementById("test-btn");
  const flushBtn = document.getElementById("flush-btn");
  const statusEl = document.getElementById("status");
  const outboxCountEl = document.getElementById("outbox-count");
  if (!formEl) return;

  let preferredLanguage = "auto";
  let currentLocale = i18n.resolveLocale(preferredLanguage, detectBrowserLanguage());
  let currentOutbox = [];
  let statusMessageFactory = null;
  let statusKind = "info";

  function renderStatus() {
    if (!statusMessageFactory) {
      statusEl.textContent = "";
      return;
    }
    statusEl.textContent = statusMessageFactory(currentLocale);
    statusEl.setAttribute("data-kind", statusKind);
  }

  function setStatusKey(key, params = undefined, kind = "info") {
    statusMessageFactory = (loc) => i18n.t(loc, key, params);
    statusKind = kind;
    renderStatus();
  }

  function setStatusText(text, kind = "info") {
    statusMessageFactory = () => text;
    statusKind = kind;
    renderStatus();
  }

  function renderOutboxCount(outbox) {
    currentOutbox = Array.isArray(outbox) ? outbox : [];
    const count = currentOutbox.length;
    outboxCountEl.textContent = i18n.t(currentLocale, "outboxCount", { count });
    flushBtn.hidden = count === 0;
  }

  function applyLanguagePreference(nextPref) {
    preferredLanguage = normalizeUiLanguagePreference(nextPref);
    if (languageSelect) {
      languageSelect.value = preferredLanguage;
    }
    currentLocale = i18n.resolveLocale(preferredLanguage, detectBrowserLanguage());
    if (document.documentElement) {
      document.documentElement.lang = currentLocale;
    }
    document.title = i18n.t(currentLocale, "optionsPageTitle");

    for (const node of document.querySelectorAll("[data-i18n]")) {
      const key = node.getAttribute("data-i18n");
      if (key) node.textContent = i18n.t(currentLocale, key);
    }
    for (const node of document.querySelectorAll("[data-i18n-placeholder]")) {
      const key = node.getAttribute("data-i18n-placeholder");
      if (key) {
        const translated = i18n.t(currentLocale, key);
        node.placeholder = translated;
        node.setAttribute("placeholder", translated);
      }
    }
    if (testBtn) {
      testBtn.textContent = i18n.t(currentLocale, "testConnectionBtn");
    }
    renderOutboxCount(currentOutbox);
    renderStatus();
  }

  applyLanguagePreference("auto");

  async function loadInitialState() {
    if (typeof chrome === "undefined" || !chrome.storage?.local) return;
    const items = await chrome.storage.local.get([
      "memosUrl",
      "memosToken",
      "showSelectionPill",
      "uiLanguage",
      "outbox"
    ]);
    if (typeof items.memosUrl === "string") urlInput.value = items.memosUrl;
    if (typeof items.memosToken === "string") tokenInput.value = items.memosToken;
    pillCheckbox.checked = items.showSelectionPill !== false;
    currentOutbox = Array.isArray(items.outbox) ? items.outbox : [];
    applyLanguagePreference(items.uiLanguage);
  }

  void loadInitialState();

  languageSelect?.addEventListener("change", async () => {
    const nextPref = normalizeUiLanguagePreference(languageSelect.value);
    applyLanguagePreference(nextPref);
    await chrome.storage?.local?.set?.({ uiLanguage: nextPref });
  });

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.outbox) {
      renderOutboxCount(changes.outbox.newValue);
    }
    if (changes.uiLanguage) {
      const incoming = normalizeUiLanguagePreference(changes.uiLanguage.newValue);
      if (incoming !== preferredLanguage) {
        applyLanguagePreference(incoming);
      }
    }
  });

  async function resolveAuthorizedBaseUrl() {
    const normalized = normalizeMemosBaseUrl(urlInput.value);
    if (!normalized) {
      setStatusKey("statusInvalidProtocolUrl", undefined, "error");
      return "";
    }
    const granted = await requestOriginPermission(normalized);
    if (!granted) {
      setStatusKey("statusOriginPermissionDenied", undefined, "error");
      return "";
    }
    return normalized;
  }

  formEl.addEventListener("submit", async (event) => {
    event.preventDefault();
    const normalized = await resolveAuthorizedBaseUrl();
    if (!normalized) return;

    urlInput.value = normalized;
    const selectedUiLang = languageSelect
      ? normalizeUiLanguagePreference(languageSelect.value)
      : preferredLanguage;
    await chrome.storage.local.set({
      memosUrl: normalized,
      memosToken: tokenInput.value.trim(),
      showSelectionPill: pillCheckbox.checked,
      uiLanguage: selectedUiLang
    });
    setStatusKey("statusSettingsSaved", undefined, "ok");
    chrome.runtime?.sendMessage?.({ type: "REWIND_FLUSH_OUTBOX" });
  });

  testBtn?.addEventListener("click", async () => {
    const normalized = await resolveAuthorizedBaseUrl();
    if (!normalized) return;
    setStatusKey("statusTestingConnection", undefined, "info");
    const res = await probeMemosConnection(
      normalized,
      tokenInput.value.trim(),
      globalThis.fetch,
      currentLocale
    );
    setStatusText(res.message, res.ok ? "ok" : "error");
  });

  flushBtn?.addEventListener("click", async () => {
    setStatusKey("statusSyncingClips", undefined, "info");
    const resp = await chrome.runtime.sendMessage({ type: "REWIND_FLUSH_OUTBOX" });
    if (resp && resp.ok) {
      setStatusKey(
        "statusSyncSummary",
        { flushed: resp.flushed, remaining: resp.remaining },
        resp.remaining === 0 ? "ok" : "info"
      );
    } else {
      setStatusKey("statusSyncFailed", undefined, "error");
    }
  });
}

initOptionsPage();

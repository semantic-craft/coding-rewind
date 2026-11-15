// SPDX-License-Identifier: MIT

import "./i18n.js";
import { buildAuthHeaders, normalizeMemosBaseUrl } from "./memos_payload.mjs";

export const DEFAULT_EXCLUDED_DOMAINS = Object.freeze([
  "docs.google.com",
  "sheets.google.com",
  "slides.google.com",
  "figma.com",
  "canva.com"
]);

export function resolvePillScope(items = {}) {
  if (!items || typeof items !== "object") return "all";
  const scope = items.selectionPillScope;
  if (scope === "all" || scope === "chat" || scope === "off") {
    return scope;
  }
  if (items.showSelectionPill === false) return "off";
  return "all";
}

export function normalizeDomainEntry(raw) {
  let s = String(raw || "").replace(/[\u0000-\u001f\u007f]+/g, "").trim().toLowerCase();
  if (!s || /\s/.test(s)) return "";
  s = s.replace(/^([a-z][a-z0-9+.-]*:\/\/)\*\./, "$1").replace(/^\*\./, "").replace(/^\.+/, "");
  if (!s) return "";
  try {
    let candidate = s;
    if (!/^[a-z][a-z0-9+.-]*:\/\//.test(candidate)) {
      const authority = candidate.split("/")[0].split("?")[0].split("#")[0];
      if (!authority) return "";
      const colonCount = (authority.match(/:/g) || []).length;
      candidate = colonCount >= 2 && !authority.startsWith("[")
        ? `https://[${authority}]`
        : `https://${authority}`;
    }
    const host = new URL(candidate).hostname.toLowerCase().replace(/\.+$/, "");
    return host || "";
  } catch {
    return "";
  }
}

export function parseExcludedDomains(rawInput) {
  const tokens = Array.isArray(rawInput)
    ? rawInput
    : typeof rawInput === "string"
      ? rawInput.split(/[\r\n,;]+/)
      : [];

  const seen = new Set();
  const result = [];
  for (const token of tokens) {
    const entry = normalizeDomainEntry(token);
    if (!entry || seen.has(entry)) continue;
    seen.add(entry);
    result.push(entry);
  }
  return result;
}

export async function testMemosConnection({
  baseUrl,
  token = "",
  fetchImpl = globalThis.fetch,
  locale = "zh-CN"
} = {}) {
  const i18n = globalThis.CodingRewindI18n;
  const resolvedLocale = i18n ? i18n.resolveLocale(locale) : (locale === "en" ? "en" : "zh-CN");
  const normalized = normalizeMemosBaseUrl(baseUrl);
  if (!normalized) {
    const msg = i18n ? i18n.t(resolvedLocale, "connInvalidUrl") : "请输入有效的 Memos 服务地址";
    return { ok: false, message: msg };
  }
  const headers = buildAuthHeaders(token, { includeJsonContentType: false });
  try {
    const resp = await fetchImpl(`${normalized}/api/memos?pageSize=1`, {
      method: "GET",
      headers
    });
    if (!resp.ok) {
      const msg = i18n
        ? i18n.t(resolvedLocale, "connHttpFailed", { status: resp.status })
        : `连接失败 (HTTP ${resp.status})`;
      return { ok: false, status: resp.status, message: msg };
    }
    await resp.json();
    const msg = i18n
      ? i18n.t(resolvedLocale, "connSuccessReadOnly")
      : "连接成功，可读取片段。尚未验证保存。";
    return { ok: true, message: msg };
  } catch (err) {
    const errMsg = err?.message || String(err);
    const msg = i18n
      ? i18n.t(resolvedLocale, "connNetworkError", { error: errMsg })
      : `网络请求失败：${errMsg}`;
    return { ok: false, message: msg };
  }
}

async function requestOriginPermission(normalizedUrl) {
  if (typeof chrome === "undefined" || !chrome.permissions) return true;
  try {
    const originPattern = `${new URL(normalizedUrl).origin}/*`;
    if (typeof chrome.permissions.contains === "function") {
      const alreadyGranted = await chrome.permissions.contains({ origins: [originPattern] });
      if (alreadyGranted) return true;
    }
    if (typeof chrome.permissions.request === "function") {
      return await chrome.permissions.request({ origins: [originPattern] });
    }
    return true;
  } catch {
    return false;
  }
}

function detectBrowserLanguage() {
  return globalThis.CodingRewindI18n?.detectBrowserLanguage?.();
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
  const urlInput = document.getElementById("memos-url") || document.getElementById("base-url");
  const tokenInput = document.getElementById("memos-token") || document.getElementById("token");
  const pillScopeSelect = document.getElementById("pill-scope");
  const excludedDomainsInput = document.getElementById("excluded-domains");
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

    const i18nNodes = typeof document.querySelectorAll === "function" ? document.querySelectorAll("[data-i18n]") : [];
    for (const node of i18nNodes) {
      const key = node.getAttribute("data-i18n");
      if (key) node.textContent = i18n.t(currentLocale, key);
    }
    const placeholderNodes = typeof document.querySelectorAll === "function" ? document.querySelectorAll("[data-i18n-placeholder]") : [];
    for (const node of placeholderNodes) {
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
      "selectionPillScope",
      "showSelectionPill",
      "excludedDomains",
      "uiLanguage",
      "outbox"
    ]);
    if (typeof items.memosUrl === "string") urlInput.value = items.memosUrl;
    if (typeof items.memosToken === "string") tokenInput.value = items.memosToken;
    if (pillScopeSelect) {
      pillScopeSelect.value = resolvePillScope(items);
    }
    if (excludedDomainsInput) {
      const domains = Array.isArray(items.excludedDomains)
        ? items.excludedDomains
        : DEFAULT_EXCLUDED_DOMAINS;
      excludedDomainsInput.value = domains.join("\n");
    }
    currentOutbox = Array.isArray(items.outbox) ? items.outbox : [];
    applyLanguagePreference(items.uiLanguage);
  }

  void loadInitialState();

  languageSelect?.addEventListener("change", async () => {
    const nextPref = normalizeUiLanguagePreference(languageSelect.value);
    applyLanguagePreference(nextPref);
    await chrome.storage?.local?.set?.({ uiLanguage: nextPref });
  });

  pillScopeSelect?.addEventListener("change", async () => {
    const scope = resolvePillScope({ selectionPillScope: pillScopeSelect.value });
    await chrome.storage?.local?.set?.({ selectionPillScope: scope });
    await chrome.storage?.local?.remove?.(["showSelectionPill"]);
  });

  excludedDomainsInput?.addEventListener("change", async () => {
    const excludedDomains = parseExcludedDomains(excludedDomainsInput.value);
    excludedDomainsInput.value = excludedDomains.join("\n");
    await chrome.storage?.local?.set?.({ excludedDomains });
  });

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area !== "local" || !changes) return;
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
    const scope = pillScopeSelect
      ? resolvePillScope({ selectionPillScope: pillScopeSelect.value })
      : "all";
    const excludedDomains = excludedDomainsInput
      ? parseExcludedDomains(excludedDomainsInput.value)
      : DEFAULT_EXCLUDED_DOMAINS.slice();
    if (excludedDomainsInput) {
      excludedDomainsInput.value = excludedDomains.join("\n");
    }
    const selectedUiLang = languageSelect
      ? normalizeUiLanguagePreference(languageSelect.value)
      : preferredLanguage;

    await chrome.storage?.local?.set?.({
      selectionPillScope: scope,
      excludedDomains,
      uiLanguage: selectedUiLang
    });
    await chrome.storage?.local?.remove?.(["showSelectionPill"]);

    if (!urlInput.value.trim()) {
      urlInput.value = "";
      await chrome.storage?.local?.set?.({
        memosUrl: "",
        memosToken: tokenInput.value.trim()
      });
      setStatusKey("statusSettingsSaved", undefined, "ok");
      return;
    }

    const normalized = await resolveAuthorizedBaseUrl();
    if (!normalized) return;

    urlInput.value = normalized;
    await chrome.storage?.local?.set?.({
      memosUrl: normalized,
      memosToken: tokenInput.value.trim()
    });
    setStatusKey("statusSettingsSaved", undefined, "ok");
    chrome.runtime?.sendMessage?.({ type: "REWIND_FLUSH_OUTBOX" });
  });

  testBtn?.addEventListener("click", async () => {
    const normalized = await resolveAuthorizedBaseUrl();
    if (!normalized) return;
    setStatusKey("statusTestingConnection", undefined, "info");
    const res = await testMemosConnection({
      baseUrl: normalized,
      token: tokenInput.value.trim(),
      locale: currentLocale
    });
    setStatusText(res.message, res.ok ? "ok" : "error");
  });

  flushBtn?.addEventListener("click", async () => {
    setStatusKey("statusSyncingClips", undefined, "info");
    const resp = await chrome.runtime?.sendMessage?.({ type: "REWIND_FLUSH_OUTBOX" });
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

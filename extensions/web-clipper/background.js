// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed background dispatch patterns in mem0ai/mem0-chrome-extension.

import "./i18n.js";
import { buildFallbackClip, isPageReadingURL } from "./extractors.mjs";
import { buildMemosWirePayloads, flushOutbox, saveClipWithOutbox } from "./memos_payload.mjs";

const SELECTION_MENU_ID = "save-to-coding-rewind";
const PAGE_LINK_MENU_ID = "save-page-link-to-coding-rewind";
const PAGE_READING_MENU_ID = "save-page-reading-to-coding-rewind";
const WEB_PAGE_PATTERNS = ["http://*/*", "https://*/*"];
const CONTEXT_MENUS = [
  { id: SELECTION_MENU_ID, label: "contextMenuSaveSelection", contexts: ["selection"] },
  { id: PAGE_LINK_MENU_ID, label: "contextMenuSavePageLink", contexts: ["page"],
    documentUrlPatterns: WEB_PAGE_PATTERNS },
  { id: PAGE_READING_MENU_ID, label: "contextMenuSavePageReading", contexts: ["page"],
    documentUrlPatterns: WEB_PAGE_PATTERNS }
];
const OUTBOX_ALARM_NAME = "rewind-outbox-flush";
const i18n = globalThis.CodingRewindI18n;

let serialQueue = Promise.resolve();
let menuSetupChain = Promise.resolve();
let menuSetupInFlight = 0;
let cachedUiLanguage = "auto";

function runSerialized(task) {
  const next = serialQueue.then(task, task);
  serialQueue = next.catch(() => {});
  return next;
}

function enqueueMenuSetup(task) {
  menuSetupInFlight += 1;
  const wrapped = async () => {
    try {
      return await task();
    } finally {
      menuSetupInFlight -= 1;
    }
  };
  const next = menuSetupChain.then(wrapped, wrapped);
  menuSetupChain = next.catch(() => {});
  return next;
}

function resolveExtensionLocale(preferredLanguage = cachedUiLanguage) {
  return i18n.resolveLocale(preferredLanguage, i18n.detectBrowserLanguage());
}

const chromeOutboxStorage = {
  async getOutbox() {
    const data = await chrome.storage.local.get(["outbox"]);
    return Array.isArray(data.outbox) ? data.outbox : [];
  },
  async setOutbox(items) {
    await chrome.storage.local.set({ outbox: items });
  }
};

async function getMemosSettings() {
  const data = await chrome.storage.local.get(["memosUrl", "memosToken", "uiLanguage"]);
  if (typeof data?.uiLanguage === "string") {
    cachedUiLanguage = data.uiLanguage;
  }
  return {
    baseUrl: typeof data?.memosUrl === "string" ? data.memosUrl : "",
    token: typeof data?.memosToken === "string" ? data.memosToken : "",
    locale: resolveExtensionLocale(cachedUiLanguage)
  };
}

function setupMenusAndAlarms() {
  return enqueueMenuSetup(async () => {
    try {
      const data = await chrome.storage?.local?.get?.(["uiLanguage"]);
      if (typeof data?.uiLanguage === "string") {
        cachedUiLanguage = data.uiLanguage;
      }
    } catch {}
    await new Promise((resolve) => {
      if (typeof chrome.contextMenus?.removeAll !== "function") {
        resolve();
        return;
      }
      chrome.contextMenus.removeAll(() => {
        void chrome.runtime?.lastError;
        const locale = resolveExtensionLocale(cachedUiLanguage);
        for (const { label, ...menu } of CONTEXT_MENUS) {
          chrome.contextMenus?.create?.({ ...menu, title: i18n.t(locale, label) }, () => {
            void chrome.runtime?.lastError;
          });
        }
        resolve();
      });
    });
    if (chrome.alarms) {
      chrome.alarms.create(OUTBOX_ALARM_NAME, { periodInMinutes: 5 });
    }
  });
}

async function sendCaptureRequest(tabId, message, options) {
  try {
    return await chrome.tabs.sendMessage(tabId, message, options);
  } catch {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["i18n.js", "content.js"]
    });
    return chrome.tabs.sendMessage(tabId, message, options);
  }
}

export async function injectContentScriptIntoOpenTabs({
  tabsApi = typeof chrome !== "undefined" ? chrome?.tabs : undefined,
  scriptingApi = typeof chrome !== "undefined" ? chrome?.scripting : undefined
} = {}) {
  if (typeof tabsApi?.query !== "function" || typeof scriptingApi?.executeScript !== "function") {
    return { attempted: 0, injected: 0 };
  }
  let tabs = [];
  try {
    const queried = await tabsApi.query({ url: ["https://*/*", "http://*/*"] });
    if (Array.isArray(queried)) tabs = queried;
  } catch {
    return { attempted: 0, injected: 0 };
  }
  let attempted = 0;
  let injected = 0;
  await Promise.all(
    tabs.map(async (tab) => {
      if (!tab || typeof tab.id !== "number") return;
      attempted += 1;
      await scriptingApi
        .executeScript({ target: { tabId: tab.id }, files: ["i18n.js", "content.js"] })
        .then(() => {
          injected += 1;
        })
        .catch(() => {});
    })
  );
  return { attempted, injected };
}

async function notifyTabToast(tabId, result) {
  if (!tabId || !result || !result.toast) return;
  try {
    await chrome.tabs.sendMessage(tabId, {
      type: "REWIND_SHOW_TOAST",
      toast: result.toast,
      status: result.status
    });
  } catch {}
}

async function processClipSave(clip) {
  try {
    return await runSerialized(async () => {
      const { baseUrl, token, locale } = await getMemosSettings();
      return saveClipWithOutbox({
        clip,
        baseUrl,
        token,
        storage: chromeOutboxStorage,
        locale
      });
    });
  } catch {
    const locale = resolveExtensionLocale(cachedUiLanguage);
    return {
      status: "error",
      queued: false,
      toast: i18n.t(locale, "toastSaveUnconfirmedError")
    };
  }
}

async function triggerFlushOutbox() {
  return runSerialized(async () => {
    const { baseUrl, token } = await getMemosSettings();
    return flushOutbox({
      baseUrl,
      token,
      storage: chromeOutboxStorage
    });
  });
}

async function handleTabSelectionCapture(tab, fallbackSelectionText = "") {
  if (!tab || !tab.id) return;
  let clip = null;
  let blocked = false;
  try {
    const extracted = await sendCaptureRequest(tab.id, { type: "REWIND_EXTRACT_SELECTION" });
    blocked = extracted?.blocked === true;
    clip = blocked ? null : extracted?.clip || null;
  } catch {
    clip = null;
  }

  if (blocked) return;

  if (!clip && fallbackSelectionText && fallbackSelectionText.trim()) {
    clip = buildFallbackClip({
      selectedMarkdown: fallbackSelectionText,
      sourceUrl: tab.url || "",
      title: tab.title || ""
    });
  }

  if (!clip || !clip.selectedMarkdown) return;
  const result = await processClipSave(clip);
  await notifyTabToast(tab.id, result);
}

async function handlePageLinkCapture(pageUrl, tab) {
  if (!tab?.id || !pageUrl) return;
  let url;
  try {
    url = new URL(pageUrl);
  } catch {
    return;
  }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return;
  const clip = buildFallbackClip({
    selectedMarkdown: pageUrl,
    sourceUrl: pageUrl,
    title: (tab.url === pageUrl && tab.title) || url.hostname
  });
  const result = await processClipSave(clip);
  await notifyTabToast(tab.id, result);
}

async function handlePageReadingCapture(info, tab) {
  if (!tab?.id) return;
  const feedback = (key) => notifyTabToast(tab.id, {
    status: "error",
    toast: i18n.t(resolveExtensionLocale(), key)
  });
  const pageUrl = info.pageUrl;
  if (tab.incognito || info.editable || (info.frameId ?? 0) !== 0 || !isPageReadingURL(pageUrl)) {
    await feedback("toastPageReadingUnavailable");
    return;
  }
  try {
    const { excludedDomains } = await chrome.storage.local.get(["excludedDomains"]);
    const result = await sendCaptureRequest(tab.id, {
      type: "REWIND_EXTRACT_PAGE_READING",
      pageUrl,
      excludedDomains
    }, { frameId: 0 });
    if (result?.clip?.sourceUrl !== pageUrl || !result.clip.selectedMarkdown) {
      await feedback("toastPageReadingUnavailable");
      return;
    }
    const { memoBody } = buildMemosWirePayloads(result.clip);
    if (new TextEncoder().encode(memoBody.content).byteLength > 8192) {
      await feedback("toastPageReadingTooLarge");
      return;
    }
    const saved = await processClipSave(result.clip);
    if (result.truncated && saved.status !== "error") {
      saved.toast += i18n.t(resolveExtensionLocale(), "toastPageReadingTruncated");
    }
    await notifyTabToast(tab.id, saved);
  } catch {
    await feedback("toastSaveRetryError");
  }
}

if (typeof chrome !== "undefined" && chrome.runtime) {
  chrome.runtime.onInstalled.addListener(() => {
    void setupMenusAndAlarms();
    void injectContentScriptIntoOpenTabs();
    void triggerFlushOutbox();
  });

  chrome.runtime.onStartup.addListener(() => {
    void setupMenusAndAlarms();
    void triggerFlushOutbox();
  });

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area === "local" && changes.uiLanguage) {
      cachedUiLanguage =
        typeof changes.uiLanguage.newValue === "string" ? changes.uiLanguage.newValue : "auto";
      const applyMenuTitleUpdate = () => {
        const locale = resolveExtensionLocale(cachedUiLanguage);
        for (const { id, label } of CONTEXT_MENUS) {
          chrome.contextMenus?.update?.(id, { title: i18n.t(locale, label) }, () => {
            void chrome.runtime?.lastError;
          });
        }
      };
      if (menuSetupInFlight > 0) {
        void enqueueMenuSetup(async () => {
          applyMenuTitleUpdate();
        });
      } else {
        applyMenuTitleUpdate();
      }
    }
  });

  chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === SELECTION_MENU_ID) {
      void handleTabSelectionCapture(tab, info.selectionText || "");
    } else if (info.menuItemId === PAGE_LINK_MENU_ID) {
      void handlePageLinkCapture(info.pageUrl, tab);
    } else if (info.menuItemId === PAGE_READING_MENU_ID) {
      void handlePageReadingCapture(info, tab);
    }
  });

  chrome.commands.onCommand.addListener(async (command) => {
    if (command !== "save-selection") return;
    const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (activeTab) {
      await handleTabSelectionCapture(activeTab);
    }
  });

  chrome.action?.onClicked?.addListener(() => {
    chrome.runtime.openOptionsPage();
  });

  chrome.alarms?.onAlarm?.addListener((alarm) => {
    if (alarm && alarm.name === OUTBOX_ALARM_NAME) {
      void triggerFlushOutbox();
    }
  });

  self.addEventListener?.("online", () => {
    void triggerFlushOutbox();
  });

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg !== "object") return false;
    if (chrome.runtime?.id && (!_sender || _sender.id !== chrome.runtime.id)) {
      return false;
    }
    if (msg.type === "REWIND_SAVE_CLIP" && msg.clip) {
      processClipSave(msg.clip)
        .then((res) => sendResponse(res));
      return true;
    }
    if (msg.type === "REWIND_FLUSH_OUTBOX") {
      triggerFlushOutbox()
        .then((res) => sendResponse({ ok: true, ...res }))
        .catch((err) => sendResponse({ ok: false, error: String(err) }));
      return true;
    }
    return false;
  });
}

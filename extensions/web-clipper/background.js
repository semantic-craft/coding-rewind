// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed background dispatch patterns in mem0ai/mem0-chrome-extension.

import "./i18n.js";
import { buildFallbackClip } from "./extractors.mjs";
import { flushOutbox, saveClipWithOutbox } from "./memos_payload.mjs";

const CONTEXT_MENU_ID = "save-to-coding-rewind";
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
        chrome.contextMenus?.create?.(
          {
            id: CONTEXT_MENU_ID,
            title: i18n.t(locale, "contextMenuSaveSelection"),
            contexts: ["selection"]
          },
          () => {
            void chrome.runtime?.lastError;
          }
        );
        resolve();
      });
    });
    if (chrome.alarms) {
      chrome.alarms.create(OUTBOX_ALARM_NAME, { periodInMinutes: 5 });
    }
  });
}

async function ensureContentScriptAndExtract(tabId) {
  try {
    const resp = await chrome.tabs.sendMessage(tabId, { type: "REWIND_EXTRACT_SELECTION" });
    if (resp && resp.clip) return resp.clip;
  } catch {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["i18n.js", "content.js"]
    });
    const retryResp = await chrome.tabs.sendMessage(tabId, { type: "REWIND_EXTRACT_SELECTION" });
    if (retryResp && retryResp.clip) return retryResp.clip;
  }
  return null;
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
  try {
    clip = await ensureContentScriptAndExtract(tab.id);
  } catch {
    clip = null;
  }

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

if (typeof chrome !== "undefined" && chrome.runtime) {
  chrome.runtime.onInstalled.addListener(() => {
    void setupMenusAndAlarms();
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
        chrome.contextMenus?.update?.(
          CONTEXT_MENU_ID,
          { title: i18n.t(locale, "contextMenuSaveSelection") },
          () => {
            void chrome.runtime?.lastError;
          }
        );
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
    if (info.menuItemId === CONTEXT_MENU_ID) {
      void handleTabSelectionCapture(tab, info.selectionText || "");
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

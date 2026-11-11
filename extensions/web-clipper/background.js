// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed background dispatch patterns in mem0ai/mem0-chrome-extension.

import { detectPlatform, cleanSessionTitle } from "./extractors.mjs";
import { flushOutbox, saveClipWithOutbox } from "./memos_payload.mjs";

const CONTEXT_MENU_ID = "save-to-coding-rewind";
const OUTBOX_ALARM_NAME = "rewind-outbox-flush";

let serialQueue = Promise.resolve();

function runSerialized(task) {
  const next = serialQueue.then(task, task);
  serialQueue = next.catch(() => {});
  return next;
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
  const data = await chrome.storage.local.get(["memosUrl", "memosToken"]);
  return {
    baseUrl: typeof data.memosUrl === "string" ? data.memosUrl : "",
    token: typeof data.memosToken === "string" ? data.memosToken : ""
  };
}

function setupMenusAndAlarms() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: CONTEXT_MENU_ID,
      title: "Save to Coding Rewind",
      contexts: ["selection"]
    });
  });
  if (chrome.alarms) {
    chrome.alarms.create(OUTBOX_ALARM_NAME, { periodInMinutes: 5 });
  }
}

async function ensureContentScriptAndExtract(tabId) {
  try {
    const resp = await chrome.tabs.sendMessage(tabId, { type: "REWIND_EXTRACT_SELECTION" });
    if (resp && resp.clip) return resp.clip;
  } catch {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["content.js"]
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
  return runSerialized(async () => {
    const { baseUrl, token } = await getMemosSettings();
    return saveClipWithOutbox({
      clip,
      baseUrl,
      token,
      storage: chromeOutboxStorage
    });
  });
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
    const sourceUrl = tab.url || "";
    clip = {
      selectedMarkdown: fallbackSelectionText.trim(),
      sourcePlatform: detectPlatform(sourceUrl),
      sessionTitle: cleanSessionTitle(tab.title || ""),
      prompt: "",
      recentTurns: "",
      sourceUrl
    };
  }

  if (!clip || !clip.selectedMarkdown) return;
  const result = await processClipSave(clip);
  await notifyTabToast(tab.id, result);
}

if (typeof chrome !== "undefined" && chrome.runtime) {
  chrome.runtime.onInstalled.addListener(() => {
    setupMenusAndAlarms();
    void triggerFlushOutbox();
  });

  chrome.runtime.onStartup.addListener(() => {
    setupMenusAndAlarms();
    void triggerFlushOutbox();
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
        .then((res) => sendResponse(res))
        .catch(() => sendResponse({ status: "queued", toast: "离线已暂存队列" }));
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

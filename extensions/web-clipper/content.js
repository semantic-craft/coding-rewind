// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed UX patterns in mem0ai/mem0-chrome-extension.

(() => {
  if (globalThis.__CODING_REWIND_CONTENT_READY__) return;
  globalThis.__CODING_REWIND_CONTENT_READY__ = true;

  const TOAST_DURATION_MS = 2200;
  let extractorsModulePromise = null;
  let shadowRootRef = null;
  let toastEl = null;
  let toastDotEl = null;
  let toastTextEl = null;
  let pillEl = null;
  let toastTimer = null;
  let showSelectionPill = true;
  let lastTriggerAt = 0;

  function loadExtractors() {
    if (!extractorsModulePromise) {
      extractorsModulePromise = import(chrome.runtime.getURL("extractors.mjs"));
    }
    return extractorsModulePromise;
  }

  function ensureUiRoot() {
    if (shadowRootRef && shadowRootRef.host && shadowRootRef.host.isConnected) {
      return shadowRootRef;
    }
    const host = document.createElement("div");
    host.setAttribute("data-coding-rewind-ui", "1");
    host.style.cssText =
      "position:fixed;inset:0;pointer-events:none;z-index:2147483647;user-select:none;-webkit-user-select:none;";
    const shadow = host.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = `
      .rw-toast {
        position: fixed;
        top: 18px;
        right: 18px;
        display: inline-flex;
        align-items: center;
        gap: 8px;
        max-width: 360px;
        padding: 9px 14px;
        border-radius: 999px;
        background: rgba(20, 22, 26, 0.88);
        color: #f5f7fa;
        border: 1px solid rgba(255, 255, 255, 0.14);
        box-shadow: 0 10px 28px rgba(0, 0, 0, 0.28);
        backdrop-filter: blur(14px);
        -webkit-backdrop-filter: blur(14px);
        font: 500 12.5px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        letter-spacing: 0.01em;
        pointer-events: none;
        opacity: 0;
        transform: translateY(-6px) scale(0.98);
        transition: opacity 150ms ease, transform 150ms ease;
      }
      .rw-toast[data-visible="true"] {
        opacity: 1;
        transform: translateY(0) scale(1);
      }
      .rw-dot {
        width: 7px;
        height: 7px;
        border-radius: 50%;
        flex: 0 0 auto;
        background: #34c759;
      }
      .rw-dot[data-variant="queued"] {
        background: #ff9f0a;
      }
      .rw-dot[data-variant="unconfigured"],
      .rw-dot[data-variant="error"] {
        background: #ff453a;
      }
      .rw-pill {
        position: fixed;
        display: none;
        align-items: center;
        gap: 5px;
        padding: 4px 10px;
        border-radius: 999px;
        background: rgba(24, 26, 31, 0.92);
        color: #f5f7fa;
        border: 1px solid rgba(255, 255, 255, 0.16);
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.24);
        backdrop-filter: blur(10px);
        -webkit-backdrop-filter: blur(10px);
        font: 500 11.5px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        cursor: pointer;
        pointer-events: auto;
        user-select: none;
      }
      .rw-pill:hover {
        background: rgba(38, 42, 50, 0.96);
      }
    `;

    toastEl = document.createElement("div");
    toastEl.className = "rw-toast";
    toastEl.setAttribute("role", "status");
    toastEl.setAttribute("aria-live", "polite");

    toastDotEl = document.createElement("span");
    toastDotEl.className = "rw-dot";
    toastTextEl = document.createElement("span");
    toastEl.append(toastDotEl, toastTextEl);

    pillEl = document.createElement("button");
    pillEl.type = "button";
    pillEl.className = "rw-pill";
    pillEl.tabIndex = -1;
    pillEl.textContent = "存入 Rewind";
    pillEl.addEventListener("mousedown", (event) => {
      event.preventDefault();
      event.stopPropagation();
      hidePill();
      void captureAndSendCurrentSelection();
    });

    shadow.append(style, toastEl, pillEl);
    (document.documentElement || document.body).appendChild(host);
    shadowRootRef = shadow;
    return shadow;
  }

  function showToast(message, variant = "saved") {
    if (!message) return;
    ensureUiRoot();
    toastDotEl.setAttribute("data-variant", variant);
    toastTextEl.textContent = message;
    toastEl.setAttribute("data-visible", "true");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      if (toastEl) toastEl.setAttribute("data-visible", "false");
    }, TOAST_DURATION_MS);
  }

  function hidePill() {
    if (pillEl) {
      pillEl.style.display = "none";
    }
  }

  function isEditableNode(node) {
    let cur = node && node.nodeType === 1 ? node : node && node.parentElement;
    while (cur) {
      const tag = (cur.tagName || "").toLowerCase();
      if (tag === "input" || tag === "textarea" || cur.isContentEditable) return true;
      if (cur.getAttribute && cur.getAttribute("role") === "textbox") return true;
      cur = cur.parentElement;
    }
    return false;
  }

  async function extractCurrentSelection() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      return null;
    }
    const rawText = selection.toString() || "";
    if (!rawText.trim()) return null;

    const range = selection.getRangeAt(0);
    const { extractClipContext } = await loadExtractors();
    const clip = extractClipContext({
      doc: document,
      selection,
      selectionRange: range,
      url: location.href
    });
    if (!clip.selectedMarkdown || !clip.selectedMarkdown.trim()) {
      clip.selectedMarkdown = rawText;
    }
    return clip;
  }

  async function captureAndSendCurrentSelection() {
    const now = Date.now();
    if (now - lastTriggerAt < 350) return;
    lastTriggerAt = now;

    const clip = await extractCurrentSelection();
    if (!clip || !clip.selectedMarkdown) return;

    try {
      const resp = await chrome.runtime.sendMessage({
        type: "REWIND_SAVE_CLIP",
        clip
      });
      if (resp && resp.toast) {
        showToast(resp.toast, resp.status || "saved");
      }
    } catch {
      showToast("保存失败，请重试", "error");
    }
  }

  function updatePillPosition() {
    if (!showSelectionPill) {
      hidePill();
      return;
    }
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      hidePill();
      return;
    }
    const text = selection.toString().trim();
    if (text.length < 2 || isEditableNode(selection.anchorNode) || isEditableNode(selection.focusNode)) {
      hidePill();
      return;
    }
    const range = selection.getRangeAt(0);
    const rect = range.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) {
      hidePill();
      return;
    }

    ensureUiRoot();
    const top = Math.max(8, rect.top - 34);
    const left = Math.min(window.innerWidth - 110, Math.max(8, rect.right - 44));
    pillEl.style.top = `${Math.round(top)}px`;
    pillEl.style.left = `${Math.round(left)}px`;
    pillEl.style.display = "inline-flex";
  }

  chrome.storage?.local?.get(["showSelectionPill"], (items) => {
    if (items && typeof items.showSelectionPill === "boolean") {
      showSelectionPill = items.showSelectionPill;
    }
  });

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area === "local" && changes.showSelectionPill) {
      showSelectionPill = changes.showSelectionPill.newValue !== false;
      if (!showSelectionPill) hidePill();
    }
  });

  document.addEventListener("mouseup", () => {
    setTimeout(updatePillPosition, 15);
  }, true);

  document.addEventListener("selectionchange", () => {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) hidePill();
  }, true);

  window.addEventListener("scroll", hidePill, { capture: true, passive: true });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      hidePill();
      return;
    }
    if (event.altKey && event.shiftKey && !event.metaKey && !event.ctrlKey && event.code === "KeyS") {
      const sel = window.getSelection();
      if (sel && !sel.isCollapsed && sel.toString().trim()) {
        event.preventDefault();
        hidePill();
        void captureAndSendCurrentSelection();
      }
    }
  }, true);

  chrome.runtime?.onMessage?.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg !== "object") return false;
    if (msg.type === "REWIND_EXTRACT_SELECTION") {
      lastTriggerAt = Date.now();
      hidePill();
      extractCurrentSelection()
        .then((clip) => sendResponse({ clip }))
        .catch(() => sendResponse({ clip: null }));
      return true;
    }
    if (msg.type === "REWIND_SHOW_TOAST") {
      showToast(msg.toast, msg.status || "saved");
      sendResponse({ ok: true });
      return false;
    }
    return false;
  });
})();

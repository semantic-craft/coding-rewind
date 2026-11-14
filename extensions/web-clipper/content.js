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
      :host {
        color-scheme: light dark;
        --rw-surface: rgba(255, 255, 255, 0.97);
        --rw-text: #202124;
        --rw-border: #dfe3e8;
        --rw-accent: #0068d9;
        --rw-success: #16713b;
        --rw-warning: #9b5c06;
        --rw-error: #b52632;
      }
      @media (prefers-color-scheme: dark) {
        :host {
          --rw-surface: rgba(32, 33, 36, 0.97);
          --rw-text: #f2f3f4;
          --rw-border: #41454c;
          --rw-accent: #0a84ff;
          --rw-success: #7ddc9d;
          --rw-warning: #f4bd6d;
          --rw-error: #ff9199;
        }
      }
      .rw-toast {
        box-sizing: border-box;
        position: fixed;
        top: 18px;
        right: 18px;
        display: inline-flex;
        align-items: center;
        gap: 8px;
        max-width: min(360px, calc(100vw - 36px));
        padding: 10px 12px;
        border-radius: 9px;
        background: var(--rw-surface);
        color: var(--rw-text);
        border: 1px solid var(--rw-border);
        box-shadow: 0 3px 12px rgba(0, 0, 0, 0.09);
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        font: 500 12.5px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        overflow-wrap: anywhere;
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
        box-sizing: border-box;
        display: grid;
        place-items: center;
        width: 17px;
        height: 17px;
        border: 1.5px solid currentColor;
        border-radius: 50%;
        flex: 0 0 auto;
        color: var(--rw-success);
        font: 600 11px/1 -apple-system, BlinkMacSystemFont, sans-serif;
      }
      .rw-dot::before { content: "✓"; }
      .rw-dot[data-variant="queued"] {
        position: relative;
        color: var(--rw-warning);
      }
      .rw-dot[data-variant="queued"]::before {
        content: "";
        position: absolute;
        top: 3px;
        left: 6px;
        width: 3px;
        height: 5px;
        border-left: 1.5px solid currentColor;
        border-bottom: 1.5px solid currentColor;
      }
      .rw-dot[data-variant="unconfigured"] {
        border-radius: 4px;
        color: var(--rw-warning);
      }
      .rw-dot[data-variant="unconfigured"]::before { content: "!"; }
      .rw-dot[data-variant="error"] {
        color: var(--rw-error);
      }
      .rw-dot[data-variant="error"]::before { content: "×"; font-size: 14px; }
      .rw-pill {
        box-sizing: border-box;
        position: fixed;
        display: none;
        align-items: center;
        gap: 4px;
        height: 28px;
        padding: 4px 8px;
        border-radius: 7px;
        background: var(--rw-surface);
        color: var(--rw-accent);
        border: 1px solid var(--rw-border);
        box-shadow: 0 2px 6px rgba(0, 0, 0, 0.06);
        font: 500 11.5px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        cursor: pointer;
        pointer-events: auto;
        user-select: none;
        white-space: nowrap;
      }
      .rw-pill:hover { border-color: var(--rw-accent); }
      .rw-pill-plus { font: 400 16px/1 -apple-system, BlinkMacSystemFont, sans-serif; }
      @media (prefers-reduced-motion: reduce) {
        .rw-toast { transition: none; }
      }
    `;

    toastEl = document.createElement("div");
    toastEl.className = "rw-toast";
    toastEl.setAttribute("role", "status");
    toastEl.setAttribute("aria-live", "polite");

    toastDotEl = document.createElement("span");
    toastDotEl.className = "rw-dot";
    toastDotEl.setAttribute("aria-hidden", "true");
    toastTextEl = document.createElement("span");
    toastEl.append(toastDotEl, toastTextEl);

    pillEl = document.createElement("button");
    pillEl.type = "button";
    pillEl.className = "rw-pill";
    pillEl.tabIndex = -1;
    pillEl.textContent = "保存所选文本";
    const pillPlus = document.createElement("span");
    pillPlus.className = "rw-pill-plus";
    pillPlus.setAttribute("aria-hidden", "true");
    pillPlus.textContent = "+";
    pillEl.prepend(pillPlus);
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
    const range = selection.getRangeAt(0).cloneRange();
    const rawText = selection.toString() || "";
    if (!rawText.trim()) return null;
    const { extractClipContext } = await loadExtractors();
    const clip = extractClipContext({
      doc: document,
      selectionRange: range,
      selectedText: rawText,
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

// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed UX patterns in mem0ai/mem0-chrome-extension and GaimsDevSoftware/linuxpop.

(() => {
  if (globalThis.__CODING_REWIND_CONTENT_READY__) return;
  globalThis.__CODING_REWIND_CONTENT_READY__ = true;

  const TOAST_DURATION_MS = 2200;
  const PILL_HOLD_MS = 900;
  const IS_APPLE_PLATFORM = /Mac|iPhone|iPad|iPod/i.test(
    (globalThis.navigator && (navigator.platform || navigator.userAgent)) || ""
  );
  const CAPTURE_SHORTCUT_HINT = IS_APPLE_PLATFORM ? "⌃⌥⇧⌘S" : "Alt+Shift+S";
  const i18n = globalThis.CodingRewindI18n;
  const detectBrowserLanguage = i18n.detectBrowserLanguage;

  let extractorsModulePromise = null;
  let shadowRootRef = null;
  let toastEl = null;
  let toastDotEl = null;
  let toastTextEl = null;
  let pillEl = null;
  let pillIconEl = null;
  let pillLabelEl = null;
  let pillShortcutEl = null;
  let toastTimer = null;
  let pillHoldTimer = null;
  let pillState = "hidden";
  let lastAnchorRect = null;
  let showSelectionPill = true;
  let currentLocale = i18n.resolveLocale("auto", detectBrowserLanguage());
  let lastTriggerAt = 0;

  function isHyperCaptureShortcutEvent(event) {
    return Boolean(
      event &&
        !event.repeat &&
        event.code === "KeyS" &&
        event.ctrlKey &&
        event.altKey &&
        event.shiftKey &&
        event.metaKey
    );
  }

  function computePillPosition({ rect, pillWidth, pillHeight, viewportWidth, viewportHeight }) {
    const width = Number(pillWidth) || 0;
    const height = Number(pillHeight) || 0;
    const vw = Number(viewportWidth) || 0;
    const vh = Number(viewportHeight) || 0;
    const rectLeft = Number(rect?.left) || 0;
    const rectTop = Number(rect?.top) || 0;
    const rectWidth = Number(rect?.width) || 0;
    const rectBottom = typeof rect?.bottom === "number" ? rect.bottom : rectTop + (Number(rect?.height) || 0);

    const maxLeft = Math.max(8, vw - width - 8);
    const left = Math.round(Math.min(maxLeft, Math.max(8, rectLeft + rectWidth / 2 - width / 2)));

    let top = rectTop - height - 8;
    if (top < 8) {
      const maxTop = Math.max(8, vh - height - 8);
      top = Math.min(maxTop, rectBottom + 8);
    }
    return { left, top: Math.round(Math.max(8, top)) };
  }

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
        --rw-surface: rgba(255, 255, 255, 0.96);
        --rw-text: #202124;
        --rw-border: #dfe3e8;
        --rw-accent: #0068d9;
        --rw-success: #16713b;
        --rw-warning: #9b5c06;
        --rw-error: #b52632;
        --rw-pill-bg: #ffffff;
        --rw-pill-hover: #f6f6f7;
        --rw-pill-border: rgba(0, 0, 0, 0.075);
        --rw-pill-shortcut: rgba(0, 0, 0, 0.42);
      }
      @media (prefers-color-scheme: dark) {
        :host {
          --rw-surface: rgba(32, 33, 36, 0.96);
          --rw-text: #f2f3f4;
          --rw-border: #41454c;
          --rw-accent: #0a84ff;
          --rw-success: #7ddc9d;
          --rw-warning: #f4bd6d;
          --rw-error: #ff9199;
          --rw-pill-bg: #242428;
          --rw-pill-hover: #2f2f35;
          --rw-pill-border: rgba(255, 255, 255, 0.12);
          --rw-pill-shortcut: rgba(255, 255, 255, 0.46);
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
        gap: 5px;
        height: 26px;
        padding: 0 10px;
        border-radius: 999px;
        background: var(--rw-pill-bg);
        color: var(--rw-text);
        border: 1px solid var(--rw-pill-border);
        box-shadow: 0 2px 10px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
        font: 500 12px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        cursor: pointer;
        pointer-events: auto;
        user-select: none;
        white-space: nowrap;
      }
      .rw-pill[data-state="ready"]:hover { background: var(--rw-pill-hover); }
      .rw-pill[data-state="saving"],
      .rw-pill[data-state="saved"],
      .rw-pill[data-state="queued"] {
        cursor: default;
      }
      .rw-pill-icon {
        color: var(--rw-accent);
        font-weight: 600;
        font-size: 12px;
        line-height: 1;
      }
      .rw-pill-icon[hidden],
      .rw-pill-shortcut[hidden] {
        display: none;
      }
      .rw-pill[data-state="saved"] .rw-pill-icon {
        color: var(--rw-success);
      }
      .rw-pill[data-state="queued"] .rw-pill-icon {
        color: var(--rw-warning);
      }
      .rw-pill-shortcut {
        color: var(--rw-pill-shortcut);
        font-size: 11.5px;
        font-weight: 400;
        line-height: 1;
      }
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
    pillEl.setAttribute("aria-label", i18n.t(currentLocale, "pillAriaLabel"));

    pillIconEl = document.createElement("span");
    pillIconEl.className = "rw-pill-icon";
    pillIconEl.setAttribute("aria-hidden", "true");

    pillLabelEl = document.createElement("span");
    pillLabelEl.className = "rw-pill-label";

    pillShortcutEl = document.createElement("span");
    pillShortcutEl.className = "rw-pill-shortcut";
    pillShortcutEl.setAttribute("aria-hidden", "true");

    pillEl.append(pillIconEl, pillLabelEl, pillShortcutEl);
    applyPillVisualState("ready");

    pillEl.addEventListener("mousedown", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (pillState !== "ready") return;
      void captureAndSendCurrentSelection({ morphPill: true });
    });

    shadow.append(style, toastEl, pillEl);
    (document.documentElement || document.body).appendChild(host);
    shadowRootRef = shadow;
    return shadow;
  }

  function applyPillVisualState(state) {
    if (!pillEl) return;
    pillState = state;
    pillEl.setAttribute("data-state", state);
    pillEl.setAttribute("aria-label", i18n.t(currentLocale, "pillAriaLabel"));
    if (state === "saving") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "…";
      pillLabelEl.textContent = i18n.t(currentLocale, "pillSaving");
      pillShortcutEl.hidden = true;
    } else if (state === "saved") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "✓";
      pillLabelEl.textContent = i18n.t(currentLocale, "pillSaved");
      pillShortcutEl.hidden = true;
    } else if (state === "queued") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "✓";
      pillLabelEl.textContent = i18n.t(currentLocale, "pillQueued");
      pillShortcutEl.hidden = true;
    } else {
      pillIconEl.hidden = true;
      pillIconEl.textContent = "";
      pillLabelEl.textContent = i18n.t(currentLocale, "pillReady");
      pillShortcutEl.textContent = CAPTURE_SHORTCUT_HINT;
      pillShortcutEl.hidden = false;
    }
  }

  function refreshLocalizedPill() {
    if (!pillEl) return;
    pillEl.setAttribute("aria-label", i18n.t(currentLocale, "pillAriaLabel"));
    if (pillState !== "hidden") {
      applyPillVisualState(pillState);
      if (lastAnchorRect && pillEl.style.display !== "none") {
        positionPillAtRect(lastAnchorRect);
      }
    }
  }

  function positionPillAtRect(rect) {
    if (!pillEl || !rect) return;
    const pillWidth = pillEl.offsetWidth || 120;
    const pillHeight = pillEl.offsetHeight || 26;
    const pos = computePillPosition({
      rect,
      pillWidth,
      pillHeight,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight
    });
    pillEl.style.left = `${pos.left}px`;
    pillEl.style.top = `${pos.top}px`;
  }

  function morphPillAndScheduleHide(nextState) {
    if (!pillEl) return;
    if (pillHoldTimer) {
      clearTimeout(pillHoldTimer);
      pillHoldTimer = null;
    }
    pillEl.style.display = "inline-flex";
    pillEl.style.visibility = "visible";
    applyPillVisualState(nextState);
    if (lastAnchorRect) {
      positionPillAtRect(lastAnchorRect);
    }
    pillHoldTimer = setTimeout(() => {
      pillHoldTimer = null;
      hidePill();
    }, PILL_HOLD_MS);
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
    if (pillHoldTimer) {
      clearTimeout(pillHoldTimer);
      pillHoldTimer = null;
    }
    pillState = "hidden";
    lastAnchorRect = null;
    if (pillEl) {
      pillEl.setAttribute("data-state", "hidden");
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

  async function captureAndSendCurrentSelection({ morphPill = false } = {}) {
    const now = Date.now();
    if (now - lastTriggerAt < 350) return;
    lastTriggerAt = now;

    if (morphPill && pillEl && pillEl.style.display !== "none") {
      applyPillVisualState("saving");
      if (lastAnchorRect) positionPillAtRect(lastAnchorRect);
    }

    try {
      const clip = await extractCurrentSelection();
      if (!clip || !clip.selectedMarkdown) {
        if (morphPill && pillState === "saving") hidePill();
        return;
      }

      const resp = await chrome.runtime.sendMessage({
        type: "REWIND_SAVE_CLIP",
        clip
      });
      if (morphPill && pillState === "saving" && resp && (resp.status === "saved" || resp.status === "queued")) {
        morphPillAndScheduleHide(resp.status);
        return;
      }
      if (morphPill && pillState === "saving") hidePill();
      if (resp && resp.toast) {
        showToast(resp.toast, resp.status || "saved");
      }
    } catch {
      if (morphPill) hidePill();
      showToast(i18n.t(currentLocale, "toastSaveRetryError"), "error");
    }
  }

  function updatePillPosition() {
    if (pillState === "saving" || pillState === "saved" || pillState === "queued") {
      return;
    }
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
    lastAnchorRect = {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      bottom: rect.bottom
    };
    applyPillVisualState("ready");
    pillEl.style.visibility = "hidden";
    pillEl.style.display = "inline-flex";
    positionPillAtRect(lastAnchorRect);
    pillEl.style.visibility = "visible";
  }

  chrome.storage?.local?.get({ showSelectionPill: true, uiLanguage: "auto" }, (items) => {
    if (items && typeof items.showSelectionPill === "boolean") {
      showSelectionPill = items.showSelectionPill;
    }
    const nextPref = typeof items?.uiLanguage === "string" ? items.uiLanguage : "auto";
    currentLocale = i18n.resolveLocale(nextPref, detectBrowserLanguage());
    refreshLocalizedPill();
  });

  chrome.storage?.onChanged?.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.showSelectionPill) {
      showSelectionPill = changes.showSelectionPill.newValue !== false;
      if (!showSelectionPill) hidePill();
    }
    if (changes.uiLanguage) {
      const nextPref =
        typeof changes.uiLanguage.newValue === "string" ? changes.uiLanguage.newValue : "auto";
      currentLocale = i18n.resolveLocale(nextPref, detectBrowserLanguage());
      refreshLocalizedPill();
    }
  });

  document.addEventListener("mousedown", (event) => {
    if (pillEl && typeof event.composedPath === "function" && event.composedPath().includes(pillEl)) {
      return;
    }
    if (pillState === "saving") return;
    hidePill();
  }, true);

  document.addEventListener("mouseup", (event) => {
    if (pillEl && typeof event.composedPath === "function" && event.composedPath().includes(pillEl)) {
      return;
    }
    setTimeout(updatePillPosition, 15);
  }, true);

  document.addEventListener("selectionchange", () => {
    if (pillState === "saving" || pillState === "saved" || pillState === "queued") return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) hidePill();
  }, true);

  window.addEventListener(
    "scroll",
    () => {
      if (pillState === "saving") return;
      hidePill();
    },
    { capture: true, passive: true }
  );

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      hidePill();
      return;
    }
    if (isHyperCaptureShortcutEvent(event)) {
      const sel = window.getSelection();
      if (sel && !sel.isCollapsed && sel.toString().trim()) {
        event.preventDefault();
        if (pillState === "saving") return;
        const canMorphInPlace = Boolean(pillEl && pillEl.style.display !== "none" && pillState === "ready");
        if (!canMorphInPlace) hidePill();
        void captureAndSendCurrentSelection({ morphPill: canMorphInPlace });
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

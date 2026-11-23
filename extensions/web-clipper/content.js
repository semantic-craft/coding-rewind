// SPDX-License-Identifier: MIT
// Re-injection teardown lifecycle adapted from obsidianmd/obsidian-clipper (MIT, Copyright (c) 2024 Obsidian, commit 6d56d618b00b)
// Selection gesture & editable target gating adapted from crimx/ext-saladict (MIT, Copyright (c) 2018 Crimx, commit 1673df156908)
// Multi-rect selection anchoring adapted from floating-ui/floating-ui (MIT, Copyright (c) 2021 Floating UI contributors, commit c3042f1f37d9)

(() => {
  globalThis.__CODING_REWIND_HOOK__?.dispose?.();

  const TOAST_DURATION_MS = 2200;
  const PILL_HOLD_MS = 900;
  const VIEWPORT_MARGIN = 8;
  const PILL_GAP = 8;
  const MIN_DRAG_DISTANCE_PX = 6;
  const KEYBOARD_SELECTION_DEBOUNCE_MS = 120;

  const i18n = globalThis.CodingRewindI18n;
  const detectBrowserLanguage = () => i18n?.detectBrowserLanguage?.();
  let currentLocale = i18n ? i18n.resolveLocale("auto", detectBrowserLanguage()) : "zh-CN";

  const DEFAULT_EXCLUDED_DOMAINS = Object.freeze([
    "docs.google.com",
    "sheets.google.com",
    "slides.google.com",
    "figma.com",
    "canva.com"
  ]);

  const NON_TEXT_INPUT_TYPES = new Set([
    "button", "checkbox", "color", "file", "hidden",
    "image", "radio", "range", "reset", "submit"
  ]);

  const SELECTION_NAV_KEYS = new Set([
    "Shift", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
    "Home", "End", "PageUp", "PageDown"
  ]);

  const IS_APPLE_PLATFORM = /Mac|iPhone|iPad|iPod/i.test(
    (globalThis.navigator && (navigator.platform || navigator.userAgent)) || ""
  );
  const CAPTURE_SHORTCUT_HINT = IS_APPLE_PLATFORM ? "⌃⌥⇧⌘S" : "Alt+Shift+S";

  const pillPrefs = {
    hasExplicitScope: false,
    scope: "all",
    showBool: true,
    excludedDomains: DEFAULT_EXCLUDED_DOMAINS.slice()
  };

  let isDisposed = false;
  const domListeners = [];
  const chromeListeners = [];
  const activeTimers = new Set();
  const changedStorageKeys = new Set();

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
  let selectionCheckTimer = null;
  let pillState = "hidden";
  let lastPlacement = null;
  let pointerDown = null;
  let suppressNextMouseUp = false;
  let lastTriggerAt = 0;
  let activeSaveId = 0;
  let inFlightSaveId = 0;

  function scheduleTimer(fn, ms) {
    if (isDisposed) return null;
    const id = setTimeout(() => {
      activeTimers.delete(id);
      if (isDisposed) return;
      fn();
    }, ms);
    activeTimers.add(id);
    return id;
  }

  function cancelTimer(id) {
    if (id !== null && id !== undefined) {
      activeTimers.delete(id);
      clearTimeout(id);
    }
  }

  function listen(target, type, fn, options = false) {
    if (!target || typeof target.addEventListener !== "function") return;
    const wrapped = (event) => {
      if (isDisposed) return;
      fn(event);
    };
    target.addEventListener(type, wrapped, options);
    domListeners.push({ target, type, wrapped, options });
  }

  function listenChrome(eventObj, fn) {
    if (!eventObj || typeof eventObj.addListener !== "function") return;
    const wrapped = (...args) => {
      if (isDisposed) return false;
      return fn(...args);
    };
    eventObj.addListener(wrapped);
    chromeListeners.push({ eventObj, wrapped });
  }

  function detachElement(el) {
    if (!el) return;
    if (typeof el.remove === "function") {
      el.remove();
      return;
    }
    const parent = el.parentElement || el.parentNode;
    if (parent && typeof parent.removeChild === "function") {
      parent.removeChild(el);
    }
  }

  function removeOrphanUiHosts() {
    if (typeof document === "undefined" || !document) return;
    if (typeof document.querySelectorAll === "function") {
      for (const el of Array.from(document.querySelectorAll('[data-coding-rewind-ui="1"]'))) {
        detachElement(el);
      }
    }
    for (const root of [document.documentElement, document.body]) {
      if (!root || !root.children) continue;
      for (const child of Array.from(root.children)) {
        const flag = typeof child.getAttribute === "function"
          ? child.getAttribute("data-coding-rewind-ui")
          : child.attributes?.["data-coding-rewind-ui"];
        if (flag === "1") {
          detachElement(child);
        }
      }
    }
  }

  removeOrphanUiHosts();

  function dispose() {
    if (isDisposed) return;
    isDisposed = true;
    activeSaveId += 1;
    inFlightSaveId = 0;

    for (const id of activeTimers) {
      clearTimeout(id);
    }
    activeTimers.clear();
    toastTimer = null;
    pillHoldTimer = null;
    selectionCheckTimer = null;

    for (const { target, type, wrapped, options } of domListeners) {
      if (typeof target.removeEventListener === "function") {
        target.removeEventListener(type, wrapped, options);
      }
    }
    domListeners.length = 0;

    for (const { eventObj, wrapped } of chromeListeners) {
      if (typeof eventObj.removeListener === "function") {
        eventObj.removeListener(wrapped);
      }
    }
    chromeListeners.length = 0;

    if (shadowRootRef && shadowRootRef.host) {
      detachElement(shadowRootRef.host);
    }
    shadowRootRef = null;
    toastEl = null;
    toastDotEl = null;
    toastTextEl = null;
    pillEl = null;
    pillIconEl = null;
    pillLabelEl = null;
    pillShortcutEl = null;
    pillState = "hidden";
    lastPlacement = null;
    pointerDown = null;
    suppressNextMouseUp = false;
  }

  globalThis.__CODING_REWIND_HOOK__ = { dispose };

  function normalizeDomainEntry(raw) {
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

  function getCurrentHostname() {
    if (typeof location !== "undefined" && location) {
      if (typeof location.hostname === "string" && location.hostname) {
        return location.hostname.toLowerCase();
      }
      if (typeof location.href === "string" && location.href) {
        try {
          return new URL(location.href).hostname.toLowerCase();
        } catch {}
      }
    }
    if (document?.location?.href) {
      try {
        return new URL(document.location.href).hostname.toLowerCase();
      } catch {}
    }
    return "";
  }

  function isChatHost(hostname) {
    const h = String(hostname || "").toLowerCase();
    return (
      h === "chatgpt.com" ||
      h.endsWith(".chatgpt.com") ||
      h === "chat.openai.com" ||
      h === "claude.ai" ||
      h.endsWith(".claude.ai") ||
      h === "gemini.google.com"
    );
  }

  function isHostExcluded(hostname, excludedList) {
    const host = normalizeDomainEntry(hostname);
    if (!host || !Array.isArray(excludedList)) return false;
    for (const entry of excludedList) {
      const domain = normalizeDomainEntry(entry);
      if (domain && (host === domain || host.endsWith(`.${domain}`))) {
        return true;
      }
    }
    return false;
  }

  function effectivePillScope() {
    if (pillPrefs.showBool === false) return "off";
    if (pillPrefs.hasExplicitScope) return pillPrefs.scope;
    return "all";
  }

  function isPillAllowedOnCurrentPage() {
    const scope = effectivePillScope();
    if (scope === "off") return false;
    const host = getCurrentHostname();
    if (isHostExcluded(host, pillPrefs.excludedDomains)) return false;
    if (scope === "chat") return isChatHost(host);
    return true;
  }

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

  function normalizeRect(raw) {
    if (!raw) return null;
    const left = Number(raw.left) || 0;
    const top = Number(raw.top) || 0;
    const width = Number(raw.width) || 0;
    const height = Number(raw.height) || 0;
    const right = typeof raw.right === "number" ? raw.right : left + width;
    const bottom = typeof raw.bottom === "number" ? raw.bottom : top + height;
    return { left, top, width, height, right, bottom };
  }

  function isRectOffscreen(rect, vw, vh) {
    if (vw <= 0 || vh <= 0) return false;
    return rect.bottom < 0 || rect.top > vh || rect.right < 0 || rect.left > vw;
  }

  function isSelectionBackward(selection) {
    if (!selection) return false;
    if (typeof selection.isBackward === "boolean") return selection.isBackward;
    const { anchorNode, focusNode } = selection;
    if (!anchorNode || !focusNode) return false;
    if (anchorNode === focusNode) {
      return Number(selection.anchorOffset) > Number(selection.focusOffset);
    }
    if (typeof anchorNode.compareDocumentPosition === "function") {
      const pos = anchorNode.compareDocumentPosition(focusNode);
      if (pos & 2) return true;
      if (pos & 4) return false;
    }
    return false;
  }

  function resolveSelectionPlacement(range, selection, releasePoint, viewportWidth, viewportHeight) {
    if (!range) return null;
    const vw = Number(viewportWidth) || 0;
    const vh = Number(viewportHeight) || 0;
    const rawRects = typeof range.getClientRects === "function" ? Array.from(range.getClientRects()) : [];
    const visibleRects = rawRects
      .map(normalizeRect)
      .filter((r) => r && r.width > 0 && r.height > 0);

    if (visibleRects.length === 0) {
      const fallbackRect = normalizeRect(
        typeof range.getBoundingClientRect === "function" ? range.getBoundingClientRect() : null
      );
      if (fallbackRect && (fallbackRect.width > 0 || fallbackRect.height > 0)) {
        visibleRects.push(fallbackRect);
      }
    }

    const inViewportRects = visibleRects.filter((r) => !isRectOffscreen(r, vw, vh));
    if (inViewportRects.length === 0) return null;

    const lineRects = [];
    for (const r of inViewportRects) {
      const existing = lineRects.find(
        (line) => Math.min(line.bottom, r.bottom) - Math.max(line.top, r.top) > Math.min(line.height, r.height) * 0.5
      );
      if (existing) {
        existing.left = Math.min(existing.left, r.left);
        existing.top = Math.min(existing.top, r.top);
        existing.right = Math.max(existing.right, r.right);
        existing.bottom = Math.max(existing.bottom, r.bottom);
        existing.width = existing.right - existing.left;
        existing.height = existing.bottom - existing.top;
      } else {
        lineRects.push({ ...r });
      }
    }

    if (lineRects.length === 1) {
      const rect = lineRects[0];
      return {
        firstRect: rect,
        lastRect: rect,
        anchorRect: rect,
        preferBelow: false,
        centerX: rect.left + rect.width / 2
      };
    }

    const firstRect = lineRects[0];
    const lastRect = lineRects[lineRects.length - 1];
    const backward = isSelectionBackward(selection);
    const anchorRect = backward ? firstRect : lastRect;
    const preferBelow = !backward;
    const centerX = releasePoint && typeof releasePoint.clientX === "number"
      ? Math.min(anchorRect.right, Math.max(anchorRect.left, releasePoint.clientX))
      : anchorRect.left + anchorRect.width / 2;

    return {
      firstRect,
      lastRect,
      anchorRect,
      preferBelow,
      centerX
    };
  }

  function computePillPosition({ placement, pillWidth, pillHeight, viewportWidth, viewportHeight }) {
    const width = Number(pillWidth) || 0;
    const height = Number(pillHeight) || 0;
    const vw = Number(viewportWidth) || 0;
    const vh = Number(viewportHeight) || 0;

    const maxLeft = Math.max(VIEWPORT_MARGIN, vw - width - VIEWPORT_MARGIN);
    const left = Math.round(
      Math.min(maxLeft, Math.max(VIEWPORT_MARGIN, placement.centerX - width / 2))
    );

    const maxTop = Math.max(VIEWPORT_MARGIN, vh - height - VIEWPORT_MARGIN);
    let top;
    if (placement.preferBelow) {
      top = placement.anchorRect.bottom + PILL_GAP;
      if (top + height > vh - VIEWPORT_MARGIN) {
        top = placement.firstRect.top - height - PILL_GAP;
      }
    } else {
      top = placement.anchorRect.top - height - PILL_GAP;
      if (top < VIEWPORT_MARGIN) {
        top = Math.min(maxTop, placement.lastRect.bottom + PILL_GAP);
      }
    }

    return {
      left,
      top: Math.round(Math.min(maxTop, Math.max(VIEWPORT_MARGIN, top)))
    };
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
      "position:fixed !important;top:0 !important;left:0 !important;width:0 !important;height:0 !important;overflow:visible !important;pointer-events:none !important;z-index:2147483647 !important;user-select:none !important;-webkit-user-select:none !important;";
    const shadow = host.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = `
      :host {
        position: fixed !important;
        top: 0 !important;
        left: 0 !important;
        width: 0 !important;
        height: 0 !important;
        overflow: visible !important;
        pointer-events: none !important;
        z-index: 2147483647 !important;
        color-scheme: light dark;
        --rw-surface: rgba(255, 255, 255, 0.96);
        --rw-text: #202124;
        --rw-border: #dfe3e8;
        --rw-pill-bg: #ffffff;
        --rw-pill-hover: #f6f6f7;
        --rw-pill-border: rgba(0, 0, 0, 0.075);
        --rw-pill-shortcut: rgba(0, 0, 0, 0.42);
        --rw-accent: #0068d9;
        --rw-success: #16713b;
        --rw-warning: #9b5c06;
        --rw-error: #b52632;
      }
      @media (prefers-color-scheme: dark) {
        :host {
          --rw-surface: rgba(32, 33, 36, 0.96);
          --rw-text: #f2f3f4;
          --rw-border: #41454c;
          --rw-pill-bg: #242428;
          --rw-pill-hover: #2f2f35;
          --rw-pill-border: rgba(255, 255, 255, 0.12);
          --rw-pill-shortcut: rgba(255, 255, 255, 0.46);
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
    pillEl.setAttribute("aria-label", i18n ? i18n.t(currentLocale, "pillAriaLabel") : "暂存选中文本");

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

    listen(pillEl, "mousedown", (event) => {
      if (!event || event.isTrusted !== true) return;
      if (typeof event.button === "number" && event.button !== 0) return;
      suppressNextMouseUp = true;
      event.preventDefault();
      event.stopPropagation();
      if (pillState !== "ready") return;
      void captureAndSendCurrentSelection({ morphPill: true, enforcePillTargetGate: true });
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
    pillEl.setAttribute("aria-label", i18n ? i18n.t(currentLocale, "pillAriaLabel") : "暂存选中文本");
    if (state === "saving") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "…";
      pillLabelEl.textContent = i18n ? i18n.t(currentLocale, "pillSaving") : "暂存中…";
      pillShortcutEl.hidden = true;
    } else if (state === "saved") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "✓";
      pillLabelEl.textContent = i18n ? i18n.t(currentLocale, "pillSaved") : "已同步";
      pillShortcutEl.hidden = true;
    } else if (state === "queued") {
      pillIconEl.hidden = false;
      pillIconEl.textContent = "✓";
      pillLabelEl.textContent = i18n ? i18n.t(currentLocale, "pillQueued") : "待同步";
      pillShortcutEl.hidden = true;
    } else {
      pillIconEl.hidden = true;
      pillIconEl.textContent = "";
      pillLabelEl.textContent = i18n ? i18n.t(currentLocale, "pillReady") : "暂存";
      pillShortcutEl.textContent = CAPTURE_SHORTCUT_HINT;
      pillShortcutEl.hidden = false;
    }
  }

  function refreshLocalizedPill() {
    if (!pillEl) return;
    pillEl.setAttribute("aria-label", i18n ? i18n.t(currentLocale, "pillAriaLabel") : "暂存选中文本");
    if (pillState !== "hidden") {
      applyPillVisualState(pillState);
      if (lastPlacement && pillEl.style.display !== "none") {
        positionPillAtPlacement(lastPlacement);
      }
    }
  }

  function positionPillAtPlacement(placement) {
    if (!pillEl || !placement) return;
    const pillWidth = pillEl.offsetWidth || 120;
    const pillHeight = pillEl.offsetHeight || 26;
    const pos = computePillPosition({
      placement,
      pillWidth,
      pillHeight,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight
    });
    pillEl.style.left = `${pos.left}px`;
    pillEl.style.top = `${pos.top}px`;
  }

  function morphPillAndScheduleHide(nextState) {
    if (!pillEl || isDisposed) return;
    cancelTimer(pillHoldTimer);
    pillHoldTimer = null;
    pillEl.style.display = "inline-flex";
    pillEl.style.visibility = "visible";
    applyPillVisualState(nextState);
    if (lastPlacement) {
      positionPillAtPlacement(lastPlacement);
    }
    pillHoldTimer = scheduleTimer(() => {
      pillHoldTimer = null;
      hidePill();
    }, PILL_HOLD_MS);
  }

  function showToast(message, variant = "saved") {
    if (!message || isDisposed) return;
    ensureUiRoot();
    toastDotEl.setAttribute("data-variant", variant);
    toastTextEl.textContent = message;
    toastEl.setAttribute("data-visible", "true");
    cancelTimer(toastTimer);
    toastTimer = scheduleTimer(() => {
      toastTimer = null;
      if (toastEl) toastEl.setAttribute("data-visible", "false");
    }, TOAST_DURATION_MS);
  }

  function hidePill() {
    activeSaveId += 1;
    cancelTimer(pillHoldTimer);
    pillHoldTimer = null;
    pillState = "hidden";
    lastPlacement = null;
    if (pillEl) {
      pillEl.setAttribute("data-state", "hidden");
      pillEl.style.display = "none";
    }
  }

  function getAttr(el, name) {
    if (!el) return null;
    if (typeof el.getAttribute === "function") return el.getAttribute(name);
    if (el.attributes && Object.prototype.hasOwnProperty.call(el.attributes, name)) {
      return el.attributes[name];
    }
    return null;
  }

  function nodeContains(root, target) {
    if (!root || !target) return false;
    if (root === target) return true;
    if (typeof root.contains === "function") {
      try {
        if (root.contains(target)) return true;
      } catch {}
    }
    let cur = target;
    while (cur) {
      if (cur === root) return true;
      cur = cur.parentElement || cur.parentNode || null;
    }
    return false;
  }

  function isReadOnlyOrDisabledInput(el) {
    return Boolean(
      el.readOnly === true ||
      el.disabled === true ||
      getAttr(el, "readonly") !== null ||
      getAttr(el, "disabled") !== null
    );
  }

  function getReadOnlyControlSelection() {
    const el = document.activeElement;
    if (!el || el.nodeType !== 1) return null;
    const tag = String(el.tagName || el.nodeName || "").toLowerCase();
    if (tag !== "textarea" && tag !== "input") return null;
    if (tag === "input") {
      const inputType = String(el.type || getAttr(el, "type") || "text").toLowerCase();
      if (NON_TEXT_INPUT_TYPES.has(inputType) || inputType === "password") return null;
    }
    if (!isReadOnlyOrDisabledInput(el)) return null;
    if (
      typeof el.selectionStart !== "number" ||
      typeof el.selectionEnd !== "number" ||
      el.selectionEnd <= el.selectionStart ||
      typeof el.value !== "string"
    ) {
      return null;
    }
    const text = el.value.slice(el.selectionStart, el.selectionEnd);
    if (!text.trim()) return null;
    const rect = normalizeRect(
      typeof el.getBoundingClientRect === "function" ? el.getBoundingClientRect() : null
    );
    return { text, element: el, rect };
  }

  function hasAriaReadOnlyOnEditableHost(el) {
    let anc = el;
    while (anc && anc.nodeType === 1) {
      if (getAttr(anc, "aria-readonly") === "true") return true;
      if (getAttr(anc, "contenteditable") !== null || getAttr(anc, "role") === "textbox") {
        return false;
      }
      anc = anc.parentElement || (anc.parentNode && anc.parentNode.nodeType === 1 ? anc.parentNode : null);
    }
    return false;
  }

  function isDisallowedSelectionNode(node) {
    let cur = node && node.nodeType === 1 ? node : node && (node.parentElement || node.parentNode);
    while (cur && cur.nodeType === 1) {
      const tag = String(cur.tagName || cur.nodeName || "").toLowerCase();
      if (tag === "textarea") {
        if (!isReadOnlyOrDisabledInput(cur)) return true;
      } else if (tag === "input") {
        const inputType = String(cur.type || getAttr(cur, "type") || "text").toLowerCase();
        if (inputType === "password") return true;
        if (!NON_TEXT_INPUT_TYPES.has(inputType) && !isReadOnlyOrDisabledInput(cur)) {
          return true;
        }
      }

      const ariaReadOnly = hasAriaReadOnlyOnEditableHost(cur);
      const ceAttr = getAttr(cur, "contenteditable");
      const ceNorm = ceAttr !== null ? String(ceAttr).trim().toLowerCase() : null;
      const isContentEditable =
        cur.isContentEditable === true ||
        ceNorm === "" ||
        ceNorm === "true" ||
        ceNorm === "plaintext-only";
      if (isContentEditable && !ariaReadOnly) return true;

      if (getAttr(cur, "role") === "textbox" && !ariaReadOnly) return true;

      const rawClass = typeof cur.className === "string" ? cur.className : (getAttr(cur, "class") || "");
      if (rawClass) {
        const classes = rawClass.split(/\s+/);
        if (
          classes.includes("monaco-editor") ||
          classes.includes("ace_editor") ||
          classes.includes("CodeMirror")
        ) {
          return true;
        }
        if (
          classes.includes("cm-editor") &&
          typeof cur.querySelector === "function" &&
          Boolean(cur.querySelector("[contenteditable='true'], [contenteditable=''], [contenteditable='plaintext-only']"))
        ) {
          return true;
        }
      }

      cur = cur.parentElement || (cur.parentNode && cur.parentNode.nodeType === 1 ? cur.parentNode : null);
    }
    return false;
  }

  function isSelectionInDisallowedTarget(selection) {
    if (isDisallowedSelectionNode(selection.anchorNode) || isDisallowedSelectionNode(selection.focusNode)) {
      return true;
    }
    const active = document.activeElement;
    if (active && active !== document.body && active !== document.documentElement) {
      const related =
        nodeContains(active, selection.anchorNode) ||
        nodeContains(active, selection.focusNode) ||
        nodeContains(selection.anchorNode, active) ||
        nodeContains(selection.focusNode, active);
      if (related && isDisallowedSelectionNode(active)) return true;
    }
    return false;
  }

  function isInteractiveClickTarget(node) {
    let cur = node && node.nodeType === 1 ? node : node && (node.parentElement || node.parentNode);
    while (cur && cur.nodeType === 1) {
      const tag = String(cur.tagName || cur.nodeName || "").toLowerCase();
      if (tag === "button" || tag === "summary" || tag === "select") return true;
      if (tag === "a" && getAttr(cur, "href")) return true;
      cur = cur.parentElement || (cur.parentNode && cur.parentNode.nodeType === 1 ? cur.parentNode : null);
    }
    return false;
  }

  function isPasswordSelectionNode(node) {
    let cur = node && node.nodeType === 1 ? node : node && (node.parentElement || node.parentNode);
    while (cur && cur.nodeType === 1) {
      const tag = String(cur.tagName || cur.nodeName || "").toLowerCase();
      if (tag === "input") {
        const inputType = String(cur.type || getAttr(cur, "type") || "text").toLowerCase();
        if (inputType === "password") return true;
      }
      cur = cur.parentElement || (cur.parentNode && cur.parentNode.nodeType === 1 ? cur.parentNode : null);
    }
    return false;
  }

  function isPasswordSelection(selection) {
    if (!selection) return false;
    if (isPasswordSelectionNode(selection.anchorNode) || isPasswordSelectionNode(selection.focusNode)) {
      return true;
    }
    const active = document.activeElement;
    if (active && active !== document.body && active !== document.documentElement) {
      const related =
        nodeContains(active, selection.anchorNode) ||
        nodeContains(active, selection.focusNode) ||
        nodeContains(selection.anchorNode, active) ||
        nodeContains(selection.focusNode, active);
      if (related && isPasswordSelectionNode(active)) return true;
    }
    return false;
  }

  function isEventInsidePill(event) {
    if (!event || !pillEl || pillState === "hidden" || pillEl.style.display === "none") {
      return false;
    }
    const uiHost = shadowRootRef?.host || null;
    if (typeof event.composedPath === "function") {
      const path = event.composedPath();
      if (Array.isArray(path) && (path.includes(pillEl) || (uiHost && path.includes(uiHost)))) {
        return true;
      }
    }
    return event.target === pillEl || Boolean(uiHost && event.target === uiHost);
  }

  async function extractCurrentSelectionResult({ enforcePillTargetGate = false } = {}) {
    if (enforcePillTargetGate && !isPillAllowedOnCurrentPage()) {
      return { clip: null, blocked: true };
    }
    const selection = window.getSelection();
    let range = null;
    let rawText = "";
    if (selection && selection.rangeCount > 0 && !selection.isCollapsed) {
      if (isPasswordSelection(selection)) return { clip: null, blocked: true };
      if (enforcePillTargetGate && isSelectionInDisallowedTarget(selection)) {
        return { clip: null, blocked: true };
      }
      range = selection.getRangeAt(0).cloneRange();
      rawText = selection.toString() || "";
    }
    if (!rawText.trim()) {
      if (isPasswordSelectionNode(document.activeElement)) {
        return { clip: null, blocked: true };
      }
      const roSel = getReadOnlyControlSelection();
      if (!roSel) return { clip: null, blocked: false };
      range = null;
      rawText = roSel.text;
    }
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
    return { clip, blocked: false };
  }

  async function extractCurrentSelection(options = {}) {
    const { clip } = await extractCurrentSelectionResult(options);
    return clip;
  }

  async function extractCurrentPageReading({ pageUrl, excludedDomains }) {
    const blockedDomains = Array.isArray(excludedDomains) ? excludedDomains : DEFAULT_EXCLUDED_DOMAINS;
    const mayReadPage = () => (
      !isDisposed && pageUrl === location.href &&
      !isHostExcluded(getCurrentHostname(), blockedDomains) &&
      !isDisallowedSelectionNode(document.activeElement)
    );
    if (!mayReadPage()) return null;
    const { extractPageReadingClip } = await loadExtractors();
    return mayReadPage() ? extractPageReadingClip(document, pageUrl) : null;
  }

  function readCapturePreferences() {
    return new Promise((resolve, reject) => {
      chrome.storage.local.get(["capturePreferences"], (items) => {
        const error = chrome.runtime.lastError;
        if (error || !items) {
          reject(new Error(error?.message || "Capture preferences unavailable"));
        } else {
          resolve(items.capturePreferences === undefined ? {} : items.capturePreferences);
        }
      });
    });
  }

  async function captureAndSendCurrentSelection({ morphPill = false, enforcePillTargetGate = false } = {}) {
    if (isDisposed || inFlightSaveId !== 0) return;
    const now = Date.now();
    if (now - lastTriggerAt < 350) return;
    lastTriggerAt = now;
    const saveId = ++activeSaveId;
    inFlightSaveId = saveId;

    if (morphPill && pillEl && pillEl.style.display !== "none") {
      applyPillVisualState("saving");
      if (lastPlacement) positionPillAtPlacement(lastPlacement);
    }

    try {
      const [capturePreferences, clip] = await Promise.all([
        readCapturePreferences(),
        extractCurrentSelection({ enforcePillTargetGate })
      ]);
      if (isDisposed || saveId !== activeSaveId) return;
      if (!clip || !clip.selectedMarkdown) {
        if (morphPill && pillState === "saving") hidePill();
        return;
      }

      const resp = await chrome.runtime.sendMessage({
        type: "REWIND_SAVE_CLIP",
        clip,
        capturePreferences
      });
      if (isDisposed || saveId !== activeSaveId) return;
      if (morphPill && pillState === "saving" && resp && (resp.status === "saved" || resp.status === "queued")) {
        morphPillAndScheduleHide(resp.status);
        return;
      }
      if (morphPill && pillState === "saving") hidePill();
      if (resp && resp.toast) {
        showToast(resp.toast, resp.status || "saved");
      }
    } catch {
      if (isDisposed || saveId !== activeSaveId) return;
      if (morphPill) hidePill();
      showToast(i18n ? i18n.t(currentLocale, "toastSaveRetryError") : "保存失败，请重试", "error");
    } finally {
      if (inFlightSaveId === saveId) {
        inFlightSaveId = 0;
      }
    }
  }

  function updatePillPosition(releasePoint = null) {
    if (isDisposed) return;
    if (pillState === "saving" || pillState === "saved" || pillState === "queued") {
      return;
    }
    if (!isPillAllowedOnCurrentPage()) {
      hidePill();
      return;
    }
    const selection = window.getSelection();
    let placement = null;
    if (selection && selection.rangeCount > 0 && !selection.isCollapsed && selection.toString().trim()) {
      const text = selection.toString().trim();
      if (text.length < 2 || isSelectionInDisallowedTarget(selection)) {
        hidePill();
        return;
      }
      const range = selection.getRangeAt(0);
      placement = resolveSelectionPlacement(
        range,
        selection,
        releasePoint,
        window.innerWidth,
        window.innerHeight
      );
    } else {
      const roSel = getReadOnlyControlSelection();
      if (!roSel || roSel.text.trim().length < 2) {
        hidePill();
        return;
      }
      const vw = Number(window.innerWidth) || 0;
      const vh = Number(window.innerHeight) || 0;
      const rect = roSel.rect;
      if (!rect || (rect.width === 0 && rect.height === 0) || isRectOffscreen(rect, vw, vh)) {
        hidePill();
        return;
      }
      const centerX = releasePoint && typeof releasePoint.clientX === "number"
        ? Math.min(rect.right, Math.max(rect.left, releasePoint.clientX))
        : rect.left + rect.width / 2;
      placement = {
        firstRect: rect,
        lastRect: rect,
        anchorRect: rect,
        preferBelow: false,
        centerX
      };
    }
    if (!placement) {
      hidePill();
      return;
    }

    ensureUiRoot();
    lastPlacement = placement;
    applyPillVisualState("ready");
    pillEl.style.visibility = "hidden";
    pillEl.style.display = "inline-flex";
    positionPillAtPlacement(placement);
    pillEl.style.visibility = "visible";
  }

  function scheduleSelectionCheck(releasePoint, delayMs) {
    cancelTimer(selectionCheckTimer);
    selectionCheckTimer = scheduleTimer(() => {
      selectionCheckTimer = null;
      updatePillPosition(releasePoint);
    }, delayMs);
  }

  chrome.storage?.local?.get(["selectionPillScope", "showSelectionPill", "excludedDomains", "uiLanguage"], (items) => {
    if (isDisposed || !items) return;
    if (
      !changedStorageKeys.has("showSelectionPill") &&
      !changedStorageKeys.has("selectionPillScope") &&
      typeof items.showSelectionPill === "boolean"
    ) {
      pillPrefs.showBool = items.showSelectionPill;
    }
    if (
      !changedStorageKeys.has("selectionPillScope") &&
      (items.selectionPillScope === "all" ||
        items.selectionPillScope === "chat" ||
        items.selectionPillScope === "off")
    ) {
      pillPrefs.hasExplicitScope = true;
      pillPrefs.scope = items.selectionPillScope;
    } else if (
      !changedStorageKeys.has("selectionPillScope") &&
      !changedStorageKeys.has("showSelectionPill") &&
      typeof items.showSelectionPill === "boolean"
    ) {
      pillPrefs.scope = items.showSelectionPill ? "all" : "off";
    }
    if (!changedStorageKeys.has("excludedDomains") && Array.isArray(items.excludedDomains)) {
      pillPrefs.excludedDomains = items.excludedDomains.slice();
    }
    if (!changedStorageKeys.has("uiLanguage")) {
      const nextPref = typeof items.uiLanguage === "string" ? items.uiLanguage : "auto";
      currentLocale = i18n ? i18n.resolveLocale(nextPref, detectBrowserLanguage()) : "zh-CN";
      refreshLocalizedPill();
    }
    if (!isPillAllowedOnCurrentPage() && pillState !== "saving") {
      hidePill();
    }
  });

  listenChrome(chrome.storage?.onChanged, (changes, area) => {
    if (area !== "local" || !changes) return;
    if (changes.selectionPillScope) {
      changedStorageKeys.add("selectionPillScope");
      const nextScope = changes.selectionPillScope.newValue;
      if (nextScope === "all" || nextScope === "chat" || nextScope === "off") {
        pillPrefs.hasExplicitScope = true;
        pillPrefs.scope = nextScope;
        if (!changes.showSelectionPill && nextScope !== "off") {
          pillPrefs.showBool = true;
        }
      } else if (nextScope === undefined) {
        pillPrefs.hasExplicitScope = false;
        pillPrefs.scope = "all";
      }
    }
    if (changes.showSelectionPill) {
      changedStorageKeys.add("showSelectionPill");
      pillPrefs.showBool = changes.showSelectionPill.newValue !== false;
      if (!changes.selectionPillScope && pillPrefs.showBool && pillPrefs.scope === "off") {
        pillPrefs.scope = "all";
      }
    }
    if (changes.excludedDomains) {
      changedStorageKeys.add("excludedDomains");
      pillPrefs.excludedDomains = Array.isArray(changes.excludedDomains.newValue)
        ? changes.excludedDomains.newValue.slice()
        : DEFAULT_EXCLUDED_DOMAINS.slice();
    }
    if (changes.uiLanguage) {
      changedStorageKeys.add("uiLanguage");
      const nextPref =
        typeof changes.uiLanguage.newValue === "string" ? changes.uiLanguage.newValue : "auto";
      currentLocale = i18n ? i18n.resolveLocale(nextPref, detectBrowserLanguage()) : "zh-CN";
      refreshLocalizedPill();
    }
    if (!isPillAllowedOnCurrentPage() && pillState !== "saving") {
      hidePill();
    }
  });

  listen(document, "mousedown", (event) => {
    if (!event || event.isTrusted !== true) return;
    if (typeof event.button === "number" && event.button !== 0) return;
    if (isEventInsidePill(event)) {
      suppressNextMouseUp = true;
      return;
    }
    suppressNextMouseUp = false;
    pointerDown = typeof event.clientX === "number" && typeof event.clientY === "number"
      ? { clientX: event.clientX, clientY: event.clientY }
      : null;
    cancelTimer(selectionCheckTimer);
    selectionCheckTimer = null;
    if (pillState === "saving") return;
    hidePill();
  }, true);

  listen(document, "mouseup", (event) => {
    if (!event || event.isTrusted !== true) return;
    if (typeof event.button === "number" && event.button !== 0) return;
    if (suppressNextMouseUp) {
      suppressNextMouseUp = false;
      pointerDown = null;
      return;
    }
    if (isEventInsidePill(event)) return;
    const down = pointerDown;
    pointerDown = null;
    const upPoint = typeof event.clientX === "number" && typeof event.clientY === "number"
      ? { clientX: event.clientX, clientY: event.clientY }
      : null;

    if (down && upPoint) {
      const dragDistance = Math.hypot(upPoint.clientX - down.clientX, upPoint.clientY - down.clientY);
      const detail = typeof event.detail === "number" ? event.detail : 1;
      const shiftKey = Boolean(event.shiftKey);
      if (dragDistance < MIN_DRAG_DISTANCE_PX && detail < 2 && !shiftKey) {
        if (pillState !== "saving") hidePill();
        return;
      }
    } else if (
      upPoint &&
      (event.detail ?? 1) < 2 &&
      !event.shiftKey &&
      isInteractiveClickTarget(event.target)
    ) {
      if (pillState !== "saving") hidePill();
      return;
    }

    scheduleSelectionCheck(upPoint, 15);
  }, true);

  listen(document, "selectionchange", () => {
    if (pillState === "saving" || pillState === "saved" || pillState === "queued") return;
    const sel = window.getSelection();
    if ((!sel || sel.isCollapsed) && !getReadOnlyControlSelection()) hidePill();
  }, true);

  listen(
    window,
    "scroll",
    () => {
      cancelTimer(selectionCheckTimer);
      selectionCheckTimer = null;
      if (pillState === "saving") return;
      hidePill();
    },
    { capture: true, passive: true }
  );

  listen(window, "resize", () => {
    cancelTimer(selectionCheckTimer);
    selectionCheckTimer = null;
    if (pillState === "saving") return;
    hidePill();
  });

  listen(document, "visibilitychange", () => {
    if (!document.hidden) return;
    cancelTimer(selectionCheckTimer);
    selectionCheckTimer = null;
    if (pillState === "saving") return;
    hidePill();
  });

  listen(document, "keydown", (event) => {
    if (!event || event.isTrusted !== true) return;
    if (event.key === "Escape") {
      cancelTimer(selectionCheckTimer);
      selectionCheckTimer = null;
      inFlightSaveId = 0;
      hidePill();
      return;
    }
    if (isHyperCaptureShortcutEvent(event)) {
      const sel = window.getSelection();
      const hasDomSel = Boolean(sel && !sel.isCollapsed && sel.toString().trim() && !isPasswordSelection(sel));
      const hasRoSel = !hasDomSel && Boolean(getReadOnlyControlSelection());
      if (hasDomSel || hasRoSel) {
        event.preventDefault();
        cancelTimer(selectionCheckTimer);
        selectionCheckTimer = null;
        if (pillState === "saving" || inFlightSaveId !== 0) return;
        const canMorphInPlace = Boolean(pillEl && pillEl.style.display !== "none" && pillState === "ready");
        if (!canMorphInPlace) hidePill();
        void captureAndSendCurrentSelection({ morphPill: canMorphInPlace });
      }
    }
  }, true);

  listen(document, "keyup", (event) => {
    if (!event || event.isTrusted !== true) return;
    if (event.key === "Escape" || isHyperCaptureShortcutEvent(event)) return;
    if (Boolean(event.shiftKey) || SELECTION_NAV_KEYS.has(event.key)) {
      scheduleSelectionCheck(null, KEYBOARD_SELECTION_DEBOUNCE_MS);
    }
  }, true);

  listenChrome(chrome.runtime?.onMessage, (msg, _sender, sendResponse) => {
    if (!msg || typeof msg !== "object") return false;
    if (chrome.runtime?.id && (!_sender || _sender.id !== chrome.runtime.id)) {
      return false;
    }
    if (msg.type === "REWIND_EXTRACT_SELECTION") {
      lastTriggerAt = Date.now();
      inFlightSaveId = 0;
      cancelTimer(selectionCheckTimer);
      selectionCheckTimer = null;
      hidePill();
      extractCurrentSelectionResult()
        .then(({ clip, blocked }) => sendResponse(blocked ? { clip: null, blocked: true } : { clip }))
        .catch(() => sendResponse({ clip: null }));
      return true;
    }
    if (msg.type === "REWIND_EXTRACT_PAGE_READING") {
      extractCurrentPageReading(msg)
        .then(sendResponse)
        .catch(() => sendResponse(null));
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

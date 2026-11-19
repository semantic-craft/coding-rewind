// SPDX-License-Identifier: MIT

(function (root) {
  function createClientModule() {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

    var API_PATH = "/coding-rewind/api";
    var POLL_TIMEOUT_MS = 20000;
    var FEEDBACK_HOLD_MS = 1800;
    var PILL_GAP = 8;
    var VIEWPORT_MARGIN = 8;
    var SELECTION_DEBOUNCE_MS = 80;
    var ELEMENT_NODE = 1;
    var TEXT_NODE = 3;
    var DOCUMENT_NODE = 9;
    var DOCUMENT_FRAGMENT_NODE = 11;

    var SKIP_TAGS = new Set([
      "script", "style", "noscript", "svg", "button", "nav", "form", "textarea", "select", "input",
    ]);

    var COPY = {
      zh: {
        ready: "暂存",
        ariaLabel: "暂存选中文本",
        saving: "暂存中…",
        saved: "已暂存",
        queued: "已离线暂存",
        notRunning: "请先打开 Coding Rewind",
        failed: "暂存失败",
      },
      en: {
        ready: "Stash",
        ariaLabel: "Stash selected text",
        saving: "Saving…",
        saved: "Stashed",
        queued: "Stashed offline",
        notRunning: "Open Coding Rewind first",
        failed: "Stash failed",
      },
    };

    function getService(ctx, key) {
      if (!ctx) return undefined;
      if (typeof ctx.get === "function") {
        return ctx.get(key);
      }
      return ctx[key];
    }

    function getTagName(node) {
      return String((node && (node.tagName || node.nodeName)) || "").toLowerCase();
    }

    function getAttr(node, attr) {
      if (!node) return null;
      if (typeof node.getAttribute === "function") return node.getAttribute(attr);
      if (node.attributes && Object.prototype.hasOwnProperty.call(node.attributes, attr)) {
        return node.attributes[attr];
      }
      return null;
    }

    function hasAttr(node, attr) {
      if (!node) return false;
      if (typeof node.hasAttribute === "function") return node.hasAttribute(attr);
      return getAttr(node, attr) !== null && getAttr(node, attr) !== undefined;
    }

    function getClassString(node) {
      if (!node) return "";
      if (typeof node.className === "string") return node.className;
      return String(getAttr(node, "class") || "");
    }

    function hasClass(node, className) {
      var raw = getClassString(node);
      return raw ? raw.split(/\s+/).includes(className) : false;
    }

    function parentElementOf(node) {
      if (!node) return null;
      if (node.parentElement) return node.parentElement;
      if (node.parentNode && node.parentNode.nodeType === ELEMENT_NODE) return node.parentNode;
      return null;
    }

    function closestElement(node, predicate) {
      var cur = node && node.nodeType === ELEMENT_NODE ? node : parentElementOf(node);
      while (cur && cur.nodeType === ELEMENT_NODE) {
        if (predicate(cur)) return cur;
        cur = parentElementOf(cur);
      }
      return null;
    }

    function parseTimestampMs(value) {
      if (typeof value === "number" && Number.isFinite(value)) return value;
      if (typeof value === "string" && value.trim()) {
        var parsed = Date.parse(value);
        if (Number.isFinite(parsed)) return parsed;
      }
      return Number.NEGATIVE_INFINITY;
    }

    function workspaceIdOf(ws) {
      if (!ws || typeof ws !== "object") return "";
      if (typeof ws.workspaceId === "string" && ws.workspaceId.trim()) return ws.workspaceId.trim();
      if (typeof ws.id === "string" && ws.id.trim()) return ws.id.trim();
      return "";
    }

    function findActiveSession(sessionsSnapshot) {
      var byId = sessionsSnapshot && sessionsSnapshot.byId;
      if (!byId || typeof byId !== "object") return null;
      var entries = Object.entries(byId);
      for (var i = 0; i < entries.length; i += 1) {
        var key = entries[i][0];
        var session = entries[i][1];
        if (!session || typeof session !== "object") continue;
        var mainViewCount = Number(session.retainedBy && session.retainedBy.mainView) || 0;
        if (mainViewCount > 0) {
          var id = typeof session.id === "string" && session.id ? session.id : key;
          var title = typeof session.displayTitle === "string" && session.displayTitle.trim()
            ? session.displayTitle.trim()
            : (typeof session.title === "string" ? session.title.trim() : "");
          return { sessionId: id, sessionTitle: title };
        }
      }
      return null;
    }

    function resolveTargetWorkspaceId(sessionsSnapshot, workspacesSnapshot) {
      var byId = (sessionsSnapshot && sessionsSnapshot.byId) || {};
      var items = Array.isArray(workspacesSnapshot && workspacesSnapshot.items)
        ? workspacesSnapshot.items
        : [];

      var active = findActiveSession(sessionsSnapshot);
      if (active) {
        for (var i = 0; i < items.length; i += 1) {
          var ws = items[i];
          if (Array.isArray(ws && ws.sessionIds) && ws.sessionIds.includes(active.sessionId)) {
            var activeWsId = workspaceIdOf(ws);
            if (activeWsId) return activeWsId;
          }
        }
      }

      var bestId = null;
      var bestTime = Number.NEGATIVE_INFINITY;
      for (var j = 0; j < items.length; j += 1) {
        var workspace = items[j];
        var wid = workspaceIdOf(workspace);
        if (!wid) continue;
        var latest = Number.NEGATIVE_INFINITY;
        var sids = Array.isArray(workspace.sessionIds) ? workspace.sessionIds : [];
        for (var k = 0; k < sids.length; k += 1) {
          var session = byId[sids[k]];
          var sessionUpdated = parseTimestampMs(session && session.updatedAt);
          if (sessionUpdated > latest) latest = sessionUpdated;
        }
        if (latest === Number.NEGATIVE_INFINITY) {
          var wsUpdated = parseTimestampMs(workspace.updatedAt);
          latest = wsUpdated !== Number.NEGATIVE_INFINITY
            ? wsUpdated
            : parseTimestampMs(workspace.createdAt);
        }
        if (latest > bestTime) {
          bestTime = latest;
          bestId = wid;
        }
      }
      if (bestId && bestTime > Number.NEGATIVE_INFINITY) {
        return bestId;
      }

      var defaultWsId = workspacesSnapshot && typeof workspacesSnapshot.defaultWorkspaceId === "string"
        ? workspacesSnapshot.defaultWorkspaceId.trim()
        : "";
      if (defaultWsId) return defaultWsId;

      if (items.length > 0) {
        var firstId = workspaceIdOf(items[0]);
        if (firstId) return firstId;
      }

      return null;
    }

    function resolveClientLanguage(ctx, doc) {
      var localeSvc = getService(ctx, "locale");
      var active = "";
      if (localeSvc) {
        if (typeof localeSvc.getSnapshot === "function") {
          var snap = localeSvc.getSnapshot();
          if (snap && typeof snap.active === "string") active = snap.active;
        } else if (typeof localeSvc.current === "string") {
          active = localeSvc.current;
        } else if (typeof localeSvc.locale === "string") {
          active = localeSvc.locale;
        }
      }
      if (!active && doc && doc.documentElement) {
        active = String(getAttr(doc.documentElement, "lang") || doc.documentElement.lang || "");
      }
      if (!active && typeof navigator !== "undefined" && navigator && navigator.language) {
        active = String(navigator.language);
      }
      return /^zh\b/i.test(active.trim()) ? "zh" : "en";
    }

    function isDisallowedAncestor(el) {
      var tag = getTagName(el);
      if (tag === "textarea" || tag === "input" || tag === "nav" || tag === "aside") {
        return true;
      }
      if (hasClass(el, "LexicalEditor")) return true;
      var role = String(getAttr(el, "role") || "").trim().toLowerCase();
      if (role === "textbox" || role === "navigation") return true;
      if (hasAttr(el, "data-sidebar") || hasAttr(el, "hidden") || hasAttr(el, "inert")) {
        return true;
      }
      if (hasAttr(el, "data-text-interaction-exclude")) return true;
      var ce = getAttr(el, "contenteditable");
      if (ce !== null && String(ce).trim().toLowerCase() !== "false") {
        return true;
      }
      if (el.isContentEditable === true) return true;
      return false;
    }

    function isValidChatSelection(selection) {
      if (!selection || selection.isCollapsed || !(selection.rangeCount > 0)) return false;
      var text = typeof selection.toString === "function" ? selection.toString() : "";
      if (!String(text || "").trim()) return false;
      var range = typeof selection.getRangeAt === "function" ? selection.getRangeAt(0) : null;
      if (!range || !range.startContainer || !range.endContainer) return false;

      var startSource = closestElement(range.startContainer, function (el) {
        return hasAttr(el, "data-text-interaction-source");
      });
      var endSource = closestElement(range.endContainer, function (el) {
        return hasAttr(el, "data-text-interaction-source");
      });
      if (!startSource || !endSource) return false;

      if (closestElement(range.startContainer, isDisallowedAncestor)) return false;
      if (closestElement(range.endContainer, isDisallowedAncestor)) return false;
      return true;
    }

    function normalizeRect(raw) {
      if (!raw) return null;
      var left = Number(raw.left);
      var top = Number(raw.top);
      var width = Number(raw.width);
      var height = Number(raw.height);
      if (!Number.isFinite(left) || !Number.isFinite(top)) return null;
      width = Number.isFinite(width) ? width : 0;
      height = Number.isFinite(height) ? height : 0;
      var right = typeof raw.right === "number" && Number.isFinite(raw.right) ? raw.right : left + width;
      var bottom = typeof raw.bottom === "number" && Number.isFinite(raw.bottom) ? raw.bottom : top + height;
      return { left: left, top: top, width: width, height: height, right: right, bottom: bottom };
    }

    function findComposerTop(doc, selectionBottom) {
      if (!doc || typeof doc.querySelectorAll !== "function") return null;
      var nodes = Array.from(doc.querySelectorAll('.LexicalEditor, [contenteditable="true"], textarea'));
      var minTop = null;
      for (var i = 0; i < nodes.length; i += 1) {
        var el = nodes[i];
        if (!el || typeof el.getBoundingClientRect !== "function") continue;
        var rect = normalizeRect(el.getBoundingClientRect());
        if (!rect || (rect.width <= 0 && rect.height <= 0)) continue;
        if (rect.top >= selectionBottom - 4) {
          if (minTop === null || rect.top < minTop) minTop = rect.top;
        }
      }
      return minTop;
    }

    function computePillPosition(opts) {
      var range = opts && opts.range;
      if (!range) return null;
      var pillWidth = Number(opts.pillWidth) || 72;
      var pillHeight = Number(opts.pillHeight) || 26;
      var vw = Number(opts.viewportWidth) || 1200;
      var vh = Number(opts.viewportHeight) || 800;

      var rawRects = typeof range.getClientRects === "function"
        ? Array.from(range.getClientRects() || [])
        : [];
      var rects = rawRects
        .map(normalizeRect)
        .filter(function (r) { return r && (r.width > 0 || r.height > 0); });

      if (rects.length === 0 && typeof range.getBoundingClientRect === "function") {
        var fallback = normalizeRect(range.getBoundingClientRect());
        if (fallback && (fallback.width > 0 || fallback.height > 0)) rects.push(fallback);
      }
      if (rects.length === 0) return null;

      var topRect = rects[0];
      var bottomRect = rects[0];
      for (var i = 1; i < rects.length; i += 1) {
        if (rects[i].top < topRect.top) topRect = rects[i];
        if (rects[i].bottom > bottomRect.bottom) bottomRect = rects[i];
      }

      var centerX = bottomRect.left + bottomRect.width / 2;
      var maxLeft = Math.max(VIEWPORT_MARGIN, vw - pillWidth - VIEWPORT_MARGIN);
      var left = Math.round(Math.min(maxLeft, Math.max(VIEWPORT_MARGIN, centerX - pillWidth / 2)));

      var composerTop = typeof opts.composerTop === "number" && Number.isFinite(opts.composerTop)
        ? opts.composerTop
        : findComposerTop(opts.doc, bottomRect.bottom);
      var bottomLimit = vh - VIEWPORT_MARGIN;
      if (composerTop !== null && composerTop - PILL_GAP < bottomLimit) {
        bottomLimit = composerTop - PILL_GAP;
      }

      var belowTop = bottomRect.bottom + PILL_GAP;
      var aboveTop = topRect.top - pillHeight - PILL_GAP;
      var placement = "below";
      var top = belowTop;

      if (belowTop + pillHeight > bottomLimit && aboveTop >= VIEWPORT_MARGIN) {
        top = aboveTop;
        placement = "above";
      }

      var maxTop = Math.max(VIEWPORT_MARGIN, vh - pillHeight - VIEWPORT_MARGIN);
      top = Math.round(Math.min(maxTop, Math.max(VIEWPORT_MARGIN, top)));
      return { left: left, top: top, placement: placement };
    }

    function extractCodeLanguage(el) {
      var cur = el;
      for (var depth = 0; depth < 3 && cur && cur.nodeType === ELEMENT_NODE; depth += 1) {
        var dataLang = getAttr(cur, "data-language") || getAttr(cur, "data-lang");
        if (dataLang && String(dataLang).trim()) {
          return String(dataLang).trim().replace(/[^a-zA-Z0-9_+#.-]/g, "");
        }
        var cls = getClassString(cur);
        var match = cls.match(/(?:^|\s)(?:language-|lang-)([a-zA-Z0-9_+#.-]+)/);
        if (match) return match[1];
        cur = parentElementOf(cur);
      }
      return "";
    }

    function extractCodeText(node) {
      if (!node) return "";
      if (node.nodeType === TEXT_NODE) {
        return String(node.nodeValue !== undefined && node.nodeValue !== null ? node.nodeValue : (node.textContent || ""));
      }
      if (node.nodeType !== ELEMENT_NODE && node.nodeType !== DOCUMENT_FRAGMENT_NODE) return "";
      if (node.nodeType === ELEMENT_NODE) {
        var tag = getTagName(node);
        if (tag === "br") return "\n";
        if (tag === "button" || tag === "svg" || hasAttr(node, "data-text-interaction-exclude")) {
          return "";
        }
      }
      var children = Array.from(node.childNodes || []);
      var out = "";
      for (var i = 0; i < children.length; i += 1) {
        out += extractCodeText(children[i]);
      }
      return out;
    }

    function formatFencedCodeBlock(rawCode, language) {
      var normalized = String(rawCode || "").replace(/\r\n?/g, "\n").replace(/^\n+|\n+$/g, "");
      var runs = normalized.match(/`{3,}/g) || [];
      var fenceLen = 3;
      for (var i = 0; i < runs.length; i += 1) {
        if (runs[i].length >= fenceLen) fenceLen = runs[i].length + 1;
      }
      var fence = "`".repeat(fenceLen);
      var safeLang = String(language || "").replace(/[^a-zA-Z0-9_+#.-]/g, "");
      return "\n\n" + fence + safeLang + "\n" + normalized + "\n" + fence + "\n\n";
    }

    function formatInlineCode(rawText) {
      var text = String(rawText || "").replace(/\r?\n/g, " ");
      if (!text) return "";
      var pad = text.startsWith("`") || text.endsWith("`") ? " " : "";
      if (!text.includes("`")) return "`" + pad + text + pad + "`";
      var runs = text.match(/`+/g) || [];
      var maxLen = 1;
      for (var i = 0; i < runs.length; i += 1) {
        if (runs[i].length >= maxLen) maxLen = runs[i].length + 1;
      }
      var ticks = "`".repeat(maxLen);
      return ticks + pad + text + pad + ticks;
    }

    function findPrimaryCodeElement(preNode) {
      var children = Array.from((preNode && preNode.childNodes) || []);
      for (var i = 0; i < children.length; i += 1) {
        if (children[i] && children[i].nodeType === ELEMENT_NODE && getTagName(children[i]) === "code") {
          return children[i];
        }
      }
      if (preNode && typeof preNode.querySelector === "function") {
        return preNode.querySelector("code");
      }
      return null;
    }

    function preservesLineBreaks(node) {
      var el = parentElementOf(node);
      var view = el && el.ownerDocument && el.ownerDocument.defaultView;
      if (!view || typeof view.getComputedStyle !== "function") return false;
      try {
        var ws = view.getComputedStyle(el).whiteSpace;
        return ws === "pre" || ws === "pre-wrap" || ws === "pre-line" || ws === "break-spaces";
      } catch {
        return false;
      }
    }

    function collectNonEmptyTextNodes(node, out) {
      if (!node) return;
      if (node.nodeType === TEXT_NODE) {
        var val = node.nodeValue !== undefined && node.nodeValue !== null ? node.nodeValue : (node.textContent || "");
        if (val) out.push(node);
        return;
      }
      var children = Array.from(node.childNodes || []);
      for (var i = 0; i < children.length; i += 1) {
        collectNonEmptyTextNodes(children[i], out);
      }
    }

    function buildLineBreakModes(range, fragment) {
      var modes = new WeakMap();
      if (!range || !range.commonAncestorContainer || typeof range.intersectsNode !== "function") {
        return modes;
      }
      var allSource = [];
      collectNonEmptyTextNodes(range.commonAncestorContainer, allSource);
      var selectedSource = [];
      for (var i = 0; i < allSource.length; i += 1) {
        var n = allSource[i];
        if (!range.intersectsNode(n)) continue;
        var val = n.nodeValue || "";
        var start = n === range.startContainer ? Number(range.startOffset) || 0 : 0;
        var end = n === range.endContainer ? Number(range.endOffset) || 0 : val.length;
        if (end > start) selectedSource.push(n);
      }
      var cloned = [];
      collectNonEmptyTextNodes(fragment, cloned);
      var len = Math.min(selectedSource.length, cloned.length);
      for (var j = 0; j < len; j += 1) {
        modes.set(cloned[j], preservesLineBreaks(selectedSource[j]));
      }
      return modes;
    }

    function wrapInlineMarker(content, marker) {
      if (!content || !content.trim()) return content;
      var leading = (content.match(/^\s*/) || [""])[0];
      var trailing = (content.match(/\s*$/) || [""])[0];
      var core = content.slice(leading.length, content.length - trailing.length);
      return leading + marker + core + marker + trailing;
    }

    function normalizeMarkdownSpacing(md) {
      if (!md) return "";
      var lines = String(md).replace(/\r\n?/g, "\n").split("\n");
      var out = [];
      var inFence = false;
      var fenceMarker = "";

      for (var i = 0; i < lines.length; i += 1) {
        var line = lines[i];
        var fenceMatch = line.match(/^(`{3,})/);
        if (fenceMatch) {
          if (!inFence) {
            inFence = true;
            fenceMarker = fenceMatch[1];
          } else if (line.startsWith(fenceMarker) && line.slice(fenceMarker.length).trim() === "") {
            inFence = false;
            fenceMarker = "";
          }
          out.push(line);
          continue;
        }
        if (inFence) {
          out.push(line);
        } else {
          var normalized = line.replace(/[ \t]+$/g, "");
          if (normalized || out[out.length - 1] !== "") {
            out.push(normalized);
          }
        }
      }

      return out.join("\n").trim();
    }

    function renderList(listEl, ordered, ctx) {
      var depth = ctx.listDepth || 0;
      var indent = "  ".repeat(depth);
      var startAttr = parseInt(getAttr(listEl, "start") || "1", 10);
      var index = Number.isFinite(startAttr) && startAttr > 0 ? startAttr : 1;
      var lines = [];
      var children = Array.from(listEl.childNodes || []);

      for (var i = 0; i < children.length; i += 1) {
        var child = children[i];
        if (!child || child.nodeType !== ELEMENT_NODE || getTagName(child) !== "li") continue;
        var itemInline = "";
        var nested = "";
        var liChildren = Array.from(child.childNodes || []);
        for (var j = 0; j < liChildren.length; j += 1) {
          var lc = liChildren[j];
          if (lc && lc.nodeType === ELEMENT_NODE) {
            var lcTag = getTagName(lc);
            if (lcTag === "ul" || lcTag === "ol") {
              nested += "\n" + renderList(lc, lcTag === "ol", {
                listDepth: depth + 1,
                lineBreakModes: ctx.lineBreakModes,
              }).trimEnd();
              continue;
            }
          }
          itemInline += convertNode(lc, { listDepth: depth + 1, lineBreakModes: ctx.lineBreakModes });
        }
        var body = normalizeMarkdownSpacing(itemInline)
          .split("\n")
          .map(function (l, idx) { return idx === 0 ? l : indent + "  " + l; })
          .join("\n")
          .trim();
        var marker = ordered ? index + ". " : "- ";
        index += 1;
        lines.push(indent + marker + body + nested);
      }

      if (lines.length === 0) return "";
      return depth === 0 ? "\n\n" + lines.join("\n") + "\n\n" : lines.join("\n");
    }

    function convertChildren(node, ctx) {
      var children = Array.from((node && node.childNodes) || []);
      var out = "";
      for (var i = 0; i < children.length; i += 1) {
        out += convertNode(children[i], ctx);
      }
      return out;
    }

    function convertNode(node, ctx) {
      if (!node) return "";
      if (node.nodeType === TEXT_NODE) {
        var raw = node.nodeValue !== undefined && node.nodeValue !== null ? node.nodeValue : (node.textContent || "");
        if (!raw) return "";
        if ((ctx.lineBreakModes && ctx.lineBreakModes.get(node)) || preservesLineBreaks(node)) {
          return raw.replace(/\r\n?/g, "\n").replace(/[ \t]+/g, " ");
        }
        return raw.replace(/[ \t\r\n]+/g, " ");
      }
      if (node.nodeType === DOCUMENT_FRAGMENT_NODE || node.nodeType === DOCUMENT_NODE) {
        return convertChildren(node, ctx);
      }
      if (node.nodeType !== ELEMENT_NODE) return "";

      var tag = getTagName(node);
      if (SKIP_TAGS.has(tag)) return "";
      if (hasAttr(node, "data-text-interaction-exclude")) return "";
      if (getAttr(node, "aria-hidden") === "true") return "";

      if (tag === "br") return "\n";
      if (tag === "hr") return "\n\n---\n\n";

      if (tag === "pre") {
        var codeEl = findPrimaryCodeElement(node);
        var lang = extractCodeLanguage(codeEl || node);
        var rawCode = extractCodeText(codeEl || node);
        return formatFencedCodeBlock(rawCode, lang);
      }

      if (tag === "code" || getAttr(node, "data-markdown-copy") === "inline-code") {
        return formatInlineCode(extractCodeText(node));
      }

      if (/^h[1-6]$/.test(tag)) {
        var level = Number(tag[1]);
        var heading = normalizeMarkdownSpacing(convertChildren(node, ctx));
        return heading ? "\n\n" + "#".repeat(level) + " " + heading + "\n\n" : "";
      }

      if (tag === "strong" || tag === "b") {
        return wrapInlineMarker(convertChildren(node, ctx), "**");
      }

      if (tag === "em" || tag === "i") {
        return wrapInlineMarker(convertChildren(node, ctx), "*");
      }

      if (tag === "del" || tag === "s") {
        return wrapInlineMarker(convertChildren(node, ctx), "~~");
      }

      if (tag === "a") {
        var label = convertChildren(node, ctx).trim();
        var href = String(getAttr(node, "href") || "").trim();
        if (!href || !/^(https?:|mailto:)/i.test(href)) return label;
        return "[" + (label || href) + "](" + href + ")";
      }

      if (tag === "ul" || tag === "ol") {
        return renderList(node, tag === "ol", ctx);
      }

      if (tag === "blockquote") {
        var innerQuote = normalizeMarkdownSpacing(convertChildren(node, ctx));
        if (!innerQuote) return "";
        var quoted = innerQuote
          .split("\n")
          .map(function (line) { return line ? "> " + line : ">"; })
          .join("\n");
        return "\n\n" + quoted + "\n\n";
      }

      if (tag === "p" || tag === "section" || tag === "article") {
        var pText = convertChildren(node, ctx).trim();
        return pText ? "\n\n" + pText + "\n\n" : "";
      }

      if (tag === "li") {
        var liText = convertChildren(node, ctx).trim();
        return liText ? "\n- " + liText + "\n" : "";
      }

      if (tag === "div") {
        var divText = convertChildren(node, ctx);
        return divText.trim() ? "\n" + divText + "\n" : "";
      }

      return convertChildren(node, ctx);
    }

    function extractSelectionMarkdown(range, fallbackText) {
      if (!range || typeof range.cloneContents !== "function") {
        return String(fallbackText || "").trim();
      }

      var startPre = closestElement(range.startContainer, function (el) {
        return getTagName(el) === "pre";
      });
      var endPre = closestElement(range.endContainer, function (el) {
        return getTagName(el) === "pre";
      });
      if (startPre && startPre === endPre) {
        var preFrag = range.cloneContents();
        var codeNode = findPrimaryCodeElement(startPre) || startPre;
        var lang = extractCodeLanguage(codeNode);
        var raw = extractCodeText(preFrag);
        return formatFencedCodeBlock(raw || fallbackText || "", lang).trim();
      }

      var startCode = closestElement(range.startContainer, function (el) {
        return getTagName(el) === "code" || getAttr(el, "data-markdown-copy") === "inline-code";
      });
      var endCode = closestElement(range.endContainer, function (el) {
        return getTagName(el) === "code" || getAttr(el, "data-markdown-copy") === "inline-code";
      });
      if (startCode && startCode === endCode && !startPre) {
        var codeFrag = range.cloneContents();
        var inlineRaw = extractCodeText(codeFrag);
        return formatInlineCode(inlineRaw || fallbackText || "");
      }

      var fragment = range.cloneContents();
      var lineBreakModes = buildLineBreakModes(range, fragment);
      var md = normalizeMarkdownSpacing(convertNode(fragment, { listDepth: 0, lineBreakModes: lineBreakModes }));
      return md || String(fallbackText || "").trim();
    }

    async function executeCommand(ctx, command) {
      if (!command || typeof command !== "object") {
        return { ok: false, error: "invalid_command" };
      }

      if (command.kind === "prefillDraft") {
        var sessions = getService(ctx, "sessions");
        var workspaces = getService(ctx, "workspaces");
        var uiWorkspace = getService(ctx, "uiWorkspace");
        var conversation = getService(ctx, "conversation");

        if (
          !sessions ||
          !sessions.list ||
          typeof sessions.list.getSnapshot !== "function" ||
          !workspaces ||
          !workspaces.list ||
          typeof workspaces.list.getSnapshot !== "function" ||
          !uiWorkspace ||
          typeof uiWorkspace.openWorkspace !== "function" ||
          !conversation ||
          !conversation.input ||
          typeof conversation.input.requestDraftInitialization !== "function"
        ) {
          return { ok: false, error: "services_unavailable" };
        }

        var targetWorkspaceId = resolveTargetWorkspaceId(
          sessions.list.getSnapshot(),
          workspaces.list.getSnapshot(),
        );
        if (!targetWorkspaceId) {
          return { ok: false, error: "no_workspace" };
        }

        var openedSessionId = null;
        var draftResult = null;
        try {
          await uiWorkspace.openWorkspace(targetWorkspaceId, function (sessionId) {
            openedSessionId = sessionId;
            var binding = typeof sessions.binding === "function" ? sessions.binding(sessionId) : null;
            if (!binding) {
              draftResult = "blocked";
              throw new Error("draft_blocked");
            }
            draftResult = conversation.input.requestDraftInitialization(binding, {
              prompt: command.prompt,
              whenDraftExists: "append",
            });
            if (draftResult === "blocked") {
              throw new Error("draft_blocked");
            }
          });
        } catch (err) {
          return {
            ok: false,
            error: (err && err.message) || "open_workspace_failed",
          };
        }

        if (!openedSessionId) {
          return { ok: false, error: "open_superseded" };
        }
        if (draftResult !== "applied") {
          return {
            ok: false,
            error: draftResult === "preserved" ? "draft_preserved" : "draft_blocked",
          };
        }
        return { ok: true, sessionId: openedSessionId };
      }

      if (command.kind === "openSession") {
        var sessSvc = getService(ctx, "sessions");
        var uiWs = getService(ctx, "uiWorkspace");
        if (
          !sessSvc ||
          !sessSvc.list ||
          typeof sessSvc.list.getSnapshot !== "function" ||
          !uiWs ||
          typeof uiWs.openSession !== "function"
        ) {
          return { ok: false, error: "services_unavailable" };
        }

        var sessionId = typeof command.sessionId === "string" ? command.sessionId : "";
        if (!sessionId) return { ok: false, error: "session_not_found" };

        var snap = sessSvc.list.getSnapshot();
        var exists = Boolean(snap && snap.byId && snap.byId[sessionId]);
        if (!exists && typeof sessSvc.refresh === "function") {
          try {
            await sessSvc.refresh();
          } catch {
          }
          snap = sessSvc.list.getSnapshot();
          exists = Boolean(snap && snap.byId && snap.byId[sessionId]);
        }
        if (!exists) {
          return { ok: false, error: "session_not_found" };
        }

        try {
          await uiWs.openSession(sessionId);
          return { ok: true, sessionId: sessionId };
        } catch (err) {
          return { ok: false, error: (err && err.message) || "open_session_failed" };
        }
      }

      return { ok: false, error: "unknown_command" };
    }

    function createClientId() {
      try {
        if (typeof crypto !== "undefined" && crypto && typeof crypto.randomUUID === "function") {
          return crypto.randomUUID();
        }
      } catch {
      }
      return "dsh-" + Date.now() + "-" + Math.random().toString(36).slice(2, 10);
    }

    function resolveApiUrl(baseOrigin) {
      if (baseOrigin) return baseOrigin.replace(/\/+$/, "") + API_PATH;
      try {
        if (typeof window !== "undefined" && window.location && window.location.origin && window.location.origin !== "null") {
          return new URL(API_PATH, window.location.origin).toString();
        }
      } catch {
      }
      return API_PATH;
    }

    function apply(ctx, options) {
      var opts = options || {};
      var fetchImpl = opts.fetch || (typeof fetch === "function"
        ? function (url, init) { return fetch(url, init); }
        : null);
      var doc = opts.document || (typeof document !== "undefined" ? document : null);
      var win = opts.window || (typeof window !== "undefined" ? window : null);
      var apiUrl = resolveApiUrl(opts.baseOrigin);
      var pollTimeoutMs = typeof opts.pollTimeoutMs === "number" ? opts.pollTimeoutMs : POLL_TIMEOUT_MS;
      var feedbackHoldMs = typeof opts.feedbackHoldMs === "number" ? opts.feedbackHoldMs : FEEDBACK_HOLD_MS;
      var selectionDebounceMs = typeof opts.selectionDebounceMs === "number"
        ? opts.selectionDebounceMs
        : SELECTION_DEBOUNCE_MS;

      var clientId = opts.clientId || createClientId();
      var abortController = new AbortController();
      var disposed = false;

      var activeTimers = new Set();
      var domListeners = [];
      var unsubscribers = [];

      var currentActiveSession = { sessionId: null, sessionTitle: "" };
      var lastReportedActiveKey = "";
      var subscribedSessionLists = new WeakSet();

      var shadowHost = null;
      var shadowRoot = null;
      var pillEl = null;
      var pillIconEl = null;
      var pillLabelEl = null;
      var pillState = "hidden";
      var pillHoldTimer = null;
      var selectionCheckTimer = null;
      var suppressNextMouseUp = false;
      var activeCaptureSeq = 0;

      function scheduleTimer(fn, ms) {
        if (disposed) return null;
        var id = setTimeout(function () {
          activeTimers.delete(id);
          if (!disposed) fn();
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

      function addListener(target, type, fn, capture) {
        if (!target || typeof target.addEventListener !== "function") return;
        var wrapped = function (ev) {
          if (!disposed) fn(ev);
        };
        target.addEventListener(type, wrapped, capture || false);
        domListeners.push({ target: target, type: type, wrapped: wrapped, capture: capture || false });
      }

      async function postApi(payload, extraInit) {
        if (!fetchImpl) throw new Error("fetch_unavailable");
        var init = Object.assign(
          {
            method: "POST",
            cache: "no-store",
            credentials: "same-origin",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(payload),
            signal: abortController.signal,
          },
          extraInit || {},
        );
        var resp = await fetchImpl(apiUrl, init);
        var text = await resp.text();
        var data = text ? JSON.parse(text) : null;
        if (!resp.ok) {
          throw new Error((data && data.error) || ("http_" + resp.status));
        }
        return data;
      }

      function getCopy() {
        var lang = resolveClientLanguage(ctx, doc);
        return COPY[lang] || COPY.en;
      }

      function syncHostTheme() {
        if (!shadowHost || !doc || !doc.documentElement) return;
        var html = doc.documentElement;
        var attrTheme = String(getAttr(html, "data-theme") || "").toLowerCase();
        if (attrTheme === "dark" || hasClass(html, "dark")) {
          shadowHost.setAttribute("data-theme", "dark");
        } else if (attrTheme === "light" || hasClass(html, "light")) {
          shadowHost.setAttribute("data-theme", "light");
        } else if (typeof shadowHost.removeAttribute === "function") {
          shadowHost.removeAttribute("data-theme");
        }
      }

      function applyPillState(nextState) {
        if (!pillEl) return;
        pillState = nextState;
        var copy = getCopy();
        pillEl.setAttribute("data-state", nextState);
        pillEl.setAttribute("aria-label", copy.ariaLabel);

        if (nextState === "saving") {
          pillIconEl.hidden = false;
          pillIconEl.textContent = "…";
          pillLabelEl.textContent = copy.saving;
        } else if (nextState === "saved") {
          pillIconEl.hidden = false;
          pillIconEl.textContent = "✓";
          pillLabelEl.textContent = copy.saved;
        } else if (nextState === "queued") {
          pillIconEl.hidden = false;
          pillIconEl.textContent = "✓";
          pillLabelEl.textContent = copy.queued;
        } else if (nextState === "not_running") {
          pillIconEl.hidden = false;
          pillIconEl.textContent = "!";
          pillLabelEl.textContent = copy.notRunning;
        } else if (nextState === "error") {
          pillIconEl.hidden = false;
          pillIconEl.textContent = "×";
          pillLabelEl.textContent = copy.failed;
        } else {
          pillIconEl.hidden = true;
          pillIconEl.textContent = "";
          pillLabelEl.textContent = copy.ready;
        }
      }

      function hidePill() {
        activeCaptureSeq += 1;
        cancelTimer(pillHoldTimer);
        pillHoldTimer = null;
        pillState = "hidden";
        if (pillEl) {
          pillEl.setAttribute("data-state", "hidden");
          pillEl.style.display = "none";
        }
      }

      function isEventInsidePill(event) {
        if (!event || !pillEl || pillState === "hidden" || pillEl.style.display === "none") {
          return false;
        }
        if (typeof event.composedPath === "function") {
          var path = event.composedPath();
          if (Array.isArray(path) && (path.includes(pillEl) || (shadowHost && path.includes(shadowHost)))) {
            return true;
          }
        }
        return event.target === pillEl || Boolean(shadowHost && event.target === shadowHost);
      }

      function ensurePillDom() {
        if (!doc || typeof doc.createElement !== "function") return null;
        if (shadowHost && shadowHost.isConnected !== false && pillEl) {
          syncHostTheme();
          return shadowRoot;
        }

        if (typeof doc.querySelectorAll === "function") {
          var stale = Array.from(doc.querySelectorAll('[data-coding-rewind-dsh-ui="1"]'));
          for (var i = 0; i < stale.length; i += 1) {
            if (typeof stale[i].remove === "function") stale[i].remove();
          }
        }

        shadowHost = doc.createElement("div");
        shadowHost.setAttribute("data-coding-rewind-dsh-ui", "1");
        shadowHost.style.cssText =
          "position:fixed !important;top:0 !important;left:0 !important;width:0 !important;height:0 !important;overflow:visible !important;pointer-events:none !important;z-index:2147483647 !important;user-select:none !important;-webkit-user-select:none !important;";
        syncHostTheme();

        shadowRoot = shadowHost.attachShadow({ mode: "closed" });

        var style = doc.createElement("style");
        style.textContent = [
          ":host {",
          "  position: fixed !important;",
          "  top: 0 !important;",
          "  left: 0 !important;",
          "  width: 0 !important;",
          "  height: 0 !important;",
          "  overflow: visible !important;",
          "  pointer-events: none !important;",
          "  z-index: 2147483647 !important;",
          "  color-scheme: light dark;",
          "  --rw-text: #202124;",
          "  --rw-pill-bg: #ffffff;",
          "  --rw-pill-hover: #f6f6f7;",
          "  --rw-pill-border: rgba(0, 0, 0, 0.09);",
          "  --rw-accent: #0068d9;",
          "  --rw-success: #16713b;",
          "  --rw-warning: #9b5c06;",
          "  --rw-error: #b52632;",
          "}",
          "@media (prefers-color-scheme: dark) {",
          "  :host(:not([data-theme='light'])) {",
          "    --rw-text: #f2f3f4;",
          "    --rw-pill-bg: #242428;",
          "    --rw-pill-hover: #2f2f35;",
          "    --rw-pill-border: rgba(255, 255, 255, 0.14);",
          "    --rw-accent: #0a84ff;",
          "    --rw-success: #7ddc9d;",
          "    --rw-warning: #f4bd6d;",
          "    --rw-error: #ff9199;",
          "  }",
          "}",
          ":host([data-theme='dark']) {",
          "  --rw-text: #f2f3f4;",
          "  --rw-pill-bg: #242428;",
          "  --rw-pill-hover: #2f2f35;",
          "  --rw-pill-border: rgba(255, 255, 255, 0.14);",
          "  --rw-accent: #0a84ff;",
          "  --rw-success: #7ddc9d;",
          "  --rw-warning: #f4bd6d;",
          "  --rw-error: #ff9199;",
          "}",
          ".rw-pill {",
          "  box-sizing: border-box;",
          "  position: fixed;",
          "  display: none;",
          "  align-items: center;",
          "  gap: 5px;",
          "  height: 26px;",
          "  padding: 0 10px;",
          "  border-radius: 999px;",
          "  background: var(--rw-pill-bg);",
          "  color: var(--rw-text);",
          "  border: 1px solid var(--rw-pill-border);",
          "  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.10), 0 1px 2px rgba(0, 0, 0, 0.05);",
          "  font: 500 12px/1 -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'PingFang SC', sans-serif;",
          "  cursor: pointer;",
          "  pointer-events: auto;",
          "  user-select: none;",
          "  white-space: nowrap;",
          "}",
          ".rw-pill[data-state='ready']:hover { background: var(--rw-pill-hover); }",
          ".rw-pill[data-state='saving'], .rw-pill[data-state='saved'], .rw-pill[data-state='queued'], .rw-pill[data-state='not_running'], .rw-pill[data-state='error'] { cursor: default; }",
          ".rw-pill-icon { font-weight: 600; font-size: 12px; line-height: 1; color: var(--rw-accent); }",
          ".rw-pill-icon[hidden] { display: none; }",
          ".rw-pill[data-state='saved'] .rw-pill-icon { color: var(--rw-success); }",
          ".rw-pill[data-state='queued'] .rw-pill-icon { color: var(--rw-warning); }",
          ".rw-pill[data-state='not_running'] .rw-pill-icon { color: var(--rw-warning); }",
          ".rw-pill[data-state='error'] .rw-pill-icon { color: var(--rw-error); }",
        ].join("\n");

        pillEl = doc.createElement("button");
        pillEl.type = "button";
        pillEl.className = "rw-pill";
        pillEl.tabIndex = -1;

        pillIconEl = doc.createElement("span");
        pillIconEl.className = "rw-pill-icon";
        pillIconEl.setAttribute("aria-hidden", "true");

        pillLabelEl = doc.createElement("span");
        pillLabelEl.className = "rw-pill-label";

        pillEl.append(pillIconEl, pillLabelEl);
        applyPillState("ready");
        pillState = "hidden";
        pillEl.setAttribute("data-state", "hidden");
        pillEl.style.display = "none";

        addListener(pillEl, "mousedown", function (event) {
          if (!event) return;
          if (typeof event.button === "number" && event.button !== 0) return;
          suppressNextMouseUp = true;
          event.preventDefault?.();
          event.stopPropagation?.();
          if (pillState !== "ready") return;
          void captureCurrentSelection();
        });

        shadowRoot.append(style, pillEl);
        var container = doc.documentElement || doc.body;
        if (container && typeof container.appendChild === "function") {
          container.appendChild(shadowHost);
        }
        return shadowRoot;
      }

      function showFeedback(state) {
        if (!pillEl || disposed) return;
        cancelTimer(pillHoldTimer);
        pillEl.style.display = "inline-flex";
        applyPillState(state);
        pillHoldTimer = scheduleTimer(function () {
          pillHoldTimer = null;
          hidePill();
        }, feedbackHoldMs);
      }

      function refreshActiveSessionSnapshot() {
        var sessions = getService(ctx, "sessions");
        if (!sessions || !sessions.list || typeof sessions.list.getSnapshot !== "function") {
          return currentActiveSession;
        }
        var active = findActiveSession(sessions.list.getSnapshot());
        if (active) {
          currentActiveSession = active;
        }
        return currentActiveSession;
      }

      async function captureCurrentSelection() {
        var selection = win && typeof win.getSelection === "function" ? win.getSelection() : null;
        if (!isValidChatSelection(selection)) {
          hidePill();
          return;
        }
        var range = selection.getRangeAt(0);
        var fallback = typeof selection.toString === "function" ? selection.toString() : "";
        var markdown = extractSelectionMarkdown(range, fallback);
        if (!markdown || !markdown.trim()) {
          hidePill();
          return;
        }

        var seq = ++activeCaptureSeq;
        cancelTimer(pillHoldTimer);
        applyPillState("saving");

        var active = refreshActiveSessionSnapshot();
        try {
          var result = await postApi({
            op: "capture",
            text: markdown,
            sessionId: active.sessionId || null,
            sessionTitle: active.sessionTitle || "",
          });
          if (disposed || seq !== activeCaptureSeq) return;

          if (result && result.ok === true) {
            showFeedback(result.state === "queued_offline" ? "queued" : "saved");
          } else if (result && result.error === "coding_rewind_not_running") {
            showFeedback("not_running");
          } else {
            showFeedback("error");
          }
        } catch {
          if (disposed || seq !== activeCaptureSeq) return;
          showFeedback("error");
        }
      }

      function updatePillFromSelection() {
        if (disposed || !win || !doc) return;
        if (pillState === "saving") return;

        var selection = typeof win.getSelection === "function" ? win.getSelection() : null;
        if (!isValidChatSelection(selection)) {
          if (pillState === "ready") hidePill();
          return;
        }

        var range = selection.getRangeAt(0);
        ensurePillDom();
        if (!pillEl) return;

        applyPillState("ready");
        pillEl.style.display = "inline-flex";
        var pos = computePillPosition({
          range: range,
          pillWidth: pillEl.offsetWidth || 72,
          pillHeight: pillEl.offsetHeight || 26,
          viewportWidth: win.innerWidth || 1200,
          viewportHeight: win.innerHeight || 800,
          doc: doc,
        });
        if (!pos) {
          hidePill();
          return;
        }
        pillEl.style.left = pos.left + "px";
        pillEl.style.top = pos.top + "px";
        pillEl.setAttribute("data-placement", pos.placement);
      }

      function scheduleSelectionUpdate(delayMs) {
        cancelTimer(selectionCheckTimer);
        selectionCheckTimer = scheduleTimer(function () {
          selectionCheckTimer = null;
          updatePillFromSelection();
        }, delayMs);
      }

      function reportActiveSessionIfChanged() {
        if (disposed) return;
        var active = refreshActiveSessionSnapshot();
        if (!active || !active.sessionId) return;
        var key = active.sessionId + "\0" + (active.sessionTitle || "");
        if (key === lastReportedActiveKey) return;
        lastReportedActiveKey = key;
        if (fetchImpl) {
          void postApi({
            op: "activeSession",
            sessionId: active.sessionId,
            sessionTitle: active.sessionTitle || "",
          }).catch(function () {});
        }
      }

      function bindSessionsService(sessions) {
        if (!sessions || !sessions.list || typeof sessions.list.subscribe !== "function") return;
        if (subscribedSessionLists.has(sessions.list)) return;
        subscribedSessionLists.add(sessions.list);
        reportActiveSessionIfChanged();
        var unsub = sessions.list.subscribe(function () {
          reportActiveSessionIfChanged();
        });
        if (typeof unsub === "function") unsubscribers.push(unsub);
      }

      function bindLocaleService(localeSvc) {
        if (!localeSvc || typeof localeSvc.subscribe !== "function") return;
        var unsub = localeSvc.subscribe(function () {
          if (pillEl && pillState !== "hidden") {
            applyPillState(pillState);
          }
        });
        if (typeof unsub === "function") unsubscribers.push(unsub);
      }

      if (doc) {
        addListener(doc, "mousedown", function (event) {
          if (!event) return;
          if (typeof event.button === "number" && event.button !== 0) return;
          if (isEventInsidePill(event)) {
            suppressNextMouseUp = true;
            return;
          }
          suppressNextMouseUp = false;
          cancelTimer(selectionCheckTimer);
          selectionCheckTimer = null;
          if (pillState !== "saving") hidePill();
        }, true);

        addListener(doc, "mouseup", function (event) {
          if (!event) return;
          if (typeof event.button === "number" && event.button !== 0) return;
          if (suppressNextMouseUp) {
            suppressNextMouseUp = false;
            return;
          }
          if (isEventInsidePill(event)) return;
          scheduleSelectionUpdate(0);
        });

        addListener(doc, "keyup", function (event) {
          if (event && event.key === "Escape") {
            if (pillState === "ready") hidePill();
            return;
          }
          scheduleSelectionUpdate(selectionDebounceMs);
        });

        addListener(doc, "keydown", function (event) {
          if (event && event.key === "Escape" && pillState === "ready") {
            hidePill();
          }
        });

        addListener(doc, "scroll", function () {
          if (pillState === "ready") hidePill();
        }, true);

        addListener(doc, "selectionchange", function () {
          if (pillState === "saving") return;
          var selection = win && typeof win.getSelection === "function" ? win.getSelection() : null;
          if (!isValidChatSelection(selection)) {
            if (pillState === "ready") hidePill();
            return;
          }
          scheduleSelectionUpdate(selectionDebounceMs);
        });
      }

      if (win) {
        addListener(win, "pagehide", function () {
          if (!fetchImpl) return;
          try {
            void fetchImpl(apiUrl, {
              method: "POST",
              keepalive: true,
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ op: "disconnect", clientId: clientId }),
            });
          } catch {
          }
        });
      }

      bindSessionsService(getService(ctx, "sessions"));
      bindLocaleService(getService(ctx, "locale"));

      if (ctx && typeof ctx.inject === "function") {
        ctx.inject(["sessions"], function (sCtx) {
          bindSessionsService(getService(sCtx, "sessions"));
        });
        ctx.inject(["locale"], function (lCtx) {
          bindLocaleService(getService(lCtx, "locale"));
        });
      }

      async function pollLoop() {
        var backoffMs = 500;
        while (!disposed && !abortController.signal.aborted && fetchImpl) {
          try {
            var res = await postApi({
              op: "poll",
              clientId: clientId,
              timeoutMs: pollTimeoutMs,
            });
            backoffMs = 500;
            if (disposed || abortController.signal.aborted) break;
            var cmd = res && res.command;
            if (cmd && cmd.requestId) {
              var outcome = await executeCommand(ctx, cmd);
              if (disposed || abortController.signal.aborted) break;
              await postApi({
                op: "completeCommand",
                clientId: clientId,
                requestId: cmd.requestId,
                kind: cmd.kind,
                ok: outcome.ok === true,
                sessionId: outcome.sessionId || null,
                error: outcome.error || null,
              });
            }
          } catch {
            if (disposed || abortController.signal.aborted) break;
            await new Promise(function (resolve) {
              var timer = scheduleTimer(resolve, backoffMs);
              if (timer === null) resolve();
            });
            backoffMs = Math.min(5000, backoffMs * 2);
          }
        }
      }

      if (fetchImpl && opts.disablePolling !== true) {
        void pollLoop();
      }

      function dispose() {
        if (disposed) return;
        disposed = true;
        abortController.abort();

        for (var id of activeTimers) {
          clearTimeout(id);
        }
        activeTimers.clear();
        pillHoldTimer = null;
        selectionCheckTimer = null;

        for (var i = 0; i < domListeners.length; i += 1) {
          var l = domListeners[i];
          l.target.removeEventListener?.(l.type, l.wrapped, l.capture);
        }
        domListeners.length = 0;

        for (var j = 0; j < unsubscribers.length; j += 1) {
          try {
            unsubscribers[j]();
          } catch {
          }
        }
        unsubscribers.length = 0;

        if (shadowHost && typeof shadowHost.remove === "function") {
          shadowHost.remove();
        }
        shadowHost = null;
        shadowRoot = null;
        pillEl = null;
        pillIconEl = null;
        pillLabelEl = null;
        pillState = "hidden";
      }

      if (ctx && typeof ctx.effect === "function") {
        ctx.effect(function () {
          return dispose;
        });
      } else if (ctx && typeof ctx.on === "function") {
        ctx.on("dispose", dispose);
      }

      return {
        clientId: clientId,
        dispose: dispose,
        updatePillFromSelection: updatePillFromSelection,
        captureCurrentSelection: captureCurrentSelection,
        reportActiveSessionIfChanged: reportActiveSessionIfChanged,
        getPillDebugState: function () {
          return {
            state: pillState,
            host: shadowHost,
            pill: pillEl,
            label: pillLabelEl ? pillLabelEl.textContent : "",
          };
        },
      };
    }

    exports.name = "coding-rewind-dsh-client";
    exports.apply = apply;
    exports.findActiveSession = findActiveSession;
    exports.resolveTargetWorkspaceId = resolveTargetWorkspaceId;
    exports.resolveClientLanguage = resolveClientLanguage;
    exports.isValidChatSelection = isValidChatSelection;
    exports.computePillPosition = computePillPosition;
    exports.extractSelectionMarkdown = extractSelectionMarkdown;
    exports.executeCommand = executeCommand;

    return module.exports;
  }

  if (root && root.__ModuleLoader__ && typeof root.__ModuleLoader__.load === "function") {
    root.__ModuleLoader__.load({
      id: "coding-rewind-dsh",
      factory: createClientModule,
    });
  } else if (typeof globalThis !== "undefined") {
    globalThis.__CODING_REWIND_DSH_CLIENT_FACTORY__ = createClientModule;
  }
})(typeof window !== "undefined" ? window : globalThis);

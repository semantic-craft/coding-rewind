// SPDX-License-Identifier: MIT
// Code block & metadata normalization adapted from kepano/defuddle (MIT, Copyright (c) 2025 Steph Ango, commit 3e8bde9f5f85)
// Rich inline/block Markdown rules adapted from mixmark-io/turndown (MIT, Copyright (c) 2017 Dom Christie, commit b86e2b18539f)

const ELEMENT_NODE = 1;
const TEXT_NODE = 3;
const DOCUMENT_NODE = 9;
const DOCUMENT_FRAGMENT_NODE = 11;

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "param", "source", "track", "wbr"
]);

const SKIP_TAGS = new Set([
  "script", "style", "noscript", "svg", "button", "nav", "form", "textarea", "select"
]);

const MARKDOWN_STRUCTURE_TAGS = new Set([
  ...VOID_TAGS,
  ...SKIP_TAGS,
  "pre", "h1", "h2", "h3", "h4", "h5", "h6",
  "strong", "b", "em", "i", "del", "s", "mark", "kbd", "a",
  "ul", "ol", "li", "blockquote", "table", "details", "summary",
  "p", "section", "article", "div"
]);

const GENERIC_TITLES = new Set([
  "", "chatgpt", "claude", "gemini", "google gemini",
  "new chat", "new conversation", "untitled", "untitled chat", "untitled conversation",
  "新对话", "新建对话", "新建聊天", "新聊天", "未命名", "未命名对话"
]);

const LANGUAGE_BOUNDARY_TAGS = new Set([
  "body", "html", "main", "article", "section"
]);

function getTagName(node) {
  return ((node && (node.tagName || node.nodeName)) || "").toLowerCase();
}

function getAttr(node, name) {
  if (!node) return null;
  if (typeof node.getAttribute === "function") return node.getAttribute(name);
  if (node.attributes && Object.prototype.hasOwnProperty.call(node.attributes, name)) {
    return node.attributes[name];
  }
  return null;
}

function getClassString(node) {
  if (!node) return "";
  if (typeof node.className === "string") return node.className;
  return getAttr(node, "class") || "";
}

function hasClass(node, cls) {
  const raw = getClassString(node);
  return raw ? raw.split(/\s+/).includes(cls) : false;
}

function isInlineCodeElement(node) {
  return getTagName(node) === "code" || getAttr(node, "data-markdown-copy") === "inline-code";
}

const TURN_ADAPTERS = Object.freeze({
  chatgpt: {
    titleSelectors: [
      "[data-testid='conversation-title']",
      "nav a[data-active]",
      "nav a[aria-current='page']",
      "[data-testid='history-item-active']",
      "nav [aria-selected='true']"
    ],
    collectCandidates(doc) {
      const roleNodes = Array.from(
        doc.querySelectorAll("[data-message-author-role], h4[data-conversation-role]"),
        (node) => (getAttr(node, "data-conversation-role") ? node.parentElement : node)
      );
      return roleNodes.length > 0
        ? roleNodes
        : Array.from(doc.querySelectorAll("article[data-testid^='conversation-turn-'], [data-testid^='conversation-turn-']"));
    },
    inferRole(el) {
      const direct = (getAttr(el, "data-message-author-role") || getAttr(el, "data-turn") || "").toLowerCase();
      if (direct === "user" || direct === "assistant") return direct;
      if (typeof el.querySelector === "function") {
        const innerRole = el.querySelector("[data-message-author-role], h4[data-conversation-role]");
        if (innerRole) {
          const r = (getAttr(innerRole, "data-message-author-role") || getAttr(innerRole, "data-conversation-role") || "").toLowerCase();
          if (r === "user" || r === "assistant") return r;
        }
        const srHeading = el.querySelector("h5, h6");
        if (srHeading) {
          const headingText = (srHeading.textContent || "").toLowerCase();
          if (headingText.includes("you said")) return "user";
          if (headingText.includes("chatgpt said")) return "assistant";
        }
      }
      return null;
    }
  },
  claude: {
    titleSelectors: [
      "[data-testid='chat-title-button']",
      "button[data-testid='rename-chat-trigger']",
      "[data-testid='conversation-title']",
      "nav a[aria-current='page']",
      "aside a[aria-current='page']"
    ],
    candidateSelector:
      "[data-testid='user-message'], [data-testid='assistant-message'], [data-testid='chat-message-content'], .font-user-message, .font-claude-message, .font-claude-response, [data-role='user'], [data-role='assistant']",
    inferRole(el) {
      const testId = (getAttr(el, "data-testid") || "").toLowerCase();
      const roleAttr = (getAttr(el, "data-role") || "").toLowerCase();
      if (
        testId === "user-message" ||
        roleAttr === "user" ||
        getAttr(el, "data-is-author-user") === "true" ||
        hasClass(el, "font-user-message")
      ) {
        return "user";
      }
      if (
        testId === "assistant-message" ||
        testId === "chat-message-content" ||
        roleAttr === "assistant" ||
        hasClass(el, "font-claude-message") ||
        hasClass(el, "font-claude-response")
      ) {
        return "assistant";
      }
      return null;
    }
  },
  gemini: {
    titleSelectors: [
      ".selected .conversation-title",
      "[data-test-id='conversation-title']",
      ".conversation-title",
      "nav [aria-selected='true']",
      "nav a[aria-current='page']"
    ],
    candidateSelector:
      "user-query, model-response, user-query-content, message-content, .user-query-container, .model-response-text, [data-message-author-role='user'], [data-message-author-role='model'], [data-message-author-role='assistant'], [data-turn-role='user'], [data-turn-role='model']",
    inferRole(el) {
      const tag = getTagName(el);
      const authorRole = (getAttr(el, "data-message-author-role") || getAttr(el, "data-turn-role") || "").toLowerCase();
      if (
        tag === "user-query" ||
        tag === "user-query-content" ||
        authorRole === "user" ||
        hasClass(el, "user-query-container")
      ) {
        return "user";
      }
      if (
        tag === "model-response" ||
        tag === "message-content" ||
        authorRole === "assistant" ||
        authorRole === "model" ||
        hasClass(el, "model-response-text")
      ) {
        return "assistant";
      }
      return null;
    }
  }
});

export function detectPlatform(url) {
  if (!url || typeof url !== "string") return "web";
  try {
    const host = new URL(url).hostname.toLowerCase();
    if (host === "chatgpt.com" || host.endsWith(".chatgpt.com") || host === "chat.openai.com") {
      return "chatgpt";
    }
    if (host === "claude.ai" || host.endsWith(".claude.ai")) {
      return "claude";
    }
    if (host === "gemini.google.com") {
      return "gemini";
    }
  } catch {
    return "web";
  }
  return "web";
}

function escapeRegExp(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function stripSiteNameSuffix(title, siteName) {
  const cleanSite = String(siteName || "").replace(/\s+/g, " ").trim();
  if (!cleanSite || !title) return title;
  const pattern = new RegExp(`(?:\\s+-\\s+|\\s*(?:\\||—|–|·|::)\\s*)${escapeRegExp(cleanSite)}\\s*$`, "i");
  const stripped = title.replace(pattern, "").trim();
  return stripped || title;
}

export function cleanSessionTitle(rawTitle, siteName = "") {
  if (!rawTitle || typeof rawTitle !== "string") return "";
  let cleaned = rawTitle
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\s*[-|·]\s*(?:ChatGPT|Claude|Google Gemini|Gemini)\s*$/i, "")
    .replace(/^(?:ChatGPT|Claude|Google Gemini|Gemini)\s*[-|·]\s*/i, "")
    .trim();
  if (siteName) {
    cleaned = stripSiteNameSuffix(cleaned, siteName);
  }
  if (GENERIC_TITLES.has(cleaned.toLowerCase())) {
    return "";
  }
  return cleaned;
}

function queryFirstText(doc, selectors, siteName = "") {
  if (!doc || typeof doc.querySelectorAll !== "function") return "";
  for (const selector of selectors) {
    let nodes;
    try {
      nodes = doc.querySelectorAll(selector);
    } catch {
      continue;
    }
    for (const node of nodes) {
      const candidate = cleanSessionTitle(node.textContent || "", siteName);
      if (candidate) return candidate;
    }
  }
  return "";
}

function readMetaContent(doc, selectors) {
  if (!doc || typeof doc.querySelector !== "function") return "";
  for (const selector of selectors) {
    try {
      const el = doc.querySelector(selector);
      const content = el ? getAttr(el, "content") : null;
      if (content && content.trim()) return content.trim();
    } catch {}
  }
  return "";
}

export function extractSessionTitle(doc, url = "", platform = detectPlatform(url)) {
  if (!doc) return "";
  const adapter = TURN_ADAPTERS[platform];
  if (adapter && adapter.titleSelectors.length > 0) {
    const fromDom = queryFirstText(doc, adapter.titleSelectors);
    if (fromDom) return fromDom;
  }

  const siteName = platform === "web"
    ? readMetaContent(doc, [
        "meta[property='og:site_name']",
        "meta[name='og:site_name']",
        "meta[name='application-name']"
      ])
    : "";

  const fromDocTitle = cleanSessionTitle(doc.title || "", siteName);
  if (fromDocTitle) return fromDocTitle;

  if (platform === "web") {
    const ogTitle = cleanSessionTitle(
      readMetaContent(doc, ["meta[property='og:title']", "meta[name='og:title']"]),
      siteName
    );
    if (ogTitle) return ogTitle;
  }

  return queryFirstText(doc, ["main h1", "article h1", "h1"], siteName);
}

function getVisibleText(node) {
  if (!node) return "";
  if (node.nodeType === TEXT_NODE) return node.nodeValue || node.textContent || "";
  if (node.nodeType !== ELEMENT_NODE && node.nodeType !== DOCUMENT_FRAGMENT_NODE && node.nodeType !== DOCUMENT_NODE) {
    return "";
  }
  const tag = getTagName(node);
  if (SKIP_TAGS.has(tag)) return "";
  if (getAttr(node, "aria-hidden") === "true") return "";
  let out = "";
  for (const child of node.childNodes || []) {
    out += getVisibleText(child);
  }
  return out;
}

function isCodeGutterElement(el) {
  if (!el || el.nodeType !== ELEMENT_NODE) return false;
  const tag = getTagName(el);
  if (
    hasClass(el, "rouge-gutter") ||
    hasClass(el, "react-syntax-highlighter-line-number") ||
    hasClass(el, "line-numbers-rows") ||
    hasClass(el, "gutter")
  ) {
    return true;
  }
  if (tag === "span" && (hasClass(el, "lnt") || hasClass(el, "lineno"))) {
    return true;
  }
  if (tag === "td" && (hasClass(el, "blob-num") || hasClass(el, "hljs-ln-numbers") || hasClass(el, "line-number"))) {
    return true;
  }
  if (
    getAttr(el, "data-line-number") !== null &&
    (el.childNodes || []).length === 0 &&
    !(el.textContent || "").trim()
  ) {
    return true;
  }
  return false;
}

function isCodeLineElement(el) {
  if (!el || el.nodeType !== ELEMENT_NODE || isCodeGutterElement(el)) return false;
  const tag = getTagName(el);
  if ((tag === "span" || tag === "div") && hasClass(el, "line")) return true;
  if (hasClass(el, "ec-line") || hasClass(el, "token-line") || hasClass(el, "cm-line")) return true;
  if (getAttr(el, "data-line") !== null) return true;
  return false;
}

function extractLanguageFromSingleNode(node) {
  if (!node || node.nodeType !== ELEMENT_NODE) return "";
  const directAttr = getAttr(node, "data-language") || getAttr(node, "data-lang");
  if (directAttr && directAttr.trim()) return directAttr.trim().toLowerCase();

  const cls = getClassString(node);
  if (!cls) return "";

  const patterns = [
    /(?:^|\s)(?:language-|lang-)([a-zA-Z0-9_+#.-]+)/i,
    /(?:^|\s)highlight-source-([a-zA-Z0-9_+#.-]+)/i,
    /(?:^|\s)syntax-([a-zA-Z0-9_+#.-]+)/i,
    /\bbrush:\s*([a-zA-Z0-9_+#.-]+)/i
  ];
  for (const re of patterns) {
    const match = cls.match(re);
    if (match && match[1]) return match[1].toLowerCase();
  }
  return "";
}

function findLanguageInSubtree(root) {
  for (const child of (root && root.childNodes) || []) {
    if (child.nodeType !== ELEMENT_NODE || isCodeGutterElement(child)) continue;
    const tag = getTagName(child);
    if (tag === "code" || tag === "pre" || getAttr(child, "data-language") || getAttr(child, "data-lang")) {
      const lang = extractLanguageFromSingleNode(child);
      if (lang) return lang;
    }
    const nested = findLanguageInSubtree(child);
    if (nested) return nested;
  }
  return "";
}

function inferPreHeaderLanguage(preNode, codeNode) {
  for (const child of preNode.childNodes || []) {
    if (child === codeNode) break;
    if (child.nodeType === ELEMENT_NODE && !nodeContains(child, codeNode)) {
      const label = getVisibleText(child).trim().toLowerCase();
      if (
        label &&
        /^[a-z0-9_+#.-]{1,20}$/.test(label) &&
        label !== "copy" &&
        label !== "copied" &&
        label !== "code"
      ) {
        return label;
      }
    }
  }
  return "";
}

export function extractCodeLanguage(primaryNode, preNode = null) {
  const fromPrimary = extractLanguageFromSingleNode(primaryNode);
  if (fromPrimary) return fromPrimary;

  if (preNode && preNode !== primaryNode) {
    const fromPre = extractLanguageFromSingleNode(preNode);
    if (fromPre) return fromPre;
  }

  const subtreeRoot = preNode || primaryNode;
  if (subtreeRoot) {
    const fromSubtree = findLanguageInSubtree(subtreeRoot);
    if (fromSubtree) return fromSubtree;
  }

  let cur = subtreeRoot ? (subtreeRoot.parentNode || subtreeRoot.parentElement) : null;
  while (cur && cur.nodeType === ELEMENT_NODE) {
    if (LANGUAGE_BOUNDARY_TAGS.has(getTagName(cur))) break;
    if (
      hasClass(cur, "highlight") ||
      getAttr(cur, "data-language") !== null ||
      getAttr(cur, "data-lang") !== null ||
      /(?:^|\s)(?:highlight-source-|language-|lang-|syntax-|brush:)/i.test(getClassString(cur))
    ) {
      const fromWrapper = extractLanguageFromSingleNode(cur);
      if (fromWrapper) return fromWrapper;
    }
    cur = cur.parentNode || cur.parentElement;
  }

  if (preNode && primaryNode && primaryNode !== preNode) {
    return inferPreHeaderLanguage(preNode, primaryNode);
  }
  return "";
}

function findPrimaryCodeElement(preNode) {
  const codes = [];
  const visit = (cur) => {
    for (const child of cur.childNodes || []) {
      if (child.nodeType !== ELEMENT_NODE) continue;
      if (isCodeGutterElement(child) || SKIP_TAGS.has(getTagName(child))) continue;
      if (isCodeLineElement(child)) return;
      if (getTagName(child) === "code") {
        codes.push(child);
        return;
      }
      visit(child);
    }
  };
  visit(preNode);
  return codes.length === 1 ? codes[0] : null;
}

function extractCodeText(node) {
  if (!node) return "";
  if (node.nodeType === TEXT_NODE) return node.nodeValue ?? node.textContent ?? "";
  if (node.nodeType !== ELEMENT_NODE && node.nodeType !== DOCUMENT_FRAGMENT_NODE) return "";
  if (node.nodeType === ELEMENT_NODE) {
    const tag = getTagName(node);
    if (tag === "br") return "\n";
    if (SKIP_TAGS.has(tag) || isCodeGutterElement(node) || getAttr(node, "data-markdown-copy") === "exclude") {
      return "";
    }
  }

  const children = Array.from(node.childNodes || []);
  const hasLineChildren = children.some((c) => c.nodeType === ELEMENT_NODE && isCodeLineElement(c));
  let out = "";
  let pendingLineBreak = false;
  let prevWasLine = false;

  for (const child of children) {
    if (child.nodeType === TEXT_NODE) {
      const val = child.nodeValue ?? child.textContent ?? "";
      if (!val) continue;
      if (hasLineChildren && /^\s*$/.test(val)) continue;
      if (pendingLineBreak) {
        out += "\n";
        pendingLineBreak = false;
      }
      out += val;
      prevWasLine = false;
      continue;
    }
    if (child.nodeType !== ELEMENT_NODE) continue;

    const childTag = getTagName(child);
    if (SKIP_TAGS.has(childTag) || isCodeGutterElement(child) || getAttr(child, "data-markdown-copy") === "exclude") {
      continue;
    }
    if (childTag === "br") {
      if (prevWasLine) {
        prevWasLine = false;
        continue;
      }
      if (pendingLineBreak) {
        out += "\n";
        pendingLineBreak = false;
      }
      out += "\n";
      continue;
    }
    if (isCodeLineElement(child)) {
      if (pendingLineBreak) {
        out += "\n";
      }
      out += extractCodeText(child).replace(/\n$/, "");
      pendingLineBreak = true;
      prevWasLine = true;
      continue;
    }

    const chunk = extractCodeText(child);
    if (chunk) {
      if (pendingLineBreak) {
        out += "\n";
        pendingLineBreak = false;
      }
      out += chunk;
      prevWasLine = false;
    }
  }
  return out;
}

function collectElements(root, predicate, acc = []) {
  for (const child of (root && root.childNodes) || []) {
    if (child.nodeType !== ELEMENT_NODE) continue;
    if (predicate(child)) {
      acc.push(child);
    } else {
      collectElements(child, predicate, acc);
    }
  }
  return acc;
}

function isCodeTableCell(el) {
  return (
    getTagName(el) === "td" &&
    (hasClass(el, "blob-code") || hasClass(el, "rouge-code") || hasClass(el, "hljs-ln-code"))
  );
}

function isCodeTableElement(el) {
  if (!el || getTagName(el) !== "table") return false;
  if (hasClass(el, "lntable") || hasClass(el, "hljs-ln") || hasClass(el, "rouge-table")) return true;
  return (
    collectElements(el, isCodeTableCell).length > 0 ||
    collectElements(el, (c) => getTagName(c) === "td" && hasClass(c, "lntd")).length > 0
  );
}

function extractCodeFromTableOrFragment(root) {
  const codeCells = collectElements(root, isCodeTableCell);
  if (codeCells.length > 0) {
    return codeCells.map((cell) => extractCodeText(cell).replace(/\n$/, "")).join("\n");
  }
  const lntds = collectElements(root, (el) => getTagName(el) === "td" && hasClass(el, "lntd"));
  if (lntds.length > 0) {
    const nonEmpty = lntds
      .map((cell) => extractCodeText(cell).replace(/^\n+|\n+$/g, ""))
      .filter((txt) => txt.trim().length > 0);
    if (
      nonEmpty.length === 2 &&
      /^\d+(?:\s+\d+)*$/.test(nonEmpty[0].trim()) &&
      !/^\d+(?:\s+\d+)*$/.test(nonEmpty[1].trim())
    ) {
      return nonEmpty[1];
    }
    if (nonEmpty.length > 0) return nonEmpty.join("\n");
  }
  return null;
}

export function formatFencedCodeBlock(rawCode, language = "", preserveWhitespace = false) {
  const sourceCode = String(rawCode || "");
  const cleanedCode = preserveWhitespace ? sourceCode : sourceCode.replace(/^\n+|\n+$/g, "");
  const runs = cleanedCode.match(/`{3,}/g) || [];
  let fenceLen = 3;
  for (const run of runs) {
    if (run.length >= fenceLen) fenceLen = run.length + 1;
  }
  const fence = "`".repeat(fenceLen);
  const safeLang = String(language || "").replace(/[^a-zA-Z0-9_+#.-]/g, "");
  return `\n\n${fence}${safeLang}\n${cleanedCode}\n${fence}\n\n`;
}

function formatInlineCode(rawText) {
  const text = String(rawText || "").replace(/\r?\n/g, " ");
  if (!text) return "";
  const pad = text.startsWith("`") || text.endsWith("`") ||
    (text.startsWith(" ") && text.endsWith(" ") && text.trim().length > 0)
    ? " "
    : "";
  if (!text.includes("`")) return `\`${pad}${text}${pad}\``;
  const runs = text.match(/`+/g) || [];
  let maxLen = 1;
  for (const run of runs) {
    if (run.length >= maxLen) maxLen = run.length + 1;
  }
  const ticks = "`".repeat(maxLen);
  return `${ticks}${pad}${text}${pad}${ticks}`;
}

function wrapInlineMarker(content, marker) {
  if (!content || !content.trim()) return content;
  const leading = (content.match(/^\s*/) || [""])[0];
  const trailing = (content.match(/\s*$/) || [""])[0];
  const core = content.slice(leading.length, content.length - trailing.length);
  return `${leading}${marker}${core}${marker}${trailing}`;
}

function stripAsciiControls(raw) {
  return String(raw || "").replace(/[\u0000-\u001f\u007f]+/g, "").trim();
}

function encodeMarkdownDestination(url) {
  return url
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29")
    .replace(/\s+/g, "%20");
}

function escapeHtmlText(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeMarkdownLinkText(label) {
  if (/^!\[[\s\S]*\]\([^()\s]+\)$/.test(label)) {
    return label;
  }
  return label
    .split(/(`+[^`]*`+)/g)
    .map((part, idx) =>
      idx % 2 === 1
        ? part
        : part.replace(/(?<!\\)\[/g, "\\[").replace(/(?<!\\)\]/g, "\\]")
    )
    .join("");
}

function resolveAgainstHttpBase(rawUrl, baseUrl) {
  const cleanBase = stripAsciiControls(baseUrl);
  if (!cleanBase) return rawUrl;
  try {
    const base = new URL(cleanBase);
    if (base.protocol !== "http:" && base.protocol !== "https:") return rawUrl;
    return new URL(rawUrl, base).href;
  } catch {
    return rawUrl;
  }
}

function resolveHref(href, baseUrl) {
  const cleaned = stripAsciiControls(href);
  if (!cleaned) return "";
  const schemeMatch = cleaned.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
  if (schemeMatch) {
    const scheme = `${schemeMatch[1].toLowerCase()}:`;
    if (scheme !== "http:" && scheme !== "https:" && scheme !== "mailto:") {
      return "";
    }
  }
  const resolved = resolveAgainstHttpBase(cleaned, baseUrl);
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(resolved)) {
    try {
      const parsed = new URL(resolved);
      const proto = parsed.protocol.toLowerCase();
      if (proto !== "http:" && proto !== "https:" && proto !== "mailto:") {
        return "";
      }
    } catch {
      return "";
    }
  }
  return encodeMarkdownDestination(resolved);
}

function resolveImageSrc(src, baseUrl) {
  const cleaned = stripAsciiControls(src);
  if (!cleaned) return "";
  const schemeMatch = cleaned.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
  if (schemeMatch) {
    const scheme = `${schemeMatch[1].toLowerCase()}:`;
    if (scheme === "data:") {
      if (cleaned.length <= 200 && /^data:image\/[a-zA-Z0-9.+-]+[,;]/i.test(cleaned)) {
        return encodeMarkdownDestination(cleaned);
      }
      return "";
    }
    if (scheme !== "http:" && scheme !== "https:") {
      return "";
    }
  }
  const resolved = resolveAgainstHttpBase(cleaned, baseUrl);
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(resolved)) {
    try {
      const parsed = new URL(resolved);
      const proto = parsed.protocol.toLowerCase();
      if (proto !== "http:" && proto !== "https:") {
        return "";
      }
    } catch {
      return "";
    }
  }
  return encodeMarkdownDestination(resolved);
}

function extractKatexTex(el) {
  if (!hasClass(el, "katex") && !hasClass(el, "katex-display")) return null;
  if (typeof el.querySelector === "function") {
    const ann = el.querySelector("annotation[encoding='application/x-tex'], annotation");
    if (ann) {
      const tex = (ann.textContent || "").trim();
      if (tex) {
        return hasClass(el, "katex-display") ? `\n\n$$\n${tex}\n$$\n\n` : `$${tex}$`;
      }
    }
  }
  return null;
}

function renderTable(tableEl, ctx) {
  const codeFromTable = extractCodeFromTableOrFragment(tableEl);
  if (codeFromTable !== null) {
    return formatFencedCodeBlock(codeFromTable, extractCodeLanguage(tableEl));
  }

  const rows = [];
  const collectRows = (node) => {
    for (const child of node.childNodes || []) {
      if (child.nodeType !== ELEMENT_NODE) continue;
      const t = getTagName(child);
      if (t === "tr") {
        const cells = [];
        for (const c of child.childNodes || []) {
          if (c.nodeType === ELEMENT_NODE && (getTagName(c) === "th" || getTagName(c) === "td")) {
            const cellMd = convertChildren(c, { ...ctx, inline: true })
              .replace(/\s*\n+\s*/g, " ")
              .replace(/\|/g, "\\|")
              .trim();
            cells.push(cellMd);
          }
        }
        if (cells.length > 0) rows.push(cells);
      } else if (t === "thead" || t === "tbody" || t === "tfoot") {
        collectRows(child);
      }
    }
  };
  collectRows(tableEl);
  if (rows.length === 0) return "";
  const colCount = Math.max(...rows.map((r) => r.length));
  const padRow = (r) => {
    const copy = r.slice();
    while (copy.length < colCount) copy.push("");
    return `| ${copy.join(" | ")} |`;
  };
  const header = padRow(rows[0]);
  const divider = `| ${Array(colCount).fill("---").join(" | ")} |`;
  const body = rows.slice(1).map(padRow);
  return `\n\n${[header, divider, ...body].join("\n")}\n\n`;
}

function firstNonWhitespaceChild(node) {
  for (const child of (node && node.childNodes) || []) {
    if (child.nodeType === TEXT_NODE && !(child.nodeValue || "").trim()) continue;
    return child;
  }
  return null;
}

function asCheckboxInput(node) {
  if (!node || node.nodeType !== ELEMENT_NODE || getTagName(node) !== "input") return null;
  const type = String(node.type || getAttr(node, "type") || "").toLowerCase();
  return type === "checkbox" ? node : null;
}

function extractTaskCheckbox(liEl) {
  const first = firstNonWhitespaceChild(liEl);
  let cb = asCheckboxInput(first);
  if (!cb && first && first.nodeType === ELEMENT_NODE) {
    const firstTag = getTagName(first);
    if (firstTag === "p" || firstTag === "label") {
      cb = asCheckboxInput(firstNonWhitespaceChild(first));
    }
  }
  if (!cb) return null;
  return { checked: Boolean(cb.checked || getAttr(cb, "checked") !== null) };
}

function renderList(listEl, ordered, ctx) {
  const depth = ctx.listDepth || 0;
  const indent = "  ".repeat(depth);
  const startAttr = parseInt(getAttr(listEl, "start") || "1", 10);
  let index = Number.isFinite(startAttr) && startAttr > 0 ? startAttr : 1;
  const lines = [];

  for (const child of listEl.childNodes || []) {
    if (child.nodeType !== ELEMENT_NODE) continue;
    if (getTagName(child) !== "li") continue;

    const task = extractTaskCheckbox(child);
    let itemInline = "";
    let nestedBlocks = "";
    for (const liChild of child.childNodes || []) {
      if (liChild.nodeType === ELEMENT_NODE) {
        const liChildTag = getTagName(liChild);
        if (liChildTag === "ul" || liChildTag === "ol") {
          nestedBlocks += "\n" + renderList(liChild, liChildTag === "ol", { ...ctx, listDepth: depth + 1 }).trimEnd();
          continue;
        }
      }
      itemInline += convertNode(liChild, { ...ctx, listDepth: depth + 1 });
    }

    const normalizedBody = normalizeMarkdownSpacing(itemInline)
      .split("\n")
      .map((line, i) => (i === 0 ? line : `${indent}  ${line}`))
      .join("\n")
      .trim();

    const taskPrefix = task ? (task.checked ? "[x] " : "[ ] ") : "";
    const marker = ordered ? `${index}. ${taskPrefix}` : `- ${taskPrefix}`;
    index += 1;
    lines.push(`${indent}${marker}${normalizedBody}${nestedBlocks}`);
  }

  if (lines.length === 0) return "";
  return depth === 0 ? `\n\n${lines.join("\n")}\n\n` : `${lines.join("\n")}`;
}

function convertChildren(node, ctx) {
  let out = "";
  for (const child of node.childNodes || []) {
    out += convertNode(child, ctx);
  }
  return out;
}

function preservesRenderedLineBreaks(node) {
  const element = node?.parentElement;
  const view = element?.ownerDocument?.defaultView;
  if (!view) return false;
  return ["pre", "pre-wrap", "pre-line", "break-spaces"].includes(view.getComputedStyle(element).whiteSpace);
}

function* nonemptyTextNodes(node) {
  if (node.nodeType === TEXT_NODE) {
    if (node.nodeValue) yield node;
    return;
  }
  for (const child of node.childNodes || []) yield* nonemptyTextNodes(child);
}

function selectedLineBreakModes(range, fragment) {
  const modes = new WeakMap();
  const source = [...nonemptyTextNodes(range.commonAncestorContainer)].filter((node) => {
    if (!range.intersectsNode(node)) return false;
    const start = node === range.startContainer ? range.startOffset : 0;
    const end = node === range.endContainer ? range.endOffset : node.nodeValue.length;
    return end > start;
  });
  const cloned = [...nonemptyTextNodes(fragment)];
  for (let index = 0; index < cloned.length; index += 1) {
    modes.set(cloned[index], preservesRenderedLineBreaks(source[index]));
  }
  return modes;
}

function convertNode(node, ctx) {
  if (!node) return "";
  if (node.nodeType === TEXT_NODE) {
    const raw = node.nodeValue ?? node.textContent ?? "";
    if (!raw) return "";
    if (ctx.lineBreakModes?.get(node) ?? preservesRenderedLineBreaks(node)) {
      return raw.replace(/\r\n?/g, "\n").replace(/[ \t]+/g, " ");
    }
    return raw.replace(/[ \t\r\n]+/g, " ");
  }
  if (node.nodeType === DOCUMENT_FRAGMENT_NODE || node.nodeType === DOCUMENT_NODE) {
    return convertChildren(node, ctx);
  }
  if (node.nodeType !== ELEMENT_NODE) return "";

  const tag = getTagName(node);
  if (SKIP_TAGS.has(tag) || tag === "input") return "";
  if (getAttr(node, "data-markdown-copy") === "exclude") return "";
  if (hasClass(node, "screen-reader-user-query-label")) return "";

  const katex = extractKatexTex(node);
  if (katex !== null) return katex;

  if (getAttr(node, "aria-hidden") === "true") return "";

  if (tag === "br") return "\n";
  if (tag === "hr") return "\n\n---\n\n";

  if (tag === "img") {
    const src = resolveImageSrc(getAttr(node, "src"), ctx.baseUrl);
    if (!src) return "";
    const alt = (getAttr(node, "alt") || "")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/\[/g, "\\[")
      .replace(/\]/g, "\\]");
    return `![${alt}](${src})`;
  }

  if (tag === "pre") {
    const codeEl = findPrimaryCodeElement(node);
    const lang = extractCodeLanguage(codeEl || node, node);
    const tableCode = extractCodeFromTableOrFragment(node);
    const rawCode = tableCode !== null ? tableCode : extractCodeText(codeEl || node);
    return formatFencedCodeBlock(rawCode, lang);
  }

  if (isInlineCodeElement(node)) {
    return formatInlineCode(extractCodeText(node));
  }

  if (/^h[1-6]$/.test(tag)) {
    const level = Number(tag[1]);
    const text = normalizeMarkdownSpacing(convertChildren(node, ctx));
    return text ? `\n\n${"#".repeat(level)} ${text}\n\n` : "";
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

  if (tag === "mark") {
    return wrapInlineMarker(convertChildren(node, ctx), "==");
  }

  if (tag === "kbd") {
    const inner = escapeHtmlText(convertChildren(node, ctx).trim());
    return inner ? `<kbd>${inner}</kbd>` : "";
  }

  if (tag === "a") {
    const inner = convertChildren(node, ctx).trim();
    const href = resolveHref(getAttr(node, "href"), ctx.baseUrl);
    if (!href) return inner;
    const label = escapeMarkdownLinkText(inner || href);
    return `[${label}](${href})`;
  }

  if (tag === "ul" || tag === "ol") {
    return renderList(node, tag === "ol", ctx);
  }

  if (tag === "blockquote") {
    const inner = normalizeMarkdownSpacing(convertChildren(node, ctx));
    if (!inner) return "";
    const quoted = inner
      .split("\n")
      .map((line) => (line ? `> ${line}` : ">"))
      .join("\n");
    return `\n\n${quoted}\n\n`;
  }

  if (tag === "table") {
    return renderTable(node, ctx);
  }

  if (tag === "summary") {
    const summaryText = normalizeMarkdownSpacing(convertChildren(node, ctx));
    if (!summaryText) return "";
    const bold = summaryText.startsWith("**") && summaryText.endsWith("**")
      ? summaryText
      : `**${summaryText}**`;
    return `\n\n${bold}\n\n`;
  }

  if (tag === "details") {
    const inner = normalizeMarkdownSpacing(convertChildren(node, ctx));
    return inner ? `\n\n${inner}\n\n` : "";
  }

  if (tag === "p" || tag === "section" || tag === "article") {
    const inner = convertChildren(node, ctx).trim();
    return inner ? `\n\n${inner}\n\n` : "";
  }

  if (tag === "li") {
    const task = extractTaskCheckbox(node);
    const inner = convertChildren(node, ctx).trim();
    if (!inner && !task) return "";
    const prefix = task ? (task.checked ? "- [x] " : "- [ ] ") : "";
    return `\n${prefix}${inner}\n`;
  }

  if (tag === "div") {
    const inner = convertChildren(node, ctx);
    if (!inner.trim()) return "";
    return `\n${inner}\n`;
  }

  return convertChildren(node, ctx);
}

function normalizeMarkdownSpacing(md) {
  if (!md) return "";
  const lines = md.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let inFence = false;
  let fenceMarker = "";

  for (const line of lines) {
    const fenceMatch = line.match(/^(`{3,})/);
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
      const normalized = line.replace(/[ \t]+$/g, "").replace(/^[ \t]+(?=(?:#{1,6}\s|> ))/, "");
      if (normalized || out.at(-1) !== "") out.push(normalized);
    }
  }

  return out.join("\n").trim();
}

export function htmlToMarkdown(nodeOrHtml, options = {}) {
  if (!nodeOrHtml) return "";
  if (typeof nodeOrHtml === "string" && typeof globalThis.DOMParser !== "function") {
    return normalizeMarkdownSpacing(String(nodeOrHtml));
  }
  const root = typeof nodeOrHtml === "string"
    ? new globalThis.DOMParser().parseFromString(nodeOrHtml, "text/html").body
    : nodeOrHtml;
  const raw = convertNode(root, { baseUrl: options.baseUrl || "", listDepth: 0, lineBreakModes: options.lineBreakModes });
  return normalizeMarkdownSpacing(raw);
}

function findAncestorElement(node, matches) {
  let cur = node;
  while (cur) {
    if (cur.nodeType === ELEMENT_NODE && matches(cur)) {
      return cur;
    }
    cur = cur.parentNode || cur.parentElement || null;
  }
  return null;
}

export function nodeContains(ancestor, target) {
  if (!ancestor || !target) return false;
  if (typeof ancestor.contains === "function") {
    try {
      return ancestor.contains(target);
    } catch {}
  }
  let cur = target;
  while (cur) {
    if (cur === ancestor) return true;
    cur = cur.parentNode || cur.parentElement || null;
  }
  return false;
}

function hasMarkdownStructure(node) {
  if (!node) return false;
  if (node.nodeType === ELEMENT_NODE) {
    if (getAttr(node, "data-markdown-copy") === "exclude") return false;
    if (
      getAttr(node, "aria-hidden") === "true" ||
      isInlineCodeElement(node) ||
      MARKDOWN_STRUCTURE_TAGS.has(getTagName(node))
    ) {
      return true;
    }
  }
  for (const child of node.childNodes || []) {
    if (hasMarkdownStructure(child)) return true;
  }
  return false;
}

export function selectionToMarkdown(selectionOrRange, baseUrl = "", capturedText = null) {
  if (!selectionOrRange) {
    return typeof capturedText === "string" && capturedText.trim() ? capturedText : "";
  }

  let range = null;
  let plainFallback = "";

  if (typeof selectionOrRange.getRangeAt === "function") {
    plainFallback = selectionOrRange.toString() || "";
    if (!plainFallback.trim()) plainFallback = "";
    if (selectionOrRange.rangeCount > 0 && !selectionOrRange.isCollapsed) {
      range = selectionOrRange.getRangeAt(0);
    }
  } else if (typeof selectionOrRange.cloneContents === "function") {
    range = selectionOrRange;
    plainFallback = typeof range.toString === "function" ? range.toString() : "";
    if (!plainFallback.trim()) plainFallback = "";
  } else if (typeof selectionOrRange === "string") {
    return selectionOrRange.trim() ? selectionOrRange : "";
  }

  if (capturedText !== null) plainFallback = capturedText;
  if (!range) return plainFallback;

  const ancestorCodeTable = findAncestorElement(range.commonAncestorContainer, isCodeTableElement);
  const ancestorPre = findAncestorElement(range.commonAncestorContainer, (el) => getTagName(el) === "pre");

  if (ancestorCodeTable) {
    const fragment = range.cloneContents();
    const tableCode = extractCodeFromTableOrFragment(fragment);
    const codeText = tableCode !== null ? tableCode : (extractCodeText(fragment) || plainFallback);
    if (codeText.trim()) {
      const ancestorCode = findAncestorElement(range.commonAncestorContainer, (el) => getTagName(el) === "code");
      const lang = extractCodeLanguage(ancestorCode || ancestorCodeTable, ancestorPre);
      return formatFencedCodeBlock(codeText, lang, tableCode === null).trim();
    }
  }

  if (ancestorPre) {
    const ancestorCode =
      findAncestorElement(range.commonAncestorContainer, (el) => getTagName(el) === "code") ||
      findPrimaryCodeElement(ancestorPre);
    const lang = extractCodeLanguage(ancestorCode || ancestorPre, ancestorPre);
    const fragment = range.cloneContents();
    const tableCode = extractCodeFromTableOrFragment(fragment);
    const codeText = tableCode !== null ? tableCode : (extractCodeText(fragment) || plainFallback);
    if (codeText.trim()) {
      return formatFencedCodeBlock(codeText, lang, tableCode === null).trim();
    }
  }

  const ancestorInlineCode = findAncestorElement(range.commonAncestorContainer, isInlineCodeElement);
  if (ancestorInlineCode) {
    const fragment = range.cloneContents();
    const codeText = extractCodeText(fragment) || plainFallback;
    if (codeText.trim()) return formatInlineCode(codeText);
  }

  try {
    const fragment = range.cloneContents();
    if (plainFallback && !hasMarkdownStructure(fragment)) return plainFallback;
    const md = htmlToMarkdown(fragment, { baseUrl, lineBreakModes: selectedLineBreakModes(range, fragment) });
    if (md) {
      if (capturedText !== null || typeof selectionOrRange.getRangeAt === "function") {
        const selectedText = [...nonemptyTextNodes(fragment)];
        const leadingWhitespace = findAncestorElement(selectedText[0], isInlineCodeElement)
          ? "" : plainFallback.match(/^\s*/)[0];
        const trailingWhitespace = findAncestorElement(selectedText.at(-1), isInlineCodeElement)
          ? "" : plainFallback.match(/\s*$/)[0];
        return `${leadingWhitespace}${md}${trailingWhitespace}`;
      }
      return md;
    }
  } catch {
    return plainFallback;
  }
  return plainFallback;
}

function dedupeOuterElements(elements) {
  const kept = [];
  for (const el of elements) {
    if (!el) continue;
    if (kept.some((existing) => existing === el || nodeContains(existing, el))) {
      continue;
    }
    for (let i = kept.length - 1; i >= 0; i -= 1) {
      if (nodeContains(el, kept[i])) {
        kept.splice(i, 1);
      }
    }
    kept.push(el);
  }
  return kept;
}

function extractTurnBodyMarkdown(turnEl, baseUrl) {
  let contentRoot = turnEl;
  if (typeof turnEl.querySelector === "function") {
    const specific = turnEl.querySelector(
      ".markdown, [data-markdown-text-style='assistant-message'], message-content, .model-response-text, .user-query-text, .whitespace-pre-wrap"
    );
    if (specific && specific !== turnEl) {
      contentRoot = specific;
    }
  }
  return htmlToMarkdown(contentRoot, { baseUrl });
}

export function extractConversationTurns(doc, platform, baseUrl = "") {
  if (!doc || typeof doc.querySelectorAll !== "function") return [];
  const adapter = TURN_ADAPTERS[platform];
  if (!adapter) return [];

  const candidates = adapter.collectCandidates
    ? adapter.collectCandidates(doc)
    : Array.from(doc.querySelectorAll(adapter.candidateSelector));

  const outerTurns = dedupeOuterElements(candidates);
  const turns = [];
  for (const el of outerTurns) {
    const role = adapter.inferRole(el);
    if (role !== "user" && role !== "assistant") continue;
    const text = extractTurnBodyMarkdown(el, baseUrl);
    if (!text) continue;
    turns.push({ role, text, element: el });
  }
  return turns;
}

function contextThroughSelection(messages, range, maxRounds) {
  if (!range) return null;
  const selectedIndex = messages.findIndex(({ element }) =>
    nodeContains(element, range.startContainer) && nodeContains(element, range.endContainer)
  );

  let roundStart = -1;
  let rounds = 0;
  let prompt = "";
  for (let i = selectedIndex; i >= 0 && rounds < maxRounds; i -= 1) {
    const message = messages[i];
    if (message.role !== "user") continue;
    if (rounds === 0 && i !== selectedIndex) prompt = message.text;
    roundStart = i;
    rounds += 1;
  }

  if (roundStart < 0) return null;
  return { prompt, messages: messages.slice(roundStart, selectedIndex + 1) };
}

function truncateCleanly(str, maxChars) {
  if (str.length <= maxChars) return str;
  if (maxChars <= 1) return str.slice(0, maxChars);
  let cut = str.slice(0, maxChars - 1);
  const lastCode = cut.charCodeAt(cut.length - 1);
  if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
    cut = cut.slice(0, -1);
  }
  return `${cut.trimEnd()}…`;
}

export function formatRecentTurns(turnsSlice, maxChars = 4000) {
  if (!Array.isArray(turnsSlice) || turnsSlice.length === 0) return "";
  const formatted = turnsSlice.map((t) => ({
    prefix: t.role === "user" ? "User: " : "Assistant: ",
    body: t.text.trim()
  }));

  const joinEntries = (entries) => entries.map((e) => `${e.prefix}${e.body}`).join("\n\n");
  const full = joinEntries(formatted);
  if (full.length <= maxChars) return full;

  const separatorOverhead = (formatted.length - 1) * 2;
  const prefixOverhead = formatted.reduce((acc, e) => acc + e.prefix.length, 0);
  const availableBody = Math.max(40, maxChars - separatorOverhead - prefixOverhead);
  const perTurnBudget = Math.max(10, Math.floor(availableBody / formatted.length));

  const trimmed = formatted.map((e) => ({
    prefix: e.prefix,
    body: truncateCleanly(e.body, perTurnBudget)
  }));
  return truncateCleanly(joinEntries(trimmed), maxChars);
}

export function buildFallbackClip({ selectedMarkdown, sourceUrl = "", title = "" } = {}) {
  const normalizedUrl = String(sourceUrl || "").trim();
  return {
    selectedMarkdown: String(selectedMarkdown ?? ""),
    sourcePlatform: detectPlatform(normalizedUrl),
    sessionTitle: cleanSessionTitle(title),
    prompt: "",
    recentTurns: "",
    sourceUrl: normalizedUrl
  };
}

export function extractClipContext({
  doc,
  selectionRange = null,
  selectedText = null,
  url = "",
  maxRecentRounds = 4,
  maxRecentChars = 4000
} = {}) {
  const sourceUrl = String(url || (doc && doc.location && doc.location.href) || "").trim();
  const selectedMarkdown = selectionToMarkdown(selectionRange, sourceUrl, selectedText);
  const base = buildFallbackClip({ selectedMarkdown, sourceUrl, title: doc?.title || "" });
  if (!doc) return base;

  const sessionTitle = extractSessionTitle(doc, sourceUrl, base.sourcePlatform);
  const messages = extractConversationTurns(doc, base.sourcePlatform, sourceUrl);
  const context = contextThroughSelection(messages, selectionRange, maxRecentRounds);

  return {
    ...base,
    sessionTitle,
    prompt: context ? truncateCleanly(context.prompt.trim(), 1500) : "",
    recentTurns: context ? formatRecentTurns(context.messages, maxRecentChars) : ""
  };
}

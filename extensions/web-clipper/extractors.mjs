// SPDX-License-Identifier: MIT
// Adapted from MIT-licensed patterns in:
// - mem0ai/mem0-chrome-extension (selection capture)
// - revivalstack/ai-chat-exporter (multi-provider chat turn & title DOM patterns)
// - pionxzh/chatgpt-exporter (conversation turn & HTML-to-Markdown conversion)

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
  "strong", "b", "em", "i", "del", "s", "a", "ul", "ol", "li",
  "blockquote", "table", "p", "section", "article", "div"
]);

const GENERIC_TITLES = new Set([
  "", "chatgpt", "claude", "gemini", "google gemini",
  "new chat", "untitled", "新对话", "新建对话", "新建聊天"
]);

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

export function cleanSessionTitle(rawTitle) {
  if (!rawTitle || typeof rawTitle !== "string") return "";
  let cleaned = rawTitle
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\s*[-|·]\s*(?:ChatGPT|Claude|Google Gemini|Gemini)\s*$/i, "")
    .replace(/^(?:ChatGPT|Claude|Google Gemini|Gemini)\s*[-|·]\s*/i, "")
    .trim();
  if (GENERIC_TITLES.has(cleaned.toLowerCase())) {
    return "";
  }
  return cleaned;
}

function queryFirstText(doc, selectors) {
  if (!doc || typeof doc.querySelectorAll !== "function") return "";
  for (const selector of selectors) {
    let nodes;
    try {
      nodes = doc.querySelectorAll(selector);
    } catch {
      continue;
    }
    for (const node of nodes) {
      const candidate = cleanSessionTitle(node.textContent || "");
      if (candidate) return candidate;
    }
  }
  return "";
}

export function extractSessionTitle(doc, url = "", platform = detectPlatform(url)) {
  if (!doc) return "";
  const selectorsByPlatform = {
    chatgpt: [
      "[data-testid='conversation-title']",
      "nav a[data-active]",
      "nav a[aria-current='page']",
      "[data-testid='history-item-active']",
      "nav [aria-selected='true']"
    ],
    claude: [
      "[data-testid='chat-title-button']",
      "button[data-testid='rename-chat-trigger']",
      "[data-testid='conversation-title']",
      "nav a[aria-current='page']",
      "aside a[aria-current='page']"
    ],
    gemini: [
      ".selected .conversation-title",
      "[data-test-id='conversation-title']",
      ".conversation-title",
      "nav [aria-selected='true']",
      "nav a[aria-current='page']"
    ],
    web: []
  };

  const fromDom = queryFirstText(doc, selectorsByPlatform[platform] || []);
  if (fromDom) return fromDom;

  const fromDocTitle = cleanSessionTitle(doc.title || "");
  if (fromDocTitle) return fromDocTitle;

  return queryFirstText(doc, ["main h1", "article h1", "h1"]);
}

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

function isInlineCodeElement(node) {
  return getTagName(node) === "code" || getAttr(node, "data-markdown-copy") === "inline-code";
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

function getVisibleText(node) {
  if (!node) return "";
  if (node.nodeType === TEXT_NODE) return node.nodeValue || node.textContent || "";
  if (node.nodeType !== ELEMENT_NODE && node.nodeType !== DOCUMENT_FRAGMENT_NODE && node.nodeType !== DOCUMENT_NODE) {
    return "";
  }
  const tag = getTagName(node);
  if (SKIP_TAGS.has(tag)) return "";
  if (getAttr(node, "aria-hidden") === "true") return "";
  const children = node.childNodes || [];
  let out = "";
  for (const child of children) {
    out += getVisibleText(child);
  }
  return out;
}

function extractLanguageFromNode(node) {
  if (!node) return "";
  const directAttr = getAttr(node, "data-language") || getAttr(node, "data-lang");
  if (directAttr) return directAttr.trim().toLowerCase();

  const cls = getClassString(node);
  const match = cls.match(/(?:^|\s)(?:language-|lang-)([a-zA-Z0-9_+#.-]+)/);
  if (match) return match[1].toLowerCase();
  return "";
}

function findFirstDescendantTag(root, targetTag) {
  const children = (root && root.childNodes) || [];
  for (const child of children) {
    if (child.nodeType === ELEMENT_NODE) {
      if (getTagName(child) === targetTag) return child;
      const nested = findFirstDescendantTag(child, targetTag);
      if (nested) return nested;
    }
  }
  return null;
}

function extractCodeText(node) {
  if (!node) return "";
  if (node.nodeType === TEXT_NODE) return node.nodeValue ?? node.textContent ?? "";
  if (node.nodeType !== ELEMENT_NODE && node.nodeType !== DOCUMENT_FRAGMENT_NODE) return "";
  const tag = getTagName(node);
  if (tag === "br") return "\n";
  if (SKIP_TAGS.has(tag)) return "";
  let out = "";
  for (const child of node.childNodes || []) {
    out += extractCodeText(child);
  }
  return out;
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

function resolveHref(href, baseUrl) {
  if (!href) return "";
  const trimmed = href.trim();
  if (!trimmed || /^(?:javascript|vbscript|data):/i.test(trimmed)) return "";
  if (!baseUrl) return trimmed;
  try {
    return new URL(trimmed, baseUrl).href;
  } catch {
    return trimmed;
  }
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

function renderList(listEl, ordered, ctx) {
  const depth = ctx.listDepth || 0;
  const indent = "  ".repeat(depth);
  const startAttr = parseInt(getAttr(listEl, "start") || "1", 10);
  let index = Number.isFinite(startAttr) && startAttr > 0 ? startAttr : 1;
  const lines = [];

  for (const child of listEl.childNodes || []) {
    if (child.nodeType !== ELEMENT_NODE) continue;
    const childTag = getTagName(child);
    if (childTag !== "li") continue;

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

    const marker = ordered ? `${index}. ` : "- ";
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
  const element = node.parentElement;
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
  if (SKIP_TAGS.has(tag)) return "";
  if (getAttr(node, "data-markdown-copy") === "exclude") return "";
  if (hasClass(node, "screen-reader-user-query-label")) return "";

  const katex = extractKatexTex(node);
  if (katex !== null) return katex;

  if (getAttr(node, "aria-hidden") === "true") return "";

  if (tag === "br") return "\n";
  if (tag === "hr") return "\n\n---\n\n";

  if (tag === "pre") {
    const codeEl = findFirstDescendantTag(node, "code");
    const lang =
      extractLanguageFromNode(codeEl) ||
      extractLanguageFromNode(node) ||
      (codeEl ? inferPreHeaderLanguage(node, codeEl) : "");
    const rawCode = extractCodeText(codeEl || node);
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

  if (tag === "a") {
    const inner = convertChildren(node, ctx).trim();
    const href = resolveHref(getAttr(node, "href"), ctx.baseUrl);
    if (!href) return inner;
    const label = inner || href;
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

  if (tag === "p" || tag === "section" || tag === "article") {
    const inner = convertChildren(node, ctx).trim();
    return inner ? `\n\n${inner}\n\n` : "";
  }

  if (tag === "div" || tag === "li") {
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
  const root = typeof nodeOrHtml === "string" ? parseHtmlDocument(nodeOrHtml).body : nodeOrHtml;
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
  if (!selectionOrRange) return "";

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

  const ancestorPre = findAncestorElement(range.commonAncestorContainer, (el) => getTagName(el) === "pre");
  if (ancestorPre) {
    const ancestorCode =
      findAncestorElement(range.commonAncestorContainer, (el) => getTagName(el) === "code") ||
      findFirstDescendantTag(ancestorPre, "code");
    const lang =
      extractLanguageFromNode(ancestorCode) ||
      extractLanguageFromNode(ancestorPre) ||
      (ancestorCode ? inferPreHeaderLanguage(ancestorPre, ancestorCode) : "");
    const fragment = range.cloneContents();
    const codeText = extractCodeText(fragment) || plainFallback;
    if (codeText.trim()) {
      return formatFencedCodeBlock(codeText, lang, true).trim();
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

function inferChatGptTurnRole(el) {
  const direct = (getAttr(el, "data-message-author-role") || getAttr(el, "data-turn") || "").toLowerCase();
  if (direct === "user") return "user";
  if (direct === "assistant") return "assistant";
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

function inferClaudeTurnRole(el) {
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

function inferGeminiTurnRole(el) {
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

  let candidates = [];
  let inferRole = null;

  if (platform === "chatgpt") {
    const roleNodes = Array.from(
      doc.querySelectorAll("[data-message-author-role], h4[data-conversation-role]"),
      (node) => getAttr(node, "data-conversation-role") ? node.parentElement : node
    );
    candidates = roleNodes.length > 0
      ? roleNodes
      : Array.from(doc.querySelectorAll("article[data-testid^='conversation-turn-'], [data-testid^='conversation-turn-']"));
    inferRole = inferChatGptTurnRole;
  } else if (platform === "claude") {
    candidates = Array.from(
      doc.querySelectorAll(
        "[data-testid='user-message'], [data-testid='assistant-message'], [data-testid='chat-message-content'], .font-user-message, .font-claude-message, .font-claude-response, [data-role='user'], [data-role='assistant']"
      )
    );
    inferRole = inferClaudeTurnRole;
  } else if (platform === "gemini") {
    candidates = Array.from(
      doc.querySelectorAll(
        "user-query, model-response, user-query-content, message-content, .user-query-container, .model-response-text, [data-message-author-role='user'], [data-message-author-role='model'], [data-message-author-role='assistant'], [data-turn-role='user'], [data-turn-role='model']"
      )
    );
    inferRole = inferGeminiTurnRole;
  } else {
    return [];
  }

  const outerTurns = dedupeOuterElements(candidates);
  const turns = [];
  for (const el of outerTurns) {
    const role = inferRole(el);
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

export function extractClipContext({
  doc,
  selectionRange = null,
  selectedText = null,
  url = "",
  maxRecentRounds = 4,
  maxRecentChars = 4000
} = {}) {
  const sourceUrl = String(url || (doc && doc.location && doc.location.href) || "").trim();
  const sourcePlatform = detectPlatform(sourceUrl);
  const selectedMarkdown = selectionToMarkdown(selectionRange, sourceUrl, selectedText);
  const sessionTitle = extractSessionTitle(doc, sourceUrl, sourcePlatform);

  const messages = extractConversationTurns(doc, sourcePlatform, sourceUrl);
  const context = contextThroughSelection(messages, selectionRange, maxRecentRounds);

  return {
    selectedMarkdown,
    sourcePlatform,
    sessionTitle,
    prompt: context ? truncateCleanly(context.prompt.trim(), 1500) : "",
    recentTurns: context ? formatRecentTurns(context.messages, maxRecentChars) : "",
    sourceUrl
  };
}

function decodeHtmlEntities(str) {
  if (!str || !str.includes("&")) return str;
  const map = {
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": "\"",
    "&#39;": "'",
    "&apos;": "'",
    "&nbsp;": " "
  };
  return str.replace(/&(?:#x([0-9a-fA-F]+)|#([0-9]+)|[a-zA-Z0-9]+);/g, (m, hex, dec) => {
    if (hex) return String.fromCodePoint(parseInt(hex, 16));
    if (dec) return String.fromCodePoint(parseInt(dec, 10));
    return map[m] ?? m;
  });
}

function matchesSimpleSelector(el, compound) {
  if (!el || el.nodeType !== ELEMENT_NODE) return false;
  let rest = compound.trim();
  if (!rest || rest === "*") return true;

  const tagMatch = rest.match(/^[a-zA-Z][a-zA-Z0-9-]*/);
  if (tagMatch) {
    if (getTagName(el) !== tagMatch[0].toLowerCase()) return false;
    rest = rest.slice(tagMatch[0].length);
  }

  const tokenRegex = /#([a-zA-Z0-9_-]+)|\.([a-zA-Z0-9_-]+)|\[\s*([a-zA-Z0-9_:-]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\]]*?)))?\s*\]/g;
  let pos = 0;
  let match;
  while ((match = tokenRegex.exec(rest)) !== null) {
    if (match.index !== pos) return false;
    pos = tokenRegex.lastIndex;
    if (match[1]) {
      if (getAttr(el, "id") !== match[1]) return false;
    } else if (match[2]) {
      if (!hasClass(el, match[2])) return false;
    } else if (match[3]) {
      const attrVal = getAttr(el, match[3]);
      if (attrVal === null || attrVal === undefined) return false;
      if (match[4]) {
        const expected = match[5] ?? match[6] ?? (match[7] || "").trim();
        const op = match[4];
        if (op === "=" && attrVal !== expected) return false;
        if (op === "^=" && !attrVal.startsWith(expected)) return false;
        if (op === "$=" && !attrVal.endsWith(expected)) return false;
        if (op === "*=" && !attrVal.includes(expected)) return false;
        if (op === "~=" && !attrVal.split(/\s+/).includes(expected)) return false;
        if (op === "|=" && attrVal !== expected && !attrVal.startsWith(`${expected}-`)) return false;
      }
    }
  }
  return pos === rest.length;
}

function matchesSelectorChain(el, chainParts) {
  if (!matchesSimpleSelector(el, chainParts[chainParts.length - 1])) return false;
  let cur = el.parentNode;
  for (let i = chainParts.length - 2; i >= 0; i -= 1) {
    while (cur && cur.nodeType === ELEMENT_NODE && !matchesSimpleSelector(cur, chainParts[i])) {
      cur = cur.parentNode;
    }
    if (!cur || cur.nodeType !== ELEMENT_NODE) return false;
    cur = cur.parentNode;
  }
  return true;
}

function splitSelectorChain(selector) {
  const parts = [];
  let buf = "";
  let inBracket = 0;
  let quote = "";
  for (const ch of selector.trim()) {
    if (quote) {
      buf += ch;
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === "\"" || ch === "'") {
      quote = ch;
      buf += ch;
    } else if (ch === "[") {
      inBracket += 1;
      buf += ch;
    } else if (ch === "]") {
      inBracket = Math.max(0, inBracket - 1);
      buf += ch;
    } else if (/\s/.test(ch) && inBracket === 0) {
      if (buf) {
        parts.push(buf);
        buf = "";
      }
    } else {
      buf += ch;
    }
  }
  if (buf) parts.push(buf);
  return parts;
}

function splitSelectorGroup(selectorList) {
  const groups = [];
  let buf = "";
  let inBracket = 0;
  let quote = "";
  for (const ch of selectorList) {
    if (quote) {
      buf += ch;
      if (ch === quote) quote = "";
    } else if (ch === "\"" || ch === "'") {
      quote = ch;
      buf += ch;
    } else if (ch === "[") {
      inBracket += 1;
      buf += ch;
    } else if (ch === "]") {
      inBracket = Math.max(0, inBracket - 1);
      buf += ch;
    } else if (ch === "," && inBracket === 0) {
      if (buf.trim()) groups.push(buf.trim());
      buf = "";
    } else {
      buf += ch;
    }
  }
  if (buf.trim()) groups.push(buf.trim());
  return groups;
}

class MiniNode {
  constructor(nodeType, nodeName) {
    this.nodeType = nodeType;
    this.nodeName = nodeName;
    this.parentNode = null;
    this.childNodes = [];
  }

  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === ELEMENT_NODE ? this.parentNode : null;
  }

  get children() {
    return this.childNodes.filter((c) => c.nodeType === ELEMENT_NODE);
  }

  appendChild(child) {
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }

  contains(other) {
    let cur = other;
    while (cur) {
      if (cur === this) return true;
      cur = cur.parentNode;
    }
    return false;
  }

  cloneNode(deep = false) {
    const copy = new MiniNode(this.nodeType, this.nodeName);
    if (deep) {
      for (const c of this.childNodes) copy.appendChild(c.cloneNode(true));
    }
    return copy;
  }

  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }

  querySelectorAll(selectorList) {
    const chains = splitSelectorGroup(selectorList).map(splitSelectorChain).filter((c) => c.length > 0);
    const matches = [];
    const visit = (node) => {
      for (const child of node.childNodes) {
        if (child.nodeType === ELEMENT_NODE) {
          if (chains.some((chain) => matchesSelectorChain(child, chain))) {
            matches.push(child);
          }
          visit(child);
        }
      }
    };
    visit(this);
    return matches;
  }

  querySelector(selectorList) {
    return this.querySelectorAll(selectorList)[0] || null;
  }
}

class MiniText extends MiniNode {
  constructor(value) {
    super(TEXT_NODE, "#text");
    this.nodeValue = value;
  }

  get textContent() {
    return this.nodeValue;
  }

  cloneNode() {
    return new MiniText(this.nodeValue);
  }
}

class MiniElement extends MiniNode {
  constructor(tagName, attributes = {}) {
    super(ELEMENT_NODE, tagName.toUpperCase());
    this.tagName = tagName.toUpperCase();
    this.attributes = attributes;
  }

  get className() {
    return this.attributes.class || "";
  }

  get id() {
    return this.attributes.id || "";
  }

  getAttribute(name) {
    const key = String(name).toLowerCase();
    return Object.prototype.hasOwnProperty.call(this.attributes, key) ? this.attributes[key] : null;
  }

  cloneNode(deep = false) {
    const copy = new MiniElement(this.tagName, { ...this.attributes });
    if (deep) {
      for (const c of this.childNodes) copy.appendChild(c.cloneNode(true));
    }
    return copy;
  }
}

export function parseHtmlDocument(html, { url = "" } = {}) {
  const doc = new MiniNode(DOCUMENT_NODE, "#document");
  doc.location = { href: url };
  const root = new MiniElement("body");
  doc.body = root;
  doc.appendChild(root);

  const stack = [root];
  const tagRegex = /<!--[\s\S]*?-->|<\/?([a-zA-Z][a-zA-Z0-9-]*)(\s[^>]*)?>/g;
  let lastIndex = 0;
  let match;

  const parseAttrs = (rawAttrs) => {
    const attrs = {};
    if (!rawAttrs) return attrs;
    const attrRegex = /([a-zA-Z0-9_:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let m;
    while ((m = attrRegex.exec(rawAttrs)) !== null) {
      const k = m[1].toLowerCase();
      const v = decodeHtmlEntities(m[2] ?? m[3] ?? m[4] ?? "");
      attrs[k] = v;
    }
    return attrs;
  };

  while ((match = tagRegex.exec(html)) !== null) {
    if (match.index > lastIndex) {
      const rawText = html.slice(lastIndex, match.index);
      const decoded = decodeHtmlEntities(rawText);
      if (decoded) stack[stack.length - 1].appendChild(new MiniText(decoded));
    }
    lastIndex = tagRegex.lastIndex;

    const fullToken = match[0];
    if (fullToken.startsWith("<!--")) continue;

    const tagName = match[1].toLowerCase();
    const isClosing = fullToken.startsWith("</");
    const isSelfClosing = fullToken.endsWith("/>") || VOID_TAGS.has(tagName);

    if (isClosing) {
      for (let i = stack.length - 1; i > 0; i -= 1) {
        if (getTagName(stack[i]) === tagName) {
          stack.length = i;
          break;
        }
      }
    } else {
      const el = new MiniElement(tagName, parseAttrs(match[2]));
      stack[stack.length - 1].appendChild(el);
      if (!isSelfClosing) {
        stack.push(el);
      }
    }
  }

  if (lastIndex < html.length) {
    const tail = decodeHtmlEntities(html.slice(lastIndex));
    if (tail) stack[stack.length - 1].appendChild(new MiniText(tail));
  }

  const titleEl = doc.querySelector("title");
  doc.title = titleEl ? titleEl.textContent : "";

  doc.createRangeFromNode = (targetNode) => ({
    startContainer: targetNode,
    startOffset: 0,
    endContainer: targetNode,
    endOffset: targetNode.nodeType === TEXT_NODE ? targetNode.nodeValue.length : targetNode.childNodes.length,
    commonAncestorContainer: targetNode,
    intersectsNode(node) {
      return targetNode.contains(node);
    },
    cloneContents() {
      const frag = new MiniNode(DOCUMENT_FRAGMENT_NODE, "#document-fragment");
      for (const child of targetNode.childNodes || []) {
        frag.appendChild(child.cloneNode(true));
      }
      if ((targetNode.childNodes || []).length === 0 && targetNode.nodeType === TEXT_NODE) {
        frag.appendChild(targetNode.cloneNode(true));
      }
      return frag;
    },
    toString() {
      return targetNode.textContent || "";
    }
  });

  return doc;
}

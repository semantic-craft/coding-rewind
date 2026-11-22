// SPDX-License-Identifier: MIT

const ELEMENT_NODE = 1;
const TEXT_NODE = 3;
const DOCUMENT_NODE = 9;
const DOCUMENT_FRAGMENT_NODE = 11;

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "param", "source", "track", "wbr"
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

function hasClass(node, cls) {
  const raw = typeof node?.className === "string" ? node.className : (getAttr(node, "class") || "");
  return raw ? raw.split(/\s+/).includes(cls) : false;
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
    return Array.from(this.childNodes || []).filter((c) => c.nodeType === ELEMENT_NODE);
  }

  appendChild(child) {
    if (child.parentNode && typeof child.parentNode.removeChild === "function") {
      child.parentNode.removeChild(child);
    }
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }

  removeChild(child) {
    const idx = this.childNodes.indexOf(child);
    if (idx >= 0) {
      this.childNodes.splice(idx, 1);
      child.parentNode = null;
    }
    return child;
  }

  remove() {
    if (this.parentNode && typeof this.parentNode.removeChild === "function") {
      this.parentNode.removeChild(this);
    }
  }

  compareDocumentPosition(other) {
    if (!other || this === other) return 0;
    if (this.contains(other)) return 16 | 4;
    if (typeof other.contains === "function" && other.contains(this)) return 8 | 2;

    const rootOf = (n) => {
      let cur = n;
      while (cur.parentNode) cur = cur.parentNode;
      return cur;
    };
    const root = rootOf(this);
    if (root !== rootOf(other)) return 1;

    let foundThis = false;
    let foundOther = false;
    let result = 0;
    const walk = (n) => {
      if (result) return;
      if (n === this) {
        if (foundOther) {
          result = 2;
          return;
        }
        foundThis = true;
      } else if (n === other) {
        if (foundThis) {
          result = 4;
          return;
        }
        foundOther = true;
      }
      for (const c of Array.from(n.childNodes || [])) {
        walk(c);
        if (result) return;
      }
    };
    walk(root);
    return result || 1;
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
      for (const c of Array.from(this.childNodes || [])) copy.appendChild(c.cloneNode(true));
    }
    return copy;
  }

  get textContent() {
    return Array.from(this.childNodes || [], (c) => c.textContent).join("");
  }

  querySelectorAll(selectorList) {
    const chains = splitSelectorGroup(selectorList).map(splitSelectorChain).filter((c) => c.length > 0);
    const matches = [];
    const visit = (node) => {
      for (const child of Array.from(node.childNodes || [])) {
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
    this._checked = undefined;
    this._readOnly = undefined;
    this._disabled = undefined;
  }

  get className() {
    return this.attributes.class || "";
  }

  get id() {
    return this.attributes.id || "";
  }

  get type() {
    return this.attributes.type || "";
  }

  get checked() {
    return this._checked !== undefined
      ? Boolean(this._checked)
      : Object.prototype.hasOwnProperty.call(this.attributes, "checked");
  }

  set checked(val) {
    this._checked = Boolean(val);
  }

  get readOnly() {
    return this._readOnly !== undefined
      ? Boolean(this._readOnly)
      : Object.prototype.hasOwnProperty.call(this.attributes, "readonly");
  }

  set readOnly(val) {
    this._readOnly = Boolean(val);
  }

  get disabled() {
    return this._disabled !== undefined
      ? Boolean(this._disabled)
      : Object.prototype.hasOwnProperty.call(this.attributes, "disabled");
  }

  set disabled(val) {
    this._disabled = Boolean(val);
  }

  get isContentEditable() {
    if (!Object.prototype.hasOwnProperty.call(this.attributes, "contenteditable")) {
      return Boolean(this.parentElement && this.parentElement.isContentEditable);
    }
    const raw = String(this.attributes.contenteditable || "").trim().toLowerCase();
    return raw === "" || raw === "true" || raw === "plaintext-only";
  }

  getAttribute(name) {
    const key = String(name).toLowerCase();
    return Object.prototype.hasOwnProperty.call(this.attributes, key) ? this.attributes[key] : null;
  }

  setAttribute(name, val) {
    this.attributes[String(name).toLowerCase()] = String(val);
  }

  cloneNode(deep = false) {
    const copy = new MiniElement(this.tagName, { ...this.attributes });
    copy._checked = this._checked;
    copy._readOnly = this._readOnly;
    copy._disabled = this._disabled;
    if (deep) {
      for (const c of Array.from(this.childNodes || [])) copy.appendChild(c.cloneNode(true));
    }
    return copy;
  }
}

export function parseHtmlDocument(html, { url = "" } = {}) {
  const doc = new MiniNode(DOCUMENT_NODE, "#document");
  doc.location = { href: url };
  doc.implementation = {
    createHTMLDocument: () => ({ importNode: (node, deep) => node.cloneNode(deep) })
  };
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
      for (const child of Array.from(targetNode.childNodes || [])) {
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

export class DOMParser {
  parseFromString(html) {
    return parseHtmlDocument(String(html ?? ""));
  }
}

if (typeof globalThis.DOMParser === "undefined") {
  globalThis.DOMParser = DOMParser;
}

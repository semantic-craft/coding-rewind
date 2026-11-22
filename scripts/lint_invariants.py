#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

import argparse
import bisect
from dataclasses import dataclass
import io
import json
import os
from pathlib import Path
import re
import sys
import tokenize

sys.dont_write_bytecode = True

SCAN_ROOTS = ("Sources", "Tests", "deploy", "extensions", "dsh-plugin", "scripts", "verification")
SKIP_DIRS = frozenset({
    ".git",
    ".build",
    "Vendor",
    "vendor",
    "node_modules",
    "__pycache__",
    "dist",
    "build",
    ".test-data",
    ".venv",
    "venv",
})

EXT_TO_LANG = {
    ".py": "python",
    ".swift": "swift",
    ".js": "js",
    ".mjs": "js",
    ".cjs": "js",
    ".ts": "js",
    ".tsx": "js",
    ".jsx": "js",
    ".sh": "shell",
    ".bash": "shell",
    ".zsh": "shell",
}

SHEBANG_PYTHON_RE = re.compile(r"^#!.*python")
SHEBANG_NODE_RE = re.compile(r"^#!.*node")
SHEBANG_SHELL_RE = re.compile(r"^#!.*\b(?:sh|bash|zsh)\b")
CODING_COOKIE_RE = re.compile(r"^#\s*(?:-\*-\s*.*?\bcoding[:=]\s*[-\w.]+.*?-\*-|coding[:=]\s*[-\w.]+)")
SWIFT_TOOLS_RE = re.compile(r"^//\s*swift-tools-version\s*:")
LICENSE_RE = re.compile(
    r"SPDX-License-Identifier|Copyright|MIT License|Apache License|Licensed under|Adapted from",
    re.IGNORECASE,
)
DIRECTIVE_RE = re.compile(
    r"(?:"
    r"eslint-disable"
    r"|@ts-ignore\b"
    r"|@ts-expect-error\b"
    r"|prettier-ignore\b"
    r"|swiftlint:"
    r"|swiftformat:"
    r"|\bnoqa\b"
    r"|\btype:\s*ignore\b"
    r"|\bpyright:"
    r"|\bruff:"
    r"|\bpragma:\s*no\s+cover\b"
    r"|\bshellcheck\s+disable\b"
    r"|\bnotary-policy:"
    r"|\bswiftui-perf:"
    r")"
)

JS_REGEX_KEYWORDS = frozenset({
    "return",
    "throw",
    "case",
    "delete",
    "void",
    "typeof",
    "instanceof",
    "in",
    "of",
    "new",
    "yield",
    "await",
    "else",
    "do",
})
JS_REGEX_PUNCT = frozenset({
    "(",
    "[",
    "{",
    ",",
    ";",
    ":",
    "?",
    "=",
    "!",
    "&",
    "|",
    "^",
    "~",
    "+",
    "-",
    "*",
    "%",
    "=>",
    "COND_END",
})
JS_COND_PARENS = frozenset({"if", "while", "for", "with"})
SHELL_HEREDOC_OP_RE = re.compile(
    r"""<<(-?)[ \t]*(?:'([^'\n]+)'|"([^"\n]+)"|\\?([A-Za-z_][A-Za-z0-9_.-]*))"""
)

TOOLTIP_RE = re.compile(r"\.\s*toolTip\s*=(?!=)")
NSWORKSPACE_OPEN_RE = re.compile(r"\bNSWorkspace\s*\.\s*shared\s*\.\s*open\s*\(")
DOM_COLLECTION_ARRAY_METHOD_RE = re.compile(
    r"(?:\.childNodes|\.children|\bgetClientRects\s*\(\s*\))\s*\??\.\s*(?:some|map|filter|forEach|reduce|find)\s*\("
)
MENU_BAR_EXTRA_RE = re.compile(r"\bMenuBarExtra\b")


@dataclass(frozen=True)
class RawComment:
    start_line: int
    end_line: int
    col: int
    text: str
    inline: bool


class LineIndex:
    def __init__(self, text: str) -> None:
        self.text = text
        self.lines = text.splitlines()
        starts = [0]
        for idx, ch in enumerate(text):
            if ch == "\n":
                starts.append(idx + 1)
        self.starts = starts

    def line_of(self, offset: int) -> int:
        return bisect.bisect_right(self.starts, offset)

    def make_comment(self, start: int, end: int) -> RawComment:
        while end > start and self.text[end - 1] in ("\n", "\r"):
            end -= 1
        start_line = self.line_of(start)
        col = start - self.starts[start_line - 1]
        last_idx = max(start, end - 1)
        end_line = self.line_of(last_idx)
        end_col = end - self.starts[end_line - 1]
        before = self.lines[start_line - 1][:col].strip() if start_line <= len(self.lines) else ""
        after = self.lines[end_line - 1][end_col:].strip() if end_line <= len(self.lines) else ""
        return RawComment(
            start_line=start_line,
            end_line=end_line,
            col=col,
            text=self.text[start:end],
            inline=bool(before or after),
        )


def _blank_preserving_newlines(segment: str) -> str:
    return "".join("\n" if ch == "\n" else " " for ch in segment)


def _scan_quoted(text: str, quote_pos: int, quote_ch: str, multiline: bool = True) -> int:
    n = len(text)
    i = quote_pos + 1
    while i < n:
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == quote_ch:
            return i + 1
        if not multiline and ch == "\n":
            return i
        i += 1
    return n


def lex_python_comments(text: str) -> list[RawComment]:
    lines = text.splitlines()
    out: list[RawComment] = []
    reader = io.StringIO(text).readline
    try:
        for tok in tokenize.generate_tokens(reader):
            if tok.type == tokenize.COMMENT:
                s_line, s_col = tok.start
                e_line, _ = tok.end
                before = lines[s_line - 1][:s_col].strip() if s_line <= len(lines) else ""
                out.append(
                    RawComment(
                        start_line=s_line,
                        end_line=e_line,
                        col=s_col,
                        text=tok.string.rstrip("\r\n"),
                        inline=bool(before),
                    )
                )
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return out


def scan_swift(text: str) -> tuple[list[RawComment], str]:
    idx = LineIndex(text)
    comments: list[RawComment] = []
    masked: list[str] = []
    n = len(text)
    i = 0
    interp_stack: list[tuple[bool, int, int]] = []

    if text.startswith("#!"):
        nl = text.find("\n")
        end = n if nl == -1 else nl
        comments.append(idx.make_comment(0, end))
        masked.append(_blank_preserving_newlines(text[0:end]))
        i = end

    def continue_swift_string(multiline: bool, hashes: int) -> None:
        nonlocal i
        closing = ('"""' if multiline else '"') + ("#" * hashes)
        escape = "\\" + ("#" * hashes)
        start = i
        while i < n:
            if text.startswith(closing, i):
                i += len(closing)
                masked.append(_blank_preserving_newlines(text[start:i]))
                return
            if not multiline and text[i] == "\n":
                masked.append(_blank_preserving_newlines(text[start:i]))
                return
            if text.startswith(escape, i):
                after_esc = i + len(escape)
                if after_esc < n and text[after_esc] == "(":
                    interp_stack.append((multiline, hashes, 1))
                    masked.append(_blank_preserving_newlines(text[start:after_esc]))
                    masked.append("(")
                    i = after_esc + 1
                    return
                i = min(n, after_esc + 1)
                continue
            i += 1
        masked.append(_blank_preserving_newlines(text[start:i]))

    while i < n:
        if text.startswith("//", i):
            nl = text.find("\n", i + 2)
            end = n if nl == -1 else nl
            comments.append(idx.make_comment(i, end))
            masked.append(_blank_preserving_newlines(text[i:end]))
            i = end
            continue
        if text.startswith("/*", i):
            start = i
            i += 2
            depth = 1
            while i < n and depth > 0:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            comments.append(idx.make_comment(start, i))
            masked.append(_blank_preserving_newlines(text[start:i]))
            continue

        if text[i] == "#":
            j = i
            while j < n and text[j] == "#":
                j += 1
            hashes = j - i
            if j < n and text[j] == '"':
                if text.startswith('"""', j):
                    masked.append(_blank_preserving_newlines(text[i : j + 3]))
                    i = j + 3
                    continue_swift_string(True, hashes)
                else:
                    masked.append(_blank_preserving_newlines(text[i : j + 1]))
                    i = j + 1
                    continue_swift_string(False, hashes)
                continue
            masked.append(text[i:j])
            i = j
            continue

        if text[i] == '"':
            if text.startswith('"""', i):
                masked.append("   ")
                i += 3
                continue_swift_string(True, 0)
            else:
                masked.append(" ")
                i += 1
                continue_swift_string(False, 0)
            continue

        if interp_stack:
            if text[i] == "(":
                ml, hs, depth = interp_stack[-1]
                interp_stack[-1] = (ml, hs, depth + 1)
                masked.append("(")
                i += 1
                continue
            if text[i] == ")":
                ml, hs, depth = interp_stack[-1]
                if depth <= 1:
                    interp_stack.pop()
                    masked.append(")")
                    i += 1
                    continue_swift_string(ml, hs)
                else:
                    interp_stack[-1] = (ml, hs, depth - 1)
                    masked.append(")")
                    i += 1
                continue

        masked.append(text[i])
        i += 1

    return comments, "".join(masked)


def _scan_js_regex(text: str, slash_pos: int) -> int | None:
    n = len(text)
    j = slash_pos + 1
    if j >= n or text[j] in ("\n", "\r", "*", "/"):
        return None
    in_class = False
    while j < n:
        ch = text[j]
        if ch in ("\n", "\r"):
            return None
        if ch == "\\":
            if j + 1 >= n or text[j + 1] in ("\n", "\r"):
                return None
            j += 2
            continue
        if ch == "[":
            in_class = True
            j += 1
            continue
        if ch == "]" and in_class:
            in_class = False
            j += 1
            continue
        if ch == "/" and not in_class:
            j += 1
            while j < n and text[j].isalpha():
                j += 1
            return j
        j += 1
    return None


def _js_allows_regex(prev_tok: str | None, prev_before_ident: str | None) -> bool:
    if prev_tok is None:
        return True
    if prev_tok in JS_REGEX_PUNCT:
        return True
    if prev_tok in JS_REGEX_KEYWORDS and prev_before_ident != ".":
        return True
    return False


def scan_js(text: str) -> tuple[list[RawComment], str]:
    idx = LineIndex(text)
    comments: list[RawComment] = []
    masked: list[str] = []
    n = len(text)
    i = 0

    if text.startswith("#!"):
        nl = text.find("\n")
        end = n if nl == -1 else nl
        comments.append(idx.make_comment(0, end))
        masked.append(_blank_preserving_newlines(text[0:end]))
        i = end

    prev_tok: str | None = None
    prev_before_ident: str | None = None
    template_brace_depths: list[int] = []
    paren_cond_stack: list[bool] = []

    def continue_template() -> None:
        nonlocal i, prev_tok, prev_before_ident
        start = i
        while i < n:
            ch = text[i]
            if ch == "\\":
                i += 2
                continue
            if ch == "`":
                i += 1
                masked.append(_blank_preserving_newlines(text[start:i]))
                prev_before_ident = prev_tok
                prev_tok = "`"
                return
            if text.startswith("${", i):
                masked.append(_blank_preserving_newlines(text[start:i]))
                masked.append("${")
                template_brace_depths.append(1)
                i += 2
                prev_before_ident = None
                prev_tok = "{"
                return
            i += 1
        masked.append(_blank_preserving_newlines(text[start:i]))

    while i < n:
        ch = text[i]
        if ch.isspace():
            masked.append(ch)
            i += 1
            continue

        if text.startswith("//", i):
            nl = text.find("\n", i + 2)
            end = n if nl == -1 else nl
            comments.append(idx.make_comment(i, end))
            masked.append(_blank_preserving_newlines(text[i:end]))
            i = end
            continue

        if text.startswith("/*", i):
            end_pos = text.find("*/", i + 2)
            end = n if end_pos == -1 else end_pos + 2
            comments.append(idx.make_comment(i, end))
            masked.append(_blank_preserving_newlines(text[i:end]))
            i = end
            continue

        if ch in ('"', "'"):
            end = _scan_quoted(text, i, ch, multiline=False)
            masked.append(_blank_preserving_newlines(text[i:end]))
            prev_before_ident = prev_tok
            prev_tok = ch
            i = end
            continue

        if ch == "`":
            masked.append(" ")
            i += 1
            continue_template()
            continue

        if ch == "/" and _js_allows_regex(prev_tok, prev_before_ident):
            regex_end = _scan_js_regex(text, i)
            if regex_end is not None:
                masked.append(_blank_preserving_newlines(text[i:regex_end]))
                i = regex_end
                prev_before_ident = prev_tok
                prev_tok = "REGEX"
                continue

        if ch == "(":
            paren_cond_stack.append(bool(prev_tok in JS_COND_PARENS and prev_before_ident != "."))
            prev_before_ident = prev_tok
            prev_tok = "("
            masked.append(ch)
            i += 1
            continue

        if ch == ")":
            is_cond = paren_cond_stack.pop() if paren_cond_stack else False
            prev_before_ident = prev_tok
            prev_tok = "COND_END" if is_cond else ")"
            masked.append(ch)
            i += 1
            continue

        if ch == "{" and template_brace_depths:
            template_brace_depths[-1] += 1
            prev_before_ident = prev_tok
            prev_tok = "{"
            masked.append(ch)
            i += 1
            continue

        if ch == "}" and template_brace_depths:
            template_brace_depths[-1] -= 1
            masked.append(ch)
            i += 1
            if template_brace_depths[-1] == 0:
                template_brace_depths.pop()
                continue_template()
            else:
                prev_before_ident = prev_tok
                prev_tok = "}"
            continue

        if ch.isalpha() or ch in ("_", "$"):
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] in ("_", "$")):
                j += 1
            prev_before_ident = prev_tok
            prev_tok = text[i:j]
            masked.append(prev_tok)
            i = j
            continue

        if ch.isdigit():
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] in ("_", ".")):
                j += 1
            prev_before_ident = prev_tok
            prev_tok = "NUM"
            masked.append(text[i:j])
            i = j
            continue

        if text.startswith("=>", i) or text.startswith("++", i) or text.startswith("--", i):
            prev_before_ident = prev_tok
            prev_tok = text[i : i + 2]
            masked.append(prev_tok)
            i += 2
            continue

        prev_before_ident = prev_tok
        prev_tok = ch
        masked.append(ch)
        i += 1

    return comments, "".join(masked)


def _skip_shell_param_expansion(text: str, pos: int) -> int:
    n = len(text)
    depth = 1
    i = pos
    while i < n and depth > 0:
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "'":
            end_q = text.find("'", i + 1)
            i = n if end_q == -1 else end_q + 1
            continue
        if ch == '"':
            i = _skip_shell_double_quoted(text, i + 1)
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        i += 1
    return i


def _skip_shell_double_quoted(text: str, pos: int) -> int:
    n = len(text)
    i = pos
    while i < n:
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            return i + 1
        if text.startswith("${", i):
            i = _skip_shell_param_expansion(text, i + 2)
            continue
        i += 1
    return n


def _heredoc_closes_later(text: str, search_from: int, delim: str, strip_tabs: bool) -> bool:
    pos = search_from
    n = len(text)
    while pos < n:
        nl = text.find("\n", pos)
        end = n if nl == -1 else nl
        line = text[pos:end].rstrip("\r")
        candidate = line.lstrip("\t") if strip_tabs else line
        if candidate == delim:
            return True
        if nl == -1:
            break
        pos = nl + 1
    return False


def lex_shell_comments(text: str) -> list[RawComment]:
    idx = LineIndex(text)
    out: list[RawComment] = []
    n = len(text)
    i = 0
    line_start = 0
    pending_heredocs: list[tuple[str, bool]] = []

    while i < n:
        ch = text[i]
        if ch == "\n":
            i += 1
            line_start = i
            while pending_heredocs and i < n:
                delim, strip_tabs = pending_heredocs.pop(0)
                while i < n:
                    nl = text.find("\n", i)
                    end = n if nl == -1 else nl
                    raw_line = text[i:end].rstrip("\r")
                    candidate = raw_line.lstrip("\t") if strip_tabs else raw_line
                    i = n if nl == -1 else nl + 1
                    line_start = i
                    if candidate == delim:
                        break
            continue

        if ch == "\\":
            if i + 1 < n and text[i + 1] == "\n":
                i += 2
                line_start = i
            else:
                i += 2
            continue

        if ch == "'":
            end_q = text.find("'", i + 1)
            i = n if end_q == -1 else end_q + 1
            continue

        if ch == '"':
            i = _skip_shell_double_quoted(text, i + 1)
            continue

        if ch == "$":
            if i + 1 < n:
                nxt = text[i + 1]
                if nxt == "{":
                    i = _skip_shell_param_expansion(text, i + 2)
                    continue
                if nxt == "'":
                    i = _scan_quoted(text, i + 1, "'", multiline=True)
                    continue
                if nxt in ("#", "?", "$", "!", "*", "@", "-") or nxt.isdigit():
                    i += 2
                    continue
            i += 1
            continue

        if text.startswith("<<<", i):
            i += 3
            continue

        if text.startswith("<<", i):
            m = SHELL_HEREDOC_OP_RE.match(text, i)
            if m:
                strip_tabs = m.group(1) == "-"
                delim = m.group(2) or m.group(3) or m.group(4) or ""
                nl = text.find("\n", m.end())
                if delim and nl != -1 and _heredoc_closes_later(text, nl + 1, delim, strip_tabs):
                    pending_heredocs.append((delim, strip_tabs))
                    i = m.end()
                    continue
            i += 2
            continue

        if ch == "#":
            if i == line_start or text[i - 1] in (" ", "\t", ";", "&", "|", "("):
                nl = text.find("\n", i)
                end = n if nl == -1 else nl
                out.append(idx.make_comment(i, end))
                i = end
                continue

        i += 1

    return out


def detect_language(rel: Path, first_line: str) -> str | None:
    ext = rel.suffix.lower()
    if ext in EXT_TO_LANG:
        return EXT_TO_LANG[ext]
    if ext:
        return None
    if not first_line.startswith("#!"):
        return None
    if SHEBANG_PYTHON_RE.match(first_line):
        return "python"
    if SHEBANG_NODE_RE.match(first_line):
        return "js"
    if SHEBANG_SHELL_RE.match(first_line):
        return "shell"
    return None


def compute_license_block_indices(raw_comments: list[RawComment]) -> set[int]:
    pure_indices = [idx for idx, c in enumerate(raw_comments) if not c.inline]
    exempt: set[int] = set()
    pos = 0
    while pos < len(pure_indices):
        group = [pure_indices[pos]]
        pos += 1
        while pos < len(pure_indices):
            prev_c = raw_comments[group[-1]]
            curr_c = raw_comments[pure_indices[pos]]
            if curr_c.start_line <= prev_c.end_line + 1:
                group.append(pure_indices[pos])
                pos += 1
            else:
                break
        if raw_comments[group[0]].start_line <= 30 and any(
            raw_comments[g].start_line <= 30 and LICENSE_RE.search(raw_comments[g].text)
            for g in group
        ):
            for g in group:
                if raw_comments[g].start_line <= 30:
                    exempt.add(g)
    return exempt


def is_exempt_comment(lang: str, comment: RawComment, in_license_block: bool) -> bool:
    if comment.start_line == 1 and comment.text.startswith("#!"):
        return True
    if comment.start_line in (1, 2) and not comment.inline and CODING_COOKIE_RE.match(comment.text):
        return True
    if comment.start_line == 1 and SWIFT_TOOLS_RE.match(comment.text):
        return True
    if in_license_block or (comment.start_line <= 30 and LICENSE_RE.search(comment.text)):
        return True
    if lang == "swift" and comment.text.startswith("///") and not comment.text.startswith("////"):
        return True
    if DIRECTIVE_RE.search(comment.text):
        return True
    return False


def walk_tree_files(root: Path, subdirs: tuple[str, ...]) -> list[Path]:
    found: list[Path] = []
    for sub in subdirs:
        base = root / sub
        if not base.exists() or base.is_symlink():
            continue
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            dp = Path(dirpath)
            dirnames[:] = sorted(
                d for d in dirnames if d not in SKIP_DIRS and not (dp / d).is_symlink()
            )
            for fn in sorted(filenames):
                full = dp / fn
                if full.is_symlink() or not full.is_file():
                    continue
                found.append(full.relative_to(root))
    return sorted(found, key=lambda p: p.as_posix())


def read_utf8(path: Path) -> str | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in raw[:8192]:
        return None
    return raw.decode("utf-8", errors="replace")


def fmt_fail(rel: str, lineno: int, message: str, fix: str) -> str:
    return f"FAIL: {rel}:{lineno}: {message}. Fix: {fix}"


def snippet_of(text: str, max_len: int = 80) -> str:
    first = text.splitlines()[0].strip() if text else ""
    return first[: max_len - 3] + "..." if len(first) > max_len else first


def check_comments_and_ratchet(root: Path) -> list[str]:
    errors: list[str] = []
    ratchet_path = root / ".comment-ratchet.json"
    if not ratchet_path.is_file():
        errors.append(
            fmt_fail(
                ".comment-ratchet.json",
                1,
                "missing .comment-ratchet.json",
                'create .comment-ratchet.json with "max_total": 0',
            )
        )
    else:
        try:
            cfg = json.loads(ratchet_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(
                fmt_fail(
                    ".comment-ratchet.json",
                    1,
                    f"invalid JSON in .comment-ratchet.json ({exc})",
                    'restore valid JSON with "max_total": 0',
                )
            )
        else:
            max_total = cfg.get("max_total") if isinstance(cfg, dict) else None
            if type(max_total) is not int or max_total != 0:
                errors.append(
                    fmt_fail(
                        ".comment-ratchet.json",
                        1,
                        f"comment ratchet max_total is {max_total!r}, expected 0",
                        'set "max_total": 0 in .comment-ratchet.json',
                    )
                )
            files_map = cfg.get("files") if isinstance(cfg, dict) else None
            if isinstance(files_map, dict) and any(
                isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in files_map.values()
            ):
                errors.append(
                    fmt_fail(
                        ".comment-ratchet.json",
                        1,
                        "comment ratchet files map contains non-zero ceiling",
                        'clear "files": {} in .comment-ratchet.json',
                    )
                )

    for rel in walk_tree_files(root, SCAN_ROOTS):
        text = read_utf8(root / rel)
        if text is None:
            continue
        lines = text.splitlines()
        first_line = lines[0] if lines else ""
        lang = detect_language(rel, first_line)
        if lang is None:
            continue
        if lang == "python":
            raw_comments = lex_python_comments(text)
        elif lang == "swift":
            raw_comments, _ = scan_swift(text)
        elif lang == "js":
            raw_comments, _ = scan_js(text)
        elif lang == "shell":
            raw_comments = lex_shell_comments(text)
        else:
            continue

        license_indices = compute_license_block_indices(raw_comments)
        rel_posix = rel.as_posix()
        for idx, rc in enumerate(raw_comments):
            if is_exempt_comment(lang, rc, idx in license_indices):
                continue
            errors.append(
                fmt_fail(
                    rel_posix,
                    rc.start_line,
                    f"ordinary comment is forbidden ({snippet_of(rc.text)})",
                    "delete the comment and make the code or type self-explanatory",
                )
            )
    return errors


def check_no_tooltip_in_app(root: Path) -> list[str]:
    errors: list[str] = []
    for rel in walk_tree_files(root, ("Sources/CodingRewindApp",)):
        if rel.suffix != ".swift":
            continue
        text = read_utf8(root / rel)
        if text is None:
            continue
        _, masked = scan_swift(text)
        idx = LineIndex(masked)
        for m in TOOLTIP_RE.finditer(masked):
            errors.append(
                fmt_fail(
                    rel.as_posix(),
                    idx.line_of(m.start()),
                    "native .toolTip assignment is forbidden in CodingRewindApp",
                    "use setAccessibilityLabel(_:) instead of native toolTip",
                )
            )
    return errors


def check_forbidden_app_surface_tokens(root: Path) -> list[str]:
    errors: list[str] = []
    targets: list[Path] = [rel for rel in walk_tree_files(root, ("Sources",)) if rel.suffix == ".swift"]
    bundle_script = Path("scripts/build-app-bundle.sh")
    if (root / bundle_script).is_file():
        targets.append(bundle_script)

    for rel in targets:
        text = read_utf8(root / rel)
        if text is None:
            continue
        rel_posix = rel.as_posix()
        if rel.suffix == ".swift":
            _, masked = scan_swift(text)
            masked_idx = LineIndex(masked)
            for m in MENU_BAR_EXTRA_RE.finditer(masked):
                errors.append(
                    fmt_fail(
                        rel_posix,
                        masked_idx.line_of(m.start()),
                        "forbidden MenuBarExtra usage detected",
                        "use AppKit NSStatusItem + NSMenu instead of MenuBarExtra",
                    )
                )
        else:
            for lineno, line in enumerate(text.splitlines(), start=1):
                if MENU_BAR_EXTRA_RE.search(line):
                    errors.append(
                        fmt_fail(
                            rel_posix,
                            lineno,
                            "forbidden MenuBarExtra reference detected",
                            "use AppKit NSStatusItem + NSMenu instead of MenuBarExtra",
                        )
                    )

        for lineno, line in enumerate(text.splitlines(), start=1):
            if "CFBundleURLSchemes" in line:
                errors.append(
                    fmt_fail(
                        rel_posix,
                        lineno,
                        "forbidden CFBundleURLSchemes detected",
                        "remove custom URL scheme registration and use HTTP /api/memos",
                    )
                )
            if "coding-rewind://" in line:
                errors.append(
                    fmt_fail(
                        rel_posix,
                        lineno,
                        "forbidden coding-rewind:// custom scheme detected",
                        "use HTTP /api/memos instead of coding-rewind://",
                    )
                )
    return errors


def check_no_direct_nsworkspace_open(root: Path) -> list[str]:
    errors: list[str] = []
    allowed_rel = "Sources/CodingRewindApp/SystemURLOpener.swift"
    if not (root / allowed_rel).is_file():
        errors.append(
            fmt_fail(
                allowed_rel,
                1,
                "SystemURLOpener.swift is missing",
                "create Sources/CodingRewindApp/SystemURLOpener.swift with a non-discardable Bool open(_:) wrapper",
            )
        )
    for rel in walk_tree_files(root, ("Sources",)):
        if rel.suffix != ".swift":
            continue
        rel_posix = rel.as_posix()
        if rel_posix == allowed_rel:
            continue
        text = read_utf8(root / rel)
        if text is None:
            continue
        _, masked = scan_swift(text)
        idx = LineIndex(masked)
        for m in NSWORKSPACE_OPEN_RE.finditer(masked):
            errors.append(
                fmt_fail(
                    rel_posix,
                    idx.line_of(m.start()),
                    "direct NSWorkspace.shared.open( call bypasses return check",
                    "call SystemURLOpener.open(_:) and handle its Bool result",
                )
            )
    return errors


def check_no_dom_collection_array_methods(root: Path) -> list[str]:
    errors: list[str] = []
    for rel in walk_tree_files(root, ("extensions",)):
        if rel.suffix not in (".js", ".mjs"):
            continue
        name = rel.name
        if name.startswith("test_") or ".test." in name:
            continue
        text = read_utf8(root / rel)
        if text is None:
            continue
        _, masked = scan_js(text)
        idx = LineIndex(masked)
        for m in DOM_COLLECTION_ARRAY_METHOD_RE.finditer(masked):
            errors.append(
                fmt_fail(
                    rel.as_posix(),
                    idx.line_of(m.start()),
                    f"direct Array.prototype call on DOM collection ({m.group(0).strip()})",
                    "wrap the collection with Array.from(...) before calling Array methods",
                )
            )
    return errors


def _extract_balanced_parens(text: str, open_paren_pos: int) -> tuple[str, int] | None:
    if open_paren_pos >= len(text) or text[open_paren_pos] != "(":
        return None
    depth = 1
    i = open_paren_pos + 1
    while i < len(text) and depth > 0:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    if depth != 0:
        return None
    return text[open_paren_pos + 1 : i - 1], i


def check_unbounded_places_queries(root: Path) -> list[str]:
    errors: list[str] = []
    rel = "Sources/CodingRewindCore/AppCoordinator+Places.swift"
    path = root / rel
    if not path.is_file():
        return [
            fmt_fail(
                rel,
                1,
                "AppCoordinator+Places.swift is missing",
                "restore Sources/CodingRewindCore/AppCoordinator+Places.swift",
            )
        ]
    text = read_utf8(path)
    if text is None:
        return errors
    _, masked = scan_swift(text)
    idx = LineIndex(masked)
    for m in re.finditer(r"\bSnippetQuery\s*\(", masked):
        open_pos = m.end() - 1
        extracted = _extract_balanced_parens(masked, open_pos)
        lineno = idx.line_of(m.start())
        if extracted is None:
            continue
        args, _ = extracted
        if re.search(r"\blimit\s*:", args) or re.search(r"\.bounded\s*\(", args):
            errors.append(
                fmt_fail(
                    rel,
                    lineno,
                    "bounded SnippetQuery in Places library aggregation truncates counts",
                    "use resultLimit: .unbounded for library aggregates",
                )
            )
        elif not re.search(r"\bresultLimit\s*:\s*\.unbounded\b", args):
            errors.append(
                fmt_fail(
                    rel,
                    lineno,
                    "SnippetQuery in Places library aggregation must explicitly pass resultLimit: .unbounded",
                    "use resultLimit: .unbounded for library aggregates",
                )
            )
    return errors


def _extract_balanced_braces(text: str, open_brace_pos: int) -> tuple[str, int] | None:
    if open_brace_pos >= len(text) or text[open_brace_pos] != "{":
        return None
    depth = 1
    i = open_brace_pos + 1
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        return None
    return text[open_brace_pos + 1 : i - 1], i


def check_offline_outbox_flock_sidecar(root: Path) -> list[str]:
    rel = "Sources/CodingRewindCore/PlatformStorage.swift"
    path = root / rel
    if not path.is_file():
        return [
            fmt_fail(
                rel,
                1,
                "PlatformStorage.swift is missing",
                "restore Sources/CodingRewindCore/PlatformStorage.swift",
            )
        ]
    text = read_utf8(path)
    if text is None:
        return []
    idx = LineIndex(text)
    struct_match = re.search(r"\bstruct\s+OfflineOutbox\b[^{]*\{", text)
    if struct_match is None:
        return [
            fmt_fail(
                rel,
                1,
                "OfflineOutbox struct not found",
                "restore OfflineOutbox.withFileLock locking fileURL.appendingPathExtension(\"lock\")",
            )
        ]
    struct_body_res = _extract_balanced_braces(text, struct_match.end() - 1)
    if struct_body_res is None:
        return [
            fmt_fail(
                rel,
                idx.line_of(struct_match.start()),
                "unbalanced braces in OfflineOutbox",
                "fix OfflineOutbox braces and ensure withFileLock locks outbox.jsonl.lock",
            )
        ]
    struct_body, _ = struct_body_res
    struct_body_offset = struct_match.end()
    fn_match = re.search(r"\bfunc\s+withFileLock\b[^{]*\{", struct_body)
    if fn_match is None:
        return [
            fmt_fail(
                rel,
                idx.line_of(struct_match.start()),
                "OfflineOutbox.withFileLock not found",
                "implement OfflineOutbox.withFileLock locking fileURL.appendingPathExtension(\"lock\")",
            )
        ]
    fn_lineno = idx.line_of(struct_body_offset + fn_match.start())
    fn_body_res = _extract_balanced_braces(struct_body, fn_match.end() - 1)
    if fn_body_res is None:
        return [
            fmt_fail(
                rel,
                fn_lineno,
                "unbalanced braces in OfflineOutbox.withFileLock",
                "lock fileURL.appendingPathExtension(\"lock\") instead of fileURL",
            )
        ]
    fn_body, _ = fn_body_res
    lock_decl = re.search(r'\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*fileURL\.appendingPathExtension\(\s*"lock"\s*\)', fn_body)
    if lock_decl is None:
        return [
            fmt_fail(
                rel,
                fn_lineno,
                "OfflineOutbox.withFileLock does not construct a sidecar .lock URL (ADR-001)",
                'lock outbox.jsonl.lock via fileURL.appendingPathExtension("lock") instead of outbox.jsonl',
            )
        ]
    lock_var = lock_decl.group(1)
    opens_sidecar = re.search(rf"\bopen\s*\(\s*{re.escape(lock_var)}\.path\b", fn_body) is not None
    opens_data_file = re.search(r"\bopen\s*\(\s*fileURL\.path\b", fn_body) is not None
    has_flock = re.search(r"\bflock\s*\(\s*fd\s*,\s*LOCK_EX\s*\)", fn_body) is not None
    if not opens_sidecar or opens_data_file or not has_flock:
        return [
            fmt_fail(
                rel,
                fn_lineno,
                "OfflineOutbox.withFileLock must open and flock the sidecar .lock file (ADR-001)",
                'open fileURL.appendingPathExtension("lock").path and flock that descriptor instead of outbox.jsonl',
            )
        ]
    return []


def _line_of_substr(text: str, needle: str) -> int:
    pos = text.find(needle)
    if pos == -1:
        return 1
    return text.count("\n", 0, pos) + 1


def check_wire_contract_parity(root: Path) -> list[str]:
    errors: list[str] = []
    contract_rel = "contracts/wire-contract.json"
    contract_path = root / contract_rel
    if not contract_path.is_file():
        return [
            fmt_fail(
                contract_rel,
                1,
                "missing cross-tier wire contract file",
                "create contracts/wire-contract.json as the single source of truth",
            )
        ]
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [
            fmt_fail(
                contract_rel,
                1,
                f"invalid JSON in wire contract ({exc})",
                "fix JSON syntax in contracts/wire-contract.json",
            )
        ]

    required_keys = (
        "apiPath",
        "forbiddenLegacyApiPath",
        "contextMarker",
        "noteMarker",
        "placeTag",
        "maxPlaceSlugLength",
        "maxPlacesPerClip",
        "memoIdPattern",
        "statusTags",
        "hasContextTag",
        "placeKinds",
    )
    for key in required_keys:
        if key not in contract:
            errors.append(
                fmt_fail(
                    contract_rel,
                    1,
                    f"missing required contract key '{key}'",
                    f"define '{key}' in contracts/wire-contract.json",
                )
            )
    if errors:
        return errors

    api_path: str = contract["apiPath"]
    legacy_path: str = contract["forbiddenLegacyApiPath"]
    context_marker: str = contract["contextMarker"]
    note_marker: str = contract["noteMarker"]
    place_tag: str = contract["placeTag"]
    max_slug_len: int = contract["maxPlaceSlugLength"]
    max_places_per_clip: int = contract["maxPlacesPerClip"]
    memo_id_pattern: str = contract["memoIdPattern"]
    status_tags: list[str] = contract["statusTags"]
    has_ctx_tag: str = contract["hasContextTag"]
    place_kinds: list[str] = contract["placeKinds"]

    tier_files = {
        "swift_client": "Sources/CodingRewindCore/MemosClient.swift",
        "swift_wire": "Sources/CodingRewindCore/MemosWireFormat.swift",
        "swift_places": "Sources/CodingRewindCore/Places.swift",
        "swift_ctx": "Sources/CodingRewindCore/ContextCommentWireFormat.swift",
        "python": "deploy/vps/enricher/enricher.py",
        "js": "extensions/web-clipper/memos_payload.mjs",
    }
    texts: dict[str, str] = {}
    for key, rel in tier_files.items():
        fpath = root / rel
        if not fpath.is_file():
            errors.append(
                fmt_fail(
                    rel,
                    1,
                    "tier file referenced by wire contract check is missing",
                    f"restore {rel} to match contracts/wire-contract.json",
                )
            )
        else:
            texts[key] = fpath.read_text(encoding="utf-8", errors="replace")
    if errors:
        return errors

    for key, rel in tier_files.items():
        if legacy_path in texts[key]:
            errors.append(
                fmt_fail(
                    rel,
                    _line_of_substr(texts[key], legacy_path),
                    f"forbidden legacy API path '{legacy_path}' found",
                    f"replace '{legacy_path}' with '{api_path}' to match contracts/wire-contract.json",
                )
            )

    if f'path: "{api_path}"' not in texts["swift_client"]:
        errors.append(
            fmt_fail(
                tier_files["swift_client"],
                1,
                f"Swift MemosClient does not use contract apiPath '{api_path}'",
                f"update {tier_files['swift_client']} to use '{api_path}' per contracts/wire-contract.json",
            )
        )
    if f"{api_path}?" not in texts["python"] or f"{api_path}/" not in texts["python"]:
        errors.append(
            fmt_fail(
                tier_files["python"],
                1,
                f"Python enricher does not use contract apiPath '{api_path}'",
                f"update {tier_files['python']} to use '{api_path}' per contracts/wire-contract.json",
            )
        )
    if f"{api_path}?" not in texts["js"] or f"{api_path}/" not in texts["js"]:
        errors.append(
            fmt_fail(
                tier_files["js"],
                1,
                f"JS web clipper does not use contract apiPath '{api_path}'",
                f"update {tier_files['js']} to use '{api_path}' per contracts/wire-contract.json",
            )
        )

    swift_ctx_m = re.search(r'public static let contextCommentMarker\s*=\s*"([^"]+)"', texts["swift_wire"])
    if swift_ctx_m is None or swift_ctx_m.group(1) != context_marker:
        found = swift_ctx_m.group(1) if swift_ctx_m else "missing"
        line = _line_of_substr(texts["swift_wire"], "contextCommentMarker")
        errors.append(
            fmt_fail(
                tier_files["swift_wire"],
                line,
                f"wire contract drift for contextMarker (expected '{context_marker}', found '{found}')",
                f"update contextCommentMarker in {tier_files['swift_wire']} to '{context_marker}' per contracts/wire-contract.json",
            )
        )
    if "contextCommentMarker" not in texts["swift_ctx"]:
        errors.append(
            fmt_fail(
                tier_files["swift_ctx"],
                1,
                "ContextCommentWireFormat must reference MemosWireFormat.contextCommentMarker",
                f"use contextCommentMarker in {tier_files['swift_ctx']} per contracts/wire-contract.json",
            )
        )
    py_ctx_m = re.search(r'^CONTEXT_MARKER\s*=\s*"([^"]+)"', texts["python"], flags=re.MULTILINE)
    if py_ctx_m is None or py_ctx_m.group(1) != context_marker:
        found = py_ctx_m.group(1) if py_ctx_m else "missing"
        line = _line_of_substr(texts["python"], "CONTEXT_MARKER")
        errors.append(
            fmt_fail(
                tier_files["python"],
                line,
                f"wire contract drift for contextMarker (expected '{context_marker}', found '{found}')",
                f"update CONTEXT_MARKER in {tier_files['python']} to '{context_marker}' per contracts/wire-contract.json",
            )
        )
    if f'"{context_marker}"' not in texts["js"]:
        errors.append(
            fmt_fail(
                tier_files["js"],
                _line_of_substr(texts["js"], "headerLines"),
                f"wire contract drift for contextMarker (expected '{context_marker}')",
                f"update context marker in {tier_files['js']} to '{context_marker}' per contracts/wire-contract.json",
            )
        )

    swift_note_m = re.search(r'public static let noteCommentMarker\s*=\s*"([^"]+)"', texts["swift_wire"])
    if swift_note_m is None or swift_note_m.group(1) != note_marker:
        found = swift_note_m.group(1) if swift_note_m else "missing"
        line = _line_of_substr(texts["swift_wire"], "noteCommentMarker")
        errors.append(
            fmt_fail(
                tier_files["swift_wire"],
                line,
                f"wire contract drift for noteMarker (expected '{note_marker}', found '{found}')",
                f"update noteCommentMarker in {tier_files['swift_wire']} to '{note_marker}' per contracts/wire-contract.json",
            )
        )

    swift_place_tag_m = re.search(r'public static let placeMarkerTag\s*=\s*"([^"]+)"', texts["swift_places"])
    if swift_place_tag_m is None or swift_place_tag_m.group(1) != place_tag:
        found = swift_place_tag_m.group(1) if swift_place_tag_m else "missing"
        line = _line_of_substr(texts["swift_places"], "placeMarkerTag")
        errors.append(
            fmt_fail(
                tier_files["swift_places"],
                line,
                f"wire contract drift for placeTag (expected '{place_tag}', found '{found}')",
                f"update placeMarkerTag in {tier_files['swift_places']} to '{place_tag}' per contracts/wire-contract.json",
            )
        )
    py_place_tag_m = re.search(r'^PLACE_TAG\s*=\s*"([^"]+)"', texts["python"], flags=re.MULTILINE)
    if py_place_tag_m is None or py_place_tag_m.group(1) != place_tag:
        found = py_place_tag_m.group(1) if py_place_tag_m else "missing"
        line = _line_of_substr(texts["python"], "PLACE_TAG")
        errors.append(
            fmt_fail(
                tier_files["python"],
                line,
                f"wire contract drift for placeTag (expected '{place_tag}', found '{found}')",
                f"update PLACE_TAG in {tier_files['python']} to '{place_tag}' per contracts/wire-contract.json",
            )
        )

    swift_slug_m = re.search(r"public static let maxLength\s*=\s*(\d+)", texts["swift_places"])
    if swift_slug_m is None or int(swift_slug_m.group(1)) != max_slug_len:
        found = swift_slug_m.group(1) if swift_slug_m else "missing"
        line = _line_of_substr(texts["swift_places"], "maxLength")
        errors.append(
            fmt_fail(
                tier_files["swift_places"],
                line,
                f"wire contract drift for maxPlaceSlugLength (expected {max_slug_len}, found {found})",
                f"update PlaceSlug.maxLength in {tier_files['swift_places']} to {max_slug_len} per contracts/wire-contract.json",
            )
        )
    py_slug_m = re.search(r"^MAX_PLACE_SLUG_LENGTH\s*=\s*(\d+)", texts["python"], flags=re.MULTILINE)
    if py_slug_m is None or int(py_slug_m.group(1)) != max_slug_len:
        found = py_slug_m.group(1) if py_slug_m else "missing"
        line = _line_of_substr(texts["python"], "MAX_PLACE_SLUG_LENGTH")
        errors.append(
            fmt_fail(
                tier_files["python"],
                line,
                f"wire contract drift for maxPlaceSlugLength (expected {max_slug_len}, found {found})",
                f"update MAX_PLACE_SLUG_LENGTH in {tier_files['python']} to {max_slug_len} per contracts/wire-contract.json",
            )
        )

    py_max_places_m = re.search(r"^MAX_PLACES_PER_CLIP\s*=\s*(\d+)", texts["python"], flags=re.MULTILINE)
    if py_max_places_m is None or int(py_max_places_m.group(1)) != max_places_per_clip:
        found = py_max_places_m.group(1) if py_max_places_m else "missing"
        line = _line_of_substr(texts["python"], "MAX_PLACES_PER_CLIP")
        errors.append(
            fmt_fail(
                tier_files["python"],
                line,
                f"wire contract drift for maxPlacesPerClip (expected {max_places_per_clip}, found {found})",
                f"update MAX_PLACES_PER_CLIP in {tier_files['python']} to {max_places_per_clip} per contracts/wire-contract.json",
            )
        )

    js_pattern_m = re.search(r"export const CLIP_ID_PATTERN\s*=\s*/([^/]+)/;", texts["js"])
    if js_pattern_m is None or js_pattern_m.group(1) != memo_id_pattern:
        found = js_pattern_m.group(1) if js_pattern_m else "missing"
        line = _line_of_substr(texts["js"], "CLIP_ID_PATTERN")
        errors.append(
            fmt_fail(
                tier_files["js"],
                line,
                f"wire contract drift for memoIdPattern (expected '{memo_id_pattern}', found '{found}')",
                f"update CLIP_ID_PATTERN in {tier_files['js']} to /{memo_id_pattern}/ per contracts/wire-contract.json",
            )
        )
    mid_len_m = re.search(r"\{0,(\d+)\}", memo_id_pattern)
    expected_memo_id_max = int(mid_len_m.group(1)) + 2 if mid_len_m else 36
    swift_id_m = re.search(r"func isValidMemoID\([^)]*\)\s*->\s*Bool\s*\{[^}]*bytes\.count\s*<=\s*(\d+)", texts["swift_wire"])
    if swift_id_m is None or int(swift_id_m.group(1)) != expected_memo_id_max:
        found = swift_id_m.group(1) if swift_id_m else "missing"
        line = _line_of_substr(texts["swift_wire"], "isValidMemoID")
        errors.append(
            fmt_fail(
                tier_files["swift_wire"],
                line,
                f"wire contract drift for memoIdPattern max length (expected {expected_memo_id_max}, found {found})",
                f"update isValidMemoID in {tier_files['swift_wire']} to match contracts/wire-contract.json",
            )
        )

    for tag in status_tags:
        if f'"{tag}"' not in texts["swift_wire"] and f"{tag} " not in texts["swift_wire"]:
            errors.append(
                fmt_fail(
                    tier_files["swift_wire"],
                    1,
                    f"wire contract drift for statusTags (missing '{tag}')",
                    f"ensure {tier_files['swift_wire']} handles '{tag}' per contracts/wire-contract.json",
                )
            )
        if f'"{tag}"' not in texts["python"]:
            errors.append(
                fmt_fail(
                    tier_files["python"],
                    1,
                    f"wire contract drift for statusTags (missing '{tag}')",
                    f"ensure {tier_files['python']} handles '{tag}' per contracts/wire-contract.json",
                )
            )
    if status_tags and status_tags[0] not in texts["js"]:
        errors.append(
            fmt_fail(
                tier_files["js"],
                1,
                f"wire contract drift for statusTags (missing '{status_tags[0]}')",
                f"ensure {tier_files['js']} emits '{status_tags[0]}' per contracts/wire-contract.json",
            )
        )

    for tier_key in ("swift_wire", "python", "js"):
        if has_ctx_tag not in texts[tier_key]:
            errors.append(
                fmt_fail(
                    tier_files[tier_key],
                    1,
                    f"wire contract drift for hasContextTag (missing '{has_ctx_tag}')",
                    f"ensure {tier_files[tier_key]} uses '{has_ctx_tag}' per contracts/wire-contract.json",
                )
            )

    swift_kind_enum = re.search(r"public enum PlaceKind\b[^{]*\{([^}]*)\}", texts["swift_places"])
    swift_kinds = re.findall(r"\bcase\s+([a-z]+)\b", swift_kind_enum.group(1)) if swift_kind_enum else []
    if swift_kinds != place_kinds:
        errors.append(
            fmt_fail(
                tier_files["swift_places"],
                _line_of_substr(texts["swift_places"], "enum PlaceKind"),
                f"wire contract drift for placeKinds (expected {place_kinds}, found {swift_kinds})",
                f"update PlaceKind cases in {tier_files['swift_places']} to match contracts/wire-contract.json",
            )
        )
    py_kinds_m = re.search(r'_PLACE_REF_RE\s*=\s*re\.compile\(r"\(\?:([a-z|]+)\)/', texts["python"])
    py_kinds = py_kinds_m.group(1).split("|") if py_kinds_m else []
    if py_kinds != place_kinds:
        errors.append(
            fmt_fail(
                tier_files["python"],
                _line_of_substr(texts["python"], "_PLACE_REF_RE"),
                f"wire contract drift for placeKinds (expected {place_kinds}, found {py_kinds})",
                f"update _PLACE_REF_RE in {tier_files['python']} to match contracts/wire-contract.json",
            )
        )

    return errors


def run_all_checks(root: Path) -> list[str]:
    violations: list[str] = []
    violations.extend(check_comments_and_ratchet(root))
    violations.extend(check_no_tooltip_in_app(root))
    violations.extend(check_forbidden_app_surface_tokens(root))
    violations.extend(check_no_direct_nsworkspace_open(root))
    violations.extend(check_no_dom_collection_array_methods(root))
    violations.extend(check_unbounded_places_queries(root))
    violations.extend(check_offline_outbox_flock_sidecar(root))
    violations.extend(check_wire_contract_parity(root))
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Structural invariant and wire-contract linter.")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root to lint.",
    )
    args = parser.parse_args(argv)
    root = args.root.expanduser().resolve()
    violations = run_all_checks(root)
    if violations:
        for line in violations:
            print(line, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

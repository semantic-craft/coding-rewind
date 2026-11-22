#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import sys
import threading
from urllib.parse import parse_qs, unquote, urlparse

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[2]
WIRE_CONTRACT_PATH = REPO_ROOT / "contracts" / "wire-contract.json"


def _load_wire_contract() -> dict:
    return json.loads(WIRE_CONTRACT_PATH.read_text(encoding="utf-8"))


WIRE_CONTRACT = _load_wire_contract()
MEMO_ID_RE = re.compile(WIRE_CONTRACT["memoIdPattern"])
API_PATH = WIRE_CONTRACT["apiPath"]
LEGACY_API_PATH = WIRE_CONTRACT["forbiddenLegacyApiPath"]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _memo_row_to_dict(row: sqlite3.Row) -> dict:
    return {
        "name": f"memos/{row['id']}",
        "content": row["content"],
        "visibility": row["visibility"],
        "createTime": row["create_time"],
        "updateTime": row["update_time"],
    }


def _comment_row_to_dict(row: sqlite3.Row) -> dict:
    return {
        "name": f"memos/{row['id']}",
        "content": row["content"],
        "visibility": row["visibility"],
        "createTime": row["create_time"],
        "updateTime": row["update_time"],
    }


class SQLiteMemosStore:
    def __init__(self, db_path: str | Path) -> None:
        self.db_path = Path(db_path).expanduser().resolve()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA foreign_keys=ON")
            self._conn.execute("PRAGMA synchronous=NORMAL")
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS memos (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    content TEXT NOT NULL,
                    visibility TEXT NOT NULL,
                    create_time TEXT NOT NULL,
                    update_time TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS comments (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    memo_id TEXT NOT NULL REFERENCES memos(id) ON DELETE CASCADE,
                    content TEXT NOT NULL,
                    visibility TEXT NOT NULL,
                    create_time TEXT NOT NULL,
                    update_time TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_comments_memo_id ON comments(memo_id, seq);
                """
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def create_memo(
        self,
        memo_id: str | None,
        content: str,
        visibility: str = "PRIVATE",
        create_time: str | None = None,
    ) -> tuple[int, dict]:
        resolved_id = (memo_id or "").strip() or f"rw-{secrets.token_hex(8)}"
        if not MEMO_ID_RE.fullmatch(resolved_id):
            return 400, {"code": 3, "message": f"invalid memoId: {resolved_id}"}
        now_iso = create_time or _utc_now_iso()
        vis = visibility or "PRIVATE"
        with self._lock:
            try:
                self._conn.execute(
                    "INSERT INTO memos (id, content, visibility, create_time, update_time) VALUES (?, ?, ?, ?, ?)",
                    (resolved_id, content, vis, now_iso, now_iso),
                )
                self._conn.commit()
            except sqlite3.IntegrityError:
                return 409, {"code": 6, "message": f"memo already exists: {resolved_id}"}
            row = self._conn.execute("SELECT * FROM memos WHERE id = ?", (resolved_id,)).fetchone()
            return 200, _memo_row_to_dict(row)

    def list_memos(self, page_size: int = 50, offset: int = 0) -> dict:
        clamped_size = max(1, min(page_size, 1000))
        safe_offset = max(0, offset)
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM memos ORDER BY create_time DESC, seq DESC LIMIT ? OFFSET ?",
                (clamped_size + 1, safe_offset),
            ).fetchall()
        has_more = len(rows) > clamped_size
        page_rows = rows[:clamped_size]
        return {
            "memos": [_memo_row_to_dict(r) for r in page_rows],
            "nextPageToken": str(safe_offset + clamped_size) if has_more else "",
        }

    def get_memo(self, memo_id: str) -> dict | None:
        with self._lock:
            row = self._conn.execute("SELECT * FROM memos WHERE id = ?", (memo_id,)).fetchone()
        return _memo_row_to_dict(row) if row is not None else None

    def patch_memo(self, memo_id: str, content: str) -> dict | None:
        now_iso = _utc_now_iso()
        with self._lock:
            cur = self._conn.execute(
                "UPDATE memos SET content = ?, update_time = ? WHERE id = ?",
                (content, now_iso, memo_id),
            )
            self._conn.commit()
            if cur.rowcount == 0:
                return None
            row = self._conn.execute("SELECT * FROM memos WHERE id = ?", (memo_id,)).fetchone()
            return _memo_row_to_dict(row)

    def delete_memo(self, memo_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute("DELETE FROM memos WHERE id = ?", (memo_id,))
            self._conn.commit()
            return cur.rowcount > 0

    def create_comment(
        self,
        memo_id: str,
        comment_id: str | None,
        content: str,
        visibility: str = "PRIVATE",
    ) -> tuple[int, dict]:
        resolved_id = (comment_id or "").strip() or f"rwc-{secrets.token_hex(8)}"
        if not MEMO_ID_RE.fullmatch(resolved_id):
            return 400, {"code": 3, "message": f"invalid commentId: {resolved_id}"}
        now_iso = _utc_now_iso()
        vis = visibility or "PRIVATE"
        with self._lock:
            parent = self._conn.execute("SELECT id FROM memos WHERE id = ?", (memo_id,)).fetchone()
            if parent is None:
                return 404, {"code": 5, "message": f"memo not found: {memo_id}"}
            try:
                self._conn.execute(
                    "INSERT INTO comments (id, memo_id, content, visibility, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?)",
                    (resolved_id, memo_id, content, vis, now_iso, now_iso),
                )
                self._conn.commit()
            except sqlite3.IntegrityError:
                return 409, {"code": 6, "message": f"comment already exists: {resolved_id}"}
            row = self._conn.execute("SELECT * FROM comments WHERE id = ?", (resolved_id,)).fetchone()
            return 200, _comment_row_to_dict(row)

    def list_comments(self, memo_id: str, page_size: int = 50, offset: int = 0) -> tuple[int, dict]:
        clamped_size = max(1, min(page_size, 1000))
        safe_offset = max(0, offset)
        with self._lock:
            parent = self._conn.execute("SELECT id FROM memos WHERE id = ?", (memo_id,)).fetchone()
            if parent is None:
                return 404, {"code": 5, "message": f"memo not found: {memo_id}"}
            rows = self._conn.execute(
                "SELECT * FROM comments WHERE memo_id = ? ORDER BY seq ASC LIMIT ? OFFSET ?",
                (memo_id, clamped_size + 1, safe_offset),
            ).fetchall()
        has_more = len(rows) > clamped_size
        page_rows = rows[:clamped_size]
        return 200, {
            "memos": [_comment_row_to_dict(r) for r in page_rows],
            "nextPageToken": str(safe_offset + clamped_size) if has_more else "",
        }


def _parse_pagination(query: dict[str, list[str]]) -> tuple[int, int] | None:
    raw_size = (query.get("pageSize") or ["50"])[0].strip()
    raw_token = (query.get("pageToken") or ["0"])[0].strip() or "0"
    try:
        page_size = int(raw_size)
        offset = int(raw_token)
    except ValueError:
        return None
    if page_size <= 0 or offset < 0:
        return None
    return page_size, offset


def _make_handler(store: SQLiteMemosStore, token: str):
    expected_auth = f"Bearer {token}"

    class MemosRequestHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send_json(self, status: int, payload: dict) -> None:
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def _read_json_body(self) -> dict | None:
            raw_len = self.headers.get("Content-Length", "0").strip()
            try:
                length = int(raw_len) if raw_len else 0
            except ValueError:
                return None
            if length < 0:
                return None
            raw = self.rfile.read(length) if length > 0 else b""
            if not raw:
                return {}
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return None
            return parsed if isinstance(parsed, dict) else None

        def _is_legacy_route(self, path: str) -> bool:
            normalized = path.rstrip("/") or "/"
            return normalized == LEGACY_API_PATH or normalized.startswith(f"{LEGACY_API_PATH}/")

        def _check_auth(self, path: str) -> bool:
            if not path.startswith("/api/"):
                return True
            if self.headers.get("Authorization") != expected_auth:
                self._send_json(401, {"code": 16, "message": "unauthorized"})
                return False
            return True

        def _guard_common(self, path: str) -> bool:
            if self._is_legacy_route(path):
                self._send_json(410, {"code": 12, "message": "legacy /api/v1/memos removed"})
                return False
            return self._check_auth(path)

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            if path == "/healthz":
                self._send_json(200, {"ok": True})
                return
            if not self._guard_common(path):
                return
            query = parse_qs(parsed.query)
            if path == API_PATH:
                pag = _parse_pagination(query)
                if pag is None:
                    self._send_json(400, {"code": 3, "message": "invalid pagination parameters"})
                    return
                self._send_json(200, store.list_memos(page_size=pag[0], offset=pag[1]))
                return
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "memos"]:
                memo = store.get_memo(unquote(parts[2]))
                if memo is None:
                    self._send_json(404, {"code": 5, "message": "memo not found"})
                else:
                    self._send_json(200, memo)
                return
            if len(parts) == 4 and parts[:2] == ["api", "memos"] and parts[3] == "comments":
                pag = _parse_pagination(query)
                if pag is None:
                    self._send_json(400, {"code": 3, "message": "invalid pagination parameters"})
                    return
                status, payload = store.list_comments(unquote(parts[2]), page_size=pag[0], offset=pag[1])
                self._send_json(status, payload)
                return
            self._send_json(404, {"code": 5, "message": "route not found"})

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            if not self._guard_common(path):
                return
            query = parse_qs(parsed.query)
            body = self._read_json_body()
            if body is None:
                self._send_json(400, {"code": 3, "message": "invalid JSON body"})
                return
            if path == API_PATH:
                memo_id = (query.get("memoId") or [None])[0]
                content = str(body.get("content", ""))
                visibility = str(body.get("visibility", "PRIVATE"))
                create_time = body.get("createTime")
                status, payload = store.create_memo(
                    memo_id=memo_id,
                    content=content,
                    visibility=visibility,
                    create_time=str(create_time) if create_time else None,
                )
                self._send_json(status, payload)
                return
            parts = path.strip("/").split("/")
            if len(parts) == 4 and parts[:2] == ["api", "memos"] and parts[3] == "comments":
                comment_id = (query.get("commentId") or [None])[0]
                content = str(body.get("content", ""))
                visibility = str(body.get("visibility", "PRIVATE"))
                status, payload = store.create_comment(
                    memo_id=unquote(parts[2]),
                    comment_id=comment_id,
                    content=content,
                    visibility=visibility,
                )
                self._send_json(status, payload)
                return
            self._send_json(404, {"code": 5, "message": "route not found"})

        def do_PATCH(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            if not self._guard_common(path):
                return
            query = parse_qs(parsed.query)
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "memos"]:
                mask_values = [
                    item.strip()
                    for raw in query.get("updateMask", [])
                    for item in raw.split(",")
                    if item.strip()
                ]
                if mask_values and "content" not in mask_values:
                    self._send_json(400, {"code": 3, "message": "updateMask must include content"})
                    return
                body = self._read_json_body()
                if body is None or "content" not in body:
                    self._send_json(400, {"code": 3, "message": "content is required"})
                    return
                updated = store.patch_memo(unquote(parts[2]), str(body["content"]))
                if updated is None:
                    self._send_json(404, {"code": 5, "message": "memo not found"})
                else:
                    self._send_json(200, updated)
                return
            self._send_json(404, {"code": 5, "message": "route not found"})

        def do_DELETE(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            if not self._guard_common(path):
                return
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "memos"]:
                deleted = store.delete_memo(unquote(parts[2]))
                if not deleted:
                    self._send_json(404, {"code": 5, "message": "memo not found"})
                else:
                    self._send_json(200, {})
                return
            self._send_json(404, {"code": 5, "message": "route not found"})

        def log_message(self, fmt: str, *args) -> None:
            return

    return MemosRequestHandler


class _ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class SQLiteMemosServer:
    def __init__(
        self,
        db_path: str | Path,
        token: str,
        host: str = "127.0.0.1",
        port: int = 0,
    ) -> None:
        self.db_path = Path(db_path).expanduser().resolve()
        self.token = token
        self.host = host
        self._requested_port = port
        self.store = SQLiteMemosStore(self.db_path)
        self._httpd: _ReusableThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def port(self) -> int:
        if self._httpd is None:
            return self._requested_port
        return int(self._httpd.server_address[1])

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def start(self) -> SQLiteMemosServer:
        if self._httpd is not None:
            return self
        handler = _make_handler(self.store, self.token)
        self._httpd = _ReusableThreadingHTTPServer((self.host, self._requested_port), handler)
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        )
        self._thread.start()
        return self

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            self._thread = None
        self.store.close()

    def __enter__(self) -> SQLiteMemosServer:
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


def _write_ready_file_atomically(path: Path, payload: dict) -> None:
    resolved = path.expanduser().resolve()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = resolved.parent / f".{resolved.name}.{os.getpid()}.pending"
    tmp_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp_path, resolved)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="SQLite-backed Memos 26.11.0 REST contract server.")
    parser.add_argument("--db", required=True, type=Path, help="Path to SQLite database file.")
    parser.add_argument("--port", type=int, default=0, help="TCP port to bind (0 selects an ephemeral port).")
    parser.add_argument("--host", default="127.0.0.1", help="Loopback host to bind.")
    parser.add_argument("--token", required=True, help="Required Bearer token for /api/* requests.")
    parser.add_argument("--ready-file", type=Path, default=None, help="Atomic JSON ready file path.")
    args = parser.parse_args(argv)

    stop_event = threading.Event()

    def _handle_signal(signum: int, frame) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    server = SQLiteMemosServer(
        db_path=args.db,
        token=args.token,
        host=args.host,
        port=args.port,
    )
    server.start()
    try:
        ready_payload = {
            "url": server.url,
            "pid": os.getpid(),
            "db": str(server.db_path),
        }
        if args.ready_file is not None:
            _write_ready_file_atomically(args.ready_file, ready_payload)
        else:
            print(json.dumps(ready_payload), flush=True)
        while not stop_event.is_set():
            stop_event.wait(timeout=0.2)
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

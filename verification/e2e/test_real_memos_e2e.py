#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "verification" / "e2e"))
sys.path.insert(0, str(REPO_ROOT / "deploy" / "vps" / "enricher"))

import enricher  # noqa: E402
from sqlite_memos_server import SQLiteMemosServer  # noqa: E402


def _http_request(
    method: str,
    url: str,
    token: str | None = None,
    payload: dict | None = None,
    timeout: float = 20.0,
) -> tuple[int, dict | str]:
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as exc:
        try:
            raw = exc.read().decode("utf-8", errors="replace")
            code = exc.code
        finally:
            exc.close()
        try:
            return code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return code, raw


def _extract_memo_id(memo_payload: dict) -> str:
    name = str(memo_payload.get("name", ""))
    if "/" not in name:
        raise AssertionError(f"Unexpected memo resource name: {name!r}")
    return name.split("/", 1)[1]


class _FakeOpenAIServer:
    def __init__(self, expected_key: str, response_obj: dict) -> None:
        self.expected_key = expected_key
        self.response_obj = response_obj
        self.calls: list[dict] = []
        self._lock = threading.Lock()
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def url(self) -> str:
        assert self._httpd is not None
        return f"http://127.0.0.1:{self._httpd.server_address[1]}/v1"

    def start(self) -> _FakeOpenAIServer:
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path != "/v1/chat/completions":
                    self._reply(404, {"error": "not found"})
                    return
                if self.headers.get("Authorization") != f"Bearer {parent.expected_key}":
                    self._reply(401, {"error": "unauthorized"})
                    return
                length = int(self.headers.get("Content-Length", "0") or 0)
                raw = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                body = json.loads(raw)
                with parent._lock:
                    parent.calls.append(body)
                    content_str = json.dumps(parent.response_obj, ensure_ascii=False)
                self._reply(200, {"choices": [{"message": {"content": content_str}}]})

            def _reply(self, code: int, body: dict) -> None:
                raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, fmt: str, *args) -> None:
                return

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            kwargs={"poll_interval": 0.02},
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


class RealMemosE2ETest(unittest.TestCase):
    base_url: str
    token: str
    is_local_sqlite: bool
    _local_server: SQLiteMemosServer | None = None
    _local_dir: Path | None = None

    @classmethod
    def setUpClass(cls) -> None:
        env_url = os.environ.get("MEMOS_E2E_URL", "").strip().rstrip("/")
        env_token = os.environ.get("MEMOS_E2E_TOKEN", "").strip()
        if env_url:
            if not env_token:
                raise RuntimeError("MEMOS_E2E_TOKEN is required when MEMOS_E2E_URL is set")
            cls.base_url = env_url
            cls.token = env_token
            cls.is_local_sqlite = False
            cls._local_server = None
            cls._local_dir = None
        else:
            run_id = f"{os.getpid()}-{secrets.token_hex(4)}"
            cls._local_dir = REPO_ROOT / ".build" / f"e2e-sqlite-{run_id}"
            cls._local_dir.mkdir(parents=True, exist_ok=True)
            db_path = cls._local_dir / "memos.sqlite3"
            cls.token = f"memos-e2e-local-{secrets.token_hex(8)}"
            cls._local_server = SQLiteMemosServer(db_path=db_path, token=cls.token).start()
            cls.base_url = cls._local_server.url
            cls.is_local_sqlite = True

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._local_server is not None:
            cls._local_server.stop()
            cls._local_server = None
        if cls._local_dir is not None and cls._local_dir.exists():
            shutil.rmtree(cls._local_dir, ignore_errors=True)
            cls._local_dir = None

    def _delete_memo_best_effort(self, memo_id: str) -> None:
        encoded = urllib.parse.quote(memo_id, safe="")
        _http_request("DELETE", f"{self.base_url}/api/memos/{encoded}", token=self.token)

    def _list_all_memos(self, page_size: int = 50) -> list[dict]:
        all_memos: list[dict] = []
        page_token = ""
        seen_tokens: set[str] = set()
        while True:
            params = {"pageSize": str(page_size)}
            if page_token:
                params["pageToken"] = page_token
            status, body = _http_request(
                "GET",
                f"{self.base_url}/api/memos?{urllib.parse.urlencode(params)}",
                token=self.token,
            )
            self.assertEqual(status, 200, f"GET /api/memos failed: {status} {body}")
            self.assertIsInstance(body, dict)
            all_memos.extend(body.get("memos") or [])
            next_token = str(body.get("nextPageToken") or "")
            if not next_token:
                break
            self.assertNotIn(next_token, seen_tokens)
            seen_tokens.add(next_token)
            page_token = next_token
        return all_memos

    def test_a_legacy_v1_memos_route_rejected(self) -> None:
        status, body = _http_request("GET", f"{self.base_url}/api/v1/memos", token=self.token)
        print(
            f"[e2e] legacy GET /api/v1/memos status={status} mode={'local-sqlite' if self.is_local_sqlite else 'external-memos'}",
            flush=True,
        )
        self.assertNotEqual(status, 200)
        self.assertIn(status, (404, 410), f"expected 404 or 410 for /api/v1/memos, got {status}: {body}")
        if self.is_local_sqlite:
            self.assertEqual(status, 410)
            health_status, health_body = _http_request("GET", f"{self.base_url}/healthz")
            self.assertEqual(health_status, 200)
            self.assertEqual(health_body, {"ok": True})
            unauth_get_status, _ = _http_request("GET", f"{self.base_url}/api/memos?pageSize=1")
            self.assertEqual(unauth_get_status, 401)
        unauth_post_status, _ = _http_request(
            "POST",
            f"{self.base_url}/api/memos",
            payload={"content": "unauth probe", "visibility": "PRIVATE"},
        )
        self.assertEqual(unauth_post_status, 401)

    def test_b_web_clipper_payload_upload_and_idempotent_409_retry(self) -> None:
        clip_id = f"rw-clip-{secrets.token_hex(6)}"
        verbatim_body = (
            "Keep literal #rewind/pending untouched inside verbatim body.\n\n"
            "```python\n"
            "def compute(x):\n"
            "    y = x + 1\n"
            "\n"
            "    return y * 2\n"
            "```"
        )
        clip = {
            "clipId": clip_id,
            "sourcePlatform": "chatgpt",
            "sessionTitle": "Web Clipper E2E Session",
            "sessionId": "sess-clipper-e2e",
            "sourceUrl": "https://chatgpt.com/c/e2e-verify",
            "prompt": "Verify 409 idempotent clip retry",
            "recentTurns": "User: test retry\nAssistant: idempotent",
            "selectedMarkdown": verbatim_body,
        }
        payload_module = (REPO_ROOT / "extensions" / "web-clipper" / "memos_payload.mjs").resolve()
        node_script = """
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PAYLOAD_MODULE).href);
const clip = JSON.parse(process.env.CLIP_JSON);
let outbox = [];
const storage = {
  async getOutbox() { return outbox.slice(); },
  async setOutbox(items) { outbox = items.slice(); }
};
const first = await mod.saveClipWithOutbox({
  clip,
  baseUrl: process.env.MEMOS_URL,
  token: process.env.MEMOS_TOKEN,
  storage,
  locale: "en"
});
const second = await mod.saveClipWithOutbox({
  clip,
  baseUrl: process.env.MEMOS_URL,
  token: process.env.MEMOS_TOKEN,
  storage,
  locale: "en"
});
console.log(JSON.stringify({ first, second, outboxLength: outbox.length }));
"""
        env = dict(os.environ)
        env["PAYLOAD_MODULE"] = str(payload_module)
        env["CLIP_JSON"] = json.dumps(clip)
        env["MEMOS_URL"] = self.base_url
        env["MEMOS_TOKEN"] = self.token
        proc = subprocess.run(
            ["node", "--input-type=module", "-e", node_script],
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )
        self.assertEqual(proc.returncode, 0, f"node failed: stdout={proc.stdout} stderr={proc.stderr}")
        result = json.loads(proc.stdout.strip())
        first = result["first"]
        second = result["second"]
        self.assertEqual(first["status"], "saved", first)
        self.assertEqual(second["status"], "saved", second)
        self.assertFalse(first["queued"])
        self.assertFalse(second["queued"])
        self.assertEqual(result["outboxLength"], 0)
        server_id = first["serverId"]
        self.assertTrue(server_id)
        self.assertEqual(second["serverId"], server_id)
        self.addCleanup(self._delete_memo_best_effort, server_id)

        encoded = urllib.parse.quote(server_id, safe="")
        memo_status, memo_body = _http_request("GET", f"{self.base_url}/api/memos/{encoded}", token=self.token)
        self.assertEqual(memo_status, 200, memo_body)
        self.assertIsInstance(memo_body, dict)
        self.assertIn("#rewind/pending #rewind/has-ctx #source/chatgpt", memo_body["content"])
        self.assertTrue(memo_body["content"].endswith(verbatim_body))

        cmt_status, cmt_body = _http_request("GET", f"{self.base_url}/api/memos/{encoded}/comments", token=self.token)
        self.assertEqual(cmt_status, 200, cmt_body)
        self.assertIsInstance(cmt_body, dict)
        ctx = enricher.extract_context_comment(cmt_body)
        self.assertIsNotNone(ctx)
        self.assertIn("<!-- rewind-context-v1 -->", ctx)
        self.assertIn("Verify 409 idempotent clip retry", ctx)

        all_memos = self._list_all_memos(page_size=50)
        matching = [m for m in all_memos if m.get("name") == f"memos/{server_id}"]
        self.assertEqual(len(matching), 1)

    def test_c_multipage_pagination_enricher_wait_window_places_and_verbatim(self) -> None:
        run_tag = secrets.token_hex(4)
        verbatim_body = (
            "Literal #rewind/pending inside page-2 excerpt must never be mutated.\n\n"
            "```swift\n"
            "func keepBlankLine() -> Int {\n"
            "    let a = 40\n"
            "\n"
            "    return a + 2\n"
            "}\n"
            "```"
        )
        target_client_id = f"rw-p2-{run_tag}"
        target_content = (
            "#rewind/pending #rewind/has-ctx #source/chatgpt\n\n"
            "> **Source:** [E2E Pagination Check](https://example.com/e2e) · 2026-11-22T20:00:00Z\n\n"
            f"{verbatim_body}"
        )
        st, target_memo = _http_request(
            "POST",
            f"{self.base_url}/api/memos?memoId={urllib.parse.quote(target_client_id)}",
            token=self.token,
            payload={"content": target_content, "visibility": "PRIVATE"},
        )
        self.assertEqual(st, 200, target_memo)
        self.assertIsInstance(target_memo, dict)
        target_id = _extract_memo_id(target_memo)
        self.addCleanup(self._delete_memo_best_effort, target_id)

        if not self.is_local_sqlite:
            time.sleep(1.05)

        for idx in range(53):
            filler_id = f"rw-fill-{run_tag}-{idx:02d}"
            fst, fbody = _http_request(
                "POST",
                f"{self.base_url}/api/memos?memoId={urllib.parse.quote(filler_id)}",
                token=self.token,
                payload={
                    "content": f"#rewind/ready #source/e2e\n\nFiller memo {idx} for {run_tag}",
                    "visibility": "PRIVATE",
                },
            )
            self.assertEqual(fst, 200, fbody)
            self.addCleanup(self._delete_memo_best_effort, _extract_memo_id(fbody))

        place_client_id = f"rw-place-{run_tag}"
        place_content = (
            "#rewind/place #project/e2e-verify\n\n"
            "> **Title:** E2E Verify Project\n"
            "> **Aliases:** e2e-verify, verify-proj\n"
            "> **Status:** active"
        )
        pst, pbody = _http_request(
            "POST",
            f"{self.base_url}/api/memos?memoId={urllib.parse.quote(place_client_id)}",
            token=self.token,
            payload={"content": place_content, "visibility": "PRIVATE"},
        )
        self.assertEqual(pst, 200, pbody)
        self.addCleanup(self._delete_memo_best_effort, _extract_memo_id(pbody))

        p1_status, p1_body = _http_request("GET", f"{self.base_url}/api/memos?pageSize=50", token=self.token)
        self.assertEqual(p1_status, 200, p1_body)
        self.assertTrue(p1_body.get("nextPageToken"), "expected >1 page for 55 seeded memos")
        p1_names = {m.get("name") for m in p1_body.get("memos") or []}
        self.assertNotIn(f"memos/{target_id}", p1_names)

        ai_key = f"fake-ai-{secrets.token_hex(6)}"
        ai_server = _FakeOpenAIServer(
            expected_key=ai_key,
            response_obj={
                "title": "Page-2 Verbatim Preservation",
                "session_topic": "Real Memos E2E Verification",
                "context_summary": "Enriched across pagination with closed-vocabulary place filtering.",
                "keywords": ["pagination", "verbatim", "places"],
                "places": ["project/e2e-verify", "project/invented-hallucination"],
            },
        ).start()
        self.addCleanup(ai_server.stop)

        created_ts = enricher.parse_iso_utc(target_memo.get("createTime")) or time.time()
        fake_now = [created_ts + 5.0]
        svc = enricher.EnricherService(
            memos_url=self.base_url,
            memos_token=self.token,
            ai_base_url=ai_server.url,
            ai_api_key=ai_key,
            ai_model="deepseek-flash",
            ctx_wait_seconds=15.0,
            clock=lambda: fake_now[0],
            summary_language="en",
        )

        deferred_outcome = svc.process_memo(target_memo)
        self.assertEqual(deferred_outcome, "deferred")
        self.assertEqual(len(ai_server.calls), 0)

        encoded_target = urllib.parse.quote(target_id, safe="")
        ctx_comment_id = f"{target_client_id}-ctx"
        ctx_text = "<!-- rewind-context-v1 -->\nSession Title: Real Memos E2E\nPrompt: Keep verbatim bytes intact"
        cst, cbody = _http_request(
            "POST",
            f"{self.base_url}/api/memos/{encoded_target}/comments?commentId={urllib.parse.quote(ctx_comment_id)}",
            token=self.token,
            payload={"content": ctx_text, "visibility": "PRIVATE"},
        )
        self.assertEqual(cst, 200, cbody)

        enriched_count = svc.reconcile_once()
        self.assertGreaterEqual(enriched_count, 1)
        self.assertEqual(len(ai_server.calls), 1)

        user_prompt = json.loads(ai_server.calls[0]["messages"][1]["content"])
        vocab_places = [entry["place"] for entry in user_prompt.get("place_vocabulary", [])]
        self.assertIn("project/e2e-verify", vocab_places)
        self.assertIn("Keep verbatim bytes intact", user_prompt.get("captured_chat_context", ""))

        gst, updated_memo = _http_request("GET", f"{self.base_url}/api/memos/{encoded_target}", token=self.token)
        self.assertEqual(gst, 200, updated_memo)
        updated_content = updated_memo["content"]
        first_line = updated_content.splitlines()[0]
        self.assertIn("#rewind/ready", first_line)
        self.assertIn("#project/e2e-verify", first_line)
        self.assertNotIn("#rewind/pending", first_line)
        self.assertNotIn("#rewind/has-ctx", first_line)
        self.assertNotIn("project/invented-hallucination", updated_content)
        self.assertTrue(
            updated_content.endswith("\n\n" + verbatim_body),
            f"verbatim body altered:\n{updated_content!r}",
        )

    def test_d_note_comment_isolated_from_context_comment(self) -> None:
        run_tag = secrets.token_hex(4)
        memo_client_id = f"rw-iso-{run_tag}"
        st, memo = _http_request(
            "POST",
            f"{self.base_url}/api/memos?memoId={urllib.parse.quote(memo_client_id)}",
            token=self.token,
            payload={
                "content": "#rewind/ready #source/e2e\n\nBody for note/context isolation test",
                "visibility": "PRIVATE",
            },
        )
        self.assertEqual(st, 200, memo)
        memo_id = _extract_memo_id(memo)
        self.addCleanup(self._delete_memo_best_effort, memo_id)

        encoded = urllib.parse.quote(memo_id, safe="")
        note_id = f"rw-note-{run_tag}"
        nst, nbody = _http_request(
            "POST",
            f"{self.base_url}/api/memos/{encoded}/comments?commentId={urllib.parse.quote(note_id)}",
            token=self.token,
            payload={
                "content": "<!-- rewind-note-v1 -->\nAuthor: tester\n\nFollow-up user note must stay isolated.",
                "visibility": "PRIVATE",
            },
        )
        self.assertEqual(nst, 200, nbody)

        ctx_id = f"rw-ctx-{run_tag}"
        cst, cbody = _http_request(
            "POST",
            f"{self.base_url}/api/memos/{encoded}/comments?commentId={urllib.parse.quote(ctx_id)}",
            token=self.token,
            payload={
                "content": "<!-- rewind-context-v1 -->\nPrompt: Actual conversation context",
                "visibility": "PRIVATE",
            },
        )
        self.assertEqual(cst, 200, cbody)

        lst, comments_payload = _http_request("GET", f"{self.base_url}/api/memos/{encoded}/comments", token=self.token)
        self.assertEqual(lst, 200, comments_payload)
        extracted = enricher.extract_context_comment(comments_payload)
        self.assertIsNotNone(extracted)
        self.assertIn("<!-- rewind-context-v1 -->", extracted)
        self.assertIn("Actual conversation context", extracted)
        self.assertNotIn("<!-- rewind-note-v1 -->", extracted)
        self.assertNotIn("Follow-up user note must stay isolated.", extracted)

    def test_e_sqlite_persistence_across_server_restart(self) -> None:
        run_id = f"restart-{os.getpid()}-{secrets.token_hex(4)}"
        work_dir = REPO_ROOT / ".build" / f"e2e-sqlite-{run_id}"
        work_dir.mkdir(parents=True, exist_ok=True)
        self.addCleanup(shutil.rmtree, work_dir, True)
        db_path = work_dir / "persist.sqlite3"
        token = f"memos-persist-{secrets.token_hex(6)}"

        srv1 = SQLiteMemosServer(db_path=db_path, token=token).start()
        try:
            st, created = _http_request(
                "POST",
                f"{srv1.url}/api/memos?memoId=rw-persist-1",
                token=token,
                payload={"content": "#rewind/ready\n\nPersistent body across restart", "visibility": "PRIVATE"},
            )
            self.assertEqual(st, 200, created)
            cst, cbody = _http_request(
                "POST",
                f"{srv1.url}/api/memos/rw-persist-1/comments?commentId=rw-persist-1-ctx",
                token=token,
                payload={"content": "<!-- rewind-context-v1 -->\nPrompt: Survives restart", "visibility": "PRIVATE"},
            )
            self.assertEqual(cst, 200, cbody)
        finally:
            srv1.stop()

        self.assertTrue(db_path.is_file())
        self.assertGreater(db_path.stat().st_size, 0)

        srv2 = SQLiteMemosServer(db_path=db_path, token=token).start()
        try:
            gst, memo = _http_request("GET", f"{srv2.url}/api/memos/rw-persist-1", token=token)
            self.assertEqual(gst, 200, memo)
            self.assertEqual(memo["name"], "memos/rw-persist-1")
            self.assertIn("Persistent body across restart", memo["content"])
            lst, comments = _http_request("GET", f"{srv2.url}/api/memos/rw-persist-1/comments", token=token)
            self.assertEqual(lst, 200, comments)
            self.assertEqual(len(comments.get("memos") or []), 1)
            self.assertIn("Survives restart", comments["memos"][0]["content"])
        finally:
            srv2.stop()


if __name__ == "__main__":
    unittest.main()

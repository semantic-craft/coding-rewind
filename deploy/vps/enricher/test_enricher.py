# SPDX-License-Identifier: MIT
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse
import base64
import hashlib
import hmac
import json
import os
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import enricher  # noqa: E402


def _sign_standard_webhook(key_bytes: bytes, msg_id: str, ts: str, body: bytes) -> str:
    payload = f"{msg_id}.{ts}.".encode("utf-8") + body
    digest = hmac.new(key_bytes, payload, hashlib.sha256).digest()
    return "v1," + base64.b64encode(digest).decode("ascii")


class MockBackendState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.memos: dict[str, dict] = {}
        self.comments: dict[str, list[dict]] = {}
        self.ai_calls: list[dict] = []
        self.patch_calls: list[tuple[str, str]] = []
        self.ai_response: dict = {
            "title": "Swift 并发锁消除",
            "session_topic": "重构本地热缓存并发读写策略",
            "context_summary": "讨论如何用单线程事件循环替代显式互斥锁，避免剪贴板捕获竞态。",
            "keywords": ["Swift", "Concurrency", "Actor"],
        }
        self.ai_raw_content: str | None = None


def _start_mock_upstream(state: MockBackendState, expected_memos_token: str = "memos-tok", expected_ai_key: str = "ai-tok"):
    class UpstreamHandler(BaseHTTPRequestHandler):
        def _send(self, code: int, payload: dict) -> None:
            raw = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length", "0") or 0)
            return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if self.headers.get("Authorization") != f"Bearer {expected_memos_token}":
                return self._send(401, {"error": "bad memos token"})
            with state.lock:
                if parsed.path == "/api/memos":
                    query = parse_qs(parsed.query)
                    memos = list(state.memos.values())
                    page_size = int(query.get("pageSize", [str(len(memos) or 1)])[0])
                    offset = int(query.get("pageToken", ["0"])[0])
                    end = offset + page_size
                    return self._send(200, {
                        "memos": memos[offset:end],
                        "nextPageToken": str(end) if end < len(memos) else "",
                    })
                parts = parsed.path.strip("/").split("/")
                if len(parts) == 4 and parts[:2] == ["api", "memos"] and parts[3] == "comments":
                    memo_id = parts[2]
                    return self._send(200, {"memos": list(state.comments.get(memo_id, []))})
            self._send(404, {"error": "not found"})

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/v1/chat/completions":
                if self.headers.get("Authorization") != f"Bearer {expected_ai_key}":
                    return self._send(401, {"error": "bad ai token"})
                body = self._read_json()
                with state.lock:
                    state.ai_calls.append(body)
                    content_str = (
                        state.ai_raw_content
                        if state.ai_raw_content is not None
                        else json.dumps(state.ai_response, ensure_ascii=False)
                    )
                return self._send(200, {"choices": [{"message": {"content": content_str}}]})
            self._send(404, {"error": "not found"})

        def do_PATCH(self) -> None:
            parsed = urlparse(self.path)
            if self.headers.get("Authorization") != f"Bearer {expected_memos_token}":
                return self._send(401, {"error": "bad memos token"})
            qs = parse_qs(parsed.query)
            parts = parsed.path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "memos"] and qs.get("updateMask") == ["content"]:
                memo_id = parts[2]
                body = self._read_json()
                with state.lock:
                    if memo_id not in state.memos:
                        return self._send(404, {"error": "missing memo"})
                    state.memos[memo_id]["content"] = body["content"]
                    state.patch_calls.append((memo_id, body["content"]))
                    return self._send(200, state.memos[memo_id])
            self._send(400, {"error": "bad patch"})

        def log_message(self, fmt: str, *args) -> None:
            return

    srv = ThreadingHTTPServer(("localhost", 0), UpstreamHandler)
    threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
    return srv, f"http://localhost:{srv.server_address[1]}"


class EnricherUnitTests(unittest.TestCase):
    def test_reconcile_enriches_pending_memo_beyond_first_page(self) -> None:
        state = MockBackendState()
        for index in range(50):
            state.memos[f"recent-{index}"] = {
                "name": f"memos/recent-{index}",
                "createTime": "2026-11-12T03:00:00Z",
                "content": "#rewind/ready #source/web\n\nAlready enriched.",
            }
        snippet = "An older pending clip must still be enriched."
        state.memos["older-pending"] = {
            "name": "memos/older-pending",
            "createTime": "2026-11-11T03:00:00Z",
            "content": "#rewind/pending #source/web\n\n" + snippet,
        }
        srv, base_url = _start_mock_upstream(state)
        try:
            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="fixture-model",
            )
            self.assertEqual(svc.reconcile_once(), 1)
            self.assertTrue(state.memos["older-pending"]["content"].startswith("#rewind/ready "))
            self.assertTrue(state.memos["older-pending"]["content"].endswith(snippet))
            self.assertEqual(len(state.ai_calls), 1)
            self.assertEqual(svc.reconcile_once(), 0)
            self.assertEqual(len(state.ai_calls), 1)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_reconcile_enumerates_pages_before_processing_and_encodes_token(self) -> None:
        token = "next=50&cursor= +/#?"
        pending = {"name": "memos/pending", "content": "#rewind/pending #source/web\n\nClip"}
        older = {"name": "memos/older", "content": "#rewind/pending #source/web\n\nOlder clip"}
        events = []

        def request(method, url, auth):
            self.assertEqual(method, "GET")
            query = parse_qs(urlparse(url).query)
            events.append("page")
            self.assertEqual(query["pageSize"], ["50"])
            if len(events) == 1:
                self.assertNotIn("pageToken", query)
                return {"memos": [pending], "nextPageToken": token}
            self.assertEqual(query["pageToken"], [token])
            return {"memos": [pending, older]}

        def process(memo):
            events.append(memo["name"])
            return "enriched"

        svc = enricher.EnricherService("http://memos.invalid", "memos-tok", "http://ai.invalid", "ai-tok", "fixture")
        with patch.object(enricher, "_json_req", side_effect=request), patch.object(svc, "process_memo", side_effect=process):
            self.assertEqual(svc.reconcile_once(), 2)
        self.assertEqual(events, ["page", "page", "memos/pending", "memos/older"])

    def test_standard_webhooks_hmac_verification(self) -> None:
        raw_key = b"super-secret-signing-bytes-32len"
        prefixed_secret = "whsec" + "_" + base64.b64encode(raw_key).decode("ascii")
        body = b'{"activityType":"memos.memo.created","memo":{"name":"memos/clip-1"}}'
        msg_id = "msg_2abc987"
        now = 1_762_830_000
        ts = str(now)

        valid_sig = _sign_standard_webhook(raw_key, msg_id, ts, body)
        headers = {"webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": f"v1,invalid {valid_sig}"}
        self.assertTrue(enricher.verify_webhook_signature(prefixed_secret, headers, body, now=now))

        self.assertFalse(
            enricher.verify_webhook_signature(prefixed_secret, headers, body + b" ", now=now),
            "tampered payload must fail signature verification",
        )
        bad_headers = {"webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": "v1,dGFtcGVyZWQ="}
        self.assertFalse(
            enricher.verify_webhook_signature(prefixed_secret, bad_headers, body, now=now),
            "wrong signature must fail verification",
        )

        self.assertFalse(
            enricher.verify_webhook_signature(prefixed_secret, headers, body, now=now + 600),
            "stale timestamp outside tolerance window must fail",
        )

        raw_secret = "plain-hmac-secret-value"
        raw_sig = _sign_standard_webhook(raw_secret.encode("utf-8"), msg_id, ts, body)
        raw_headers = {"Webhook-Id": msg_id, "Webhook-Timestamp": ts, "Webhook-Signature": raw_sig}
        self.assertTrue(
            enricher.verify_webhook_signature(raw_secret, raw_headers, body, now=now),
            "raw non-prefixed secret must verify per Standard Webhooks fallback",
        )

        for empty_secret in ("", "   ", "\t\n", "whsec_"):
            self.assertFalse(
                enricher.verify_webhook_signature(empty_secret, headers, body, now=now),
                f"empty secret material {empty_secret!r} must fail closed",
            )
            self.assertFalse(enricher.verify_webhook_signature(empty_secret, {}, body, now=now))

    def test_verbatim_snippet_preservation(self) -> None:
        verbatim = (
            "Consider the inline formula $E = mc^2$ and display block:\n"
            "$$\n\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}\n$$\n\n"
            "> Nested quote inside user selection that must NOT be stripped\n\n"
            "```python\n"
            "def f(x: int) -> str:\n"
            "    # preserve exact spacing & links [docs](https://example.com/a(b)c)\n"
            "    return f'{x:#06x}'\n"
            "```\n"
        )
        raw_memo = (
            "#rewind/pending #rewind/has-ctx #source/claude\n\n"
            "> **Source:** [Math & Code Review](https://claude.ai/chat/abc-123) · 2026-11-11T03:11:04Z\n\n"
            + verbatim
        )
        parsed = enricher.parse_raw_memo(raw_memo)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertTrue(parsed["has_ctx"])
        self.assertEqual(parsed["ready_tag_line"], "#rewind/ready #source/claude")
        self.assertEqual(parsed["verbatim_body"], verbatim)

        enriched = enricher.build_enriched_content(
            parsed,
            {
                "title": "高斯积分与格式化函数",
                "session_topic": "Claude 数学推导与 Python 十六进制格式化",
                "context_summary": "核对积分常数并保留精确宽度格式化实现。",
                "keywords": ["LaTeX", "Python", "Formatting"],
            },
        )
        expected_prefix = (
            "#rewind/ready #source/claude\n\n"
            "> **Title:** 高斯积分与格式化函数\n"
            "> **Session:** Claude 数学推导与 Python 十六进制格式化\n"
            "> **Context:** 核对积分常数并保留精确宽度格式化实现。\n"
            "> **Keywords:** LaTeX, Python, Formatting\n"
            "> **Source:** [Math & Code Review](https://claude.ai/chat/abc-123) · 2026-11-11T03:11:04Z\n\n"
        )
        self.assertTrue(enriched.startswith(expected_prefix))
        self.assertEqual(enriched[len(expected_prefix) :], verbatim)
        self.assertNotIn("#rewind/pending", enriched)
        self.assertNotIn("#rewind/has-ctx", enriched)

    def test_crlf_headers_preserve_verbatim_body_without_duplicating_source(self) -> None:
        verbatim = "\r\n  first line with CRLF\r\n\r\nsecond line\r\n"
        raw_memo = (
            "#rewind/pending #rewind/has-ctx #source/web\r\n\r\n"
            "> **Source:** [CRLF Clip](https://example.com/crlf) · 2026-11-14T10:00:00Z\r\n\r\n"
            + verbatim
        )
        parsed = enricher.parse_raw_memo(raw_memo)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertTrue(parsed["has_ctx"])
        self.assertEqual(parsed["ready_tag_line"], "#rewind/ready #source/web")
        self.assertEqual(
            parsed["source_line"],
            "> **Source:** [CRLF Clip](https://example.com/crlf) · 2026-11-14T10:00:00Z",
        )
        self.assertEqual(parsed["verbatim_body"], verbatim)

        enriched = enricher.build_enriched_content(
            parsed,
            {
                "title": "CRLF 边界保留",
                "session_topic": "换行兼容验证",
                "context_summary": "确保 CRLF 头部解析不污染原始正文。",
                "keywords": ["CRLF", "Parser"],
            },
        )
        self.assertEqual(enriched.count("> **Source:**"), 1)
        self.assertTrue(enriched.endswith("\n\n" + verbatim))

    def test_process_memo_extracts_fenced_json_with_wrapper_text(self) -> None:
        state = MockBackendState()
        state.ai_raw_content = (
            "以下是整理结果：\n```JSON\n"
            + json.dumps(state.ai_response, ensure_ascii=False)
            + "\n```\n以上。"
        )
        srv, base_url = _start_mock_upstream(state)
        try:
            verbatim = "let value = 7"
            state.memos["rw-fenced"] = {
                "name": "memos/rw-fenced",
                "createTime": "2026-11-14T10:00:00Z",
                "content": (
                    "#rewind/pending #source/macos\n\n"
                    "> **Source:** [Antigravity](conversation://fenced) · 2026-11-14T10:00:00Z\n\n"
                    + verbatim
                ),
            }
            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
            )
            self.assertEqual(svc.process_memo(state.memos["rw-fenced"]), "enriched")
            patched = state.memos["rw-fenced"]["content"]
            self.assertTrue(patched.startswith("#rewind/ready #source/macos\n\n> **Title:** Swift 并发锁消除\n"))
            self.assertTrue(patched.endswith("\n\n" + verbatim))

            state.ai_raw_content = (
                "Here is the structured summary:\n"
                + json.dumps(state.ai_response, ensure_ascii=False)
                + "\nDone."
            )
            leading_blank_verbatim = "\nleading blank preserved\nsecond line"
            state.memos["rw-prose"] = {
                "name": "memos/rw-prose",
                "createTime": "2026-11-14T10:01:00Z",
                "content": (
                    "#rewind/pending #source/macos\r\n\r\n\r\n"
                    "> **Source:** [Antigravity](conversation://prose) · 2026-11-14T10:01:00Z\r\n\r\n"
                    + leading_blank_verbatim
                ),
            }
            self.assertEqual(svc.process_memo(state.memos["rw-prose"]), "enriched")
            prose_patched = state.memos["rw-prose"]["content"]
            self.assertEqual(prose_patched.count("> **Source:**"), 1)
            self.assertTrue(prose_patched.endswith("\n\n" + leading_blank_verbatim))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_has_ctx_wait_comment_arrival_and_timeout_fallback(self) -> None:
        state = MockBackendState()
        srv, base_url = _start_mock_upstream(state)
        try:
            t0 = 1_762_830_000.0
            created_iso = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            excerpt = "验收标识\n第二行：**绿色叶子**与 `alpha = 42`。\n"
            context = (
                "Session Title: 剪藏验收\n"
                "Prompt: 请按指定格式回复三行 Markdown。\n\n"
                "### Recent Turns\nUser: 请按指定格式回复三行 Markdown。\n"
                "Assistant: 验收标识\n第二行：**绿色叶子**与 `alpha = 42`。\n第三行：中文原文保持完整。"
            )
            state.memos["rw-ctx-1"] = {
                "name": "memos/rw-ctx-1",
                "createTime": created_iso,
                "content": (
                    "#rewind/pending #rewind/has-ctx #source/chatgpt\n\n"
                    "> **Source:** [剪藏验收](https://chatgpt.com/c/99) · 2026-11-11T03:00:00Z\n\n"
                    + excerpt
                ),
            }
            now_box = [t0 + 3.0]
            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
                clock=lambda: now_box[0],
            )

            self.assertEqual(svc.reconcile_once(), 0, "missing context within 15s window must defer")
            self.assertEqual(len(state.ai_calls), 0)
            self.assertIn("#rewind/pending", state.memos["rw-ctx-1"]["content"])

            summary = "用户要求三行 Markdown，选区保留了验收标识和行内代码。"
            state.ai_response["context_summary"] = summary
            state.comments["rw-ctx-1"] = [
                {
                    "name": "memos/rw-ctx-1-ctx",
                    "content": "<!-- rewind-context-v1 -->\n" + context,
                }
            ]
            self.assertEqual(svc.reconcile_once(), 1)
            self.assertEqual(len(state.ai_calls), 1)
            sent_prompt = json.loads(state.ai_calls[0]["messages"][1]["content"])
            self.assertEqual(sent_prompt["selected_excerpt"], excerpt)
            self.assertEqual(sent_prompt["captured_chat_context"], context)
            tags, metadata, stored_excerpt = state.memos["rw-ctx-1"]["content"].split("\n\n", 2)
            self.assertEqual(tags, "#rewind/ready #source/chatgpt")
            self.assertIn(f"> **Context:** {summary}", metadata.splitlines())
            self.assertEqual(stored_excerpt, excerpt)

            state.memos["rw-ctx-timeout"] = {
                "name": "memos/rw-ctx-timeout",
                "createTime": created_iso,
                "content": (
                    "#rewind/pending #rewind/has-ctx #source/gemini\n\n"
                    "> **Source:** [Dropped Comment](https://gemini.google.com/app/1) · 2026-11-11T03:00:00Z\n\n"
                    "SELECT 1;"
                ),
            }
            now_box[0] = t0 + 16.0
            self.assertEqual(svc.reconcile_once(), 1, "missing context past 15s grace window must proceed")
            self.assertEqual(len(state.ai_calls), 2)
            sent_prompt = json.loads(state.ai_calls[1]["messages"][1]["content"])
            self.assertEqual(sent_prompt["selected_excerpt"], "SELECT 1;")
            self.assertIsNone(sent_prompt["captured_chat_context"])
            self.assertTrue(state.memos["rw-ctx-timeout"]["content"].endswith("\n\nSELECT 1;"))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_idempotency_skips_ready_and_synthesized(self) -> None:
        state = MockBackendState()
        srv, base_url = _start_mock_upstream(state)
        try:
            state.memos["rw-idem"] = {
                "name": "memos/rw-idem",
                "createTime": "2026-11-11T03:00:00Z",
                "content": (
                    "#rewind/pending #source/macos\n\n"
                    "> **Source:** [Antigravity](conversation://abc-def) · 2026-11-11T03:00:00Z\n\n"
                    "let x = 42"
                ),
            }
            state.memos["rw-synth"] = {
                "name": "memos/rw-synth",
                "createTime": "2026-11-11T03:00:00Z",
                "content": "#rewind/synthesized #source/macos\n\nalready synthesized",
            }
            state.memos["unrelated"] = {
                "name": "memos/unrelated",
                "createTime": "2026-11-11T03:00:00Z",
                "content": "#daily-note\n\nBuy coffee",
            }
            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
            )
            self.assertEqual(svc.reconcile_once(), 1)
            first_ready = state.memos["rw-idem"]["content"]
            self.assertEqual(len(state.ai_calls), 1)

            self.assertEqual(svc.reconcile_once(), 0, "second reconcile must be a no-op")
            self.assertEqual(len(state.ai_calls), 1)
            self.assertEqual(state.memos["rw-idem"]["content"], first_ready)
            self.assertEqual(enricher.EnricherService(f"{base_url}/api/memos/", "t", "u", "k", "m")._base_url(), base_url)
            self.assertEqual(enricher.EnricherService(f"{base_url}/api/v1/memos/", "t", "u", "k", "m")._base_url(), base_url)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_end_to_end_webhook_and_http_server(self) -> None:
        state = MockBackendState()
        upstream_srv, base_url = _start_mock_upstream(state)
        raw_key = b"webhook-e2e-hmac-key-material-01"
        secret = "whsec" + "_" + base64.b64encode(raw_key).decode("ascii")
        svc = enricher.EnricherService(
            memos_url=base_url,
            memos_token="memos-tok",
            ai_base_url=f"{base_url}/v1",
            ai_api_key="ai-tok",
            ai_model="qwen-plus",
            webhook_secret=secret,
            poll_interval=60.0,
        )
        worker = threading.Thread(target=svc.run_loop, daemon=True)
        worker.start()
        http_srv = enricher.create_http_server(svc, host="localhost", port=0)
        threading.Thread(target=http_srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        enricher_url = f"http://localhost:{http_srv.server_address[1]}"
        try:
            with urllib.request.urlopen(f"{enricher_url}/healthz", timeout=5) as hresp:
                self.assertEqual(hresp.status, 200)

            time.sleep(0.05)
            snippet = "```swift\n@MainActor final class HUDPanel: NSPanel {}\n```"
            state.memos["rw-e2e"] = {
                "name": "memos/rw-e2e",
                "createTime": "2026-11-11T03:00:00Z",
                "content": (
                    "#rewind/pending #source/antigravity\n\n"
                    "> **Source:** [coding-rewind](conversation://1111-2222) · 2026-11-11T03:00:00Z\n\n"
                    + snippet
                ),
            }

            bad_req = urllib.request.Request(f"{enricher_url}/webhook", data=b"{}", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(bad_req, timeout=5)
            self.assertEqual(ctx.exception.code, 401, "unsigned webhook must be rejected with 401")
            ctx.exception.close()

            payload = b'{"activityType":"memos.memo.created"}'
            msg_id, ts = "msg_e2e_1", str(int(time.time()))
            sig = _sign_standard_webhook(raw_key, msg_id, ts, payload)
            good_req = urllib.request.Request(
                f"{enricher_url}/webhook",
                data=payload,
                headers={"Content-Type": "application/json", "webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": sig},
                method="POST",
            )
            with urllib.request.urlopen(good_req, timeout=5) as wresp:
                self.assertEqual(wresp.status, 200)
                self.assertEqual(json.loads(wresp.read().decode("utf-8")), {"ok": True})

            deadline = time.time() + 5.0
            while time.time() < deadline:
                with state.lock:
                    if state.memos["rw-e2e"]["content"].startswith("#rewind/ready"):
                        break
                time.sleep(0.02)

            enriched_text = state.memos["rw-e2e"]["content"]
            self.assertTrue(enriched_text.startswith("#rewind/ready #source/antigravity\n\n"))
            self.assertTrue(enriched_text.endswith("\n\n" + snippet))

            import http.client
            host, port = http_srv.server_address[0], http_srv.server_address[1]

            def raw_post(path: str, hdrs: dict[str, str]) -> int:
                conn = http.client.HTTPConnection(host, port, timeout=3)
                try:
                    conn.putrequest("POST", path)
                    for k, v in hdrs.items():
                        conn.putheader(k, v)
                    conn.endheaders()
                    resp = conn.getresponse()
                    _ = resp.read()
                    return resp.status
                finally:
                    conn.close()

            self.assertEqual(raw_post("/webhook", {"Content-Length": "-1"}), 400)
            self.assertEqual(raw_post("/webhook", {"Content-Length": "+2"}), 400)
            self.assertEqual(raw_post("/webhook", {"Content-Length": "1_0"}), 400)
            self.assertEqual(raw_post("/webhook", {"Content-Length": "not-an-int"}), 400)
            self.assertEqual(raw_post("/webhook", {"Content-Length": "2097152"}), 413)
            self.assertEqual(raw_post("/hooks/rewind", {"Transfer-Encoding": "chunked"}), 400)

            dup_conn = http.client.HTTPConnection(host, port, timeout=3)
            try:
                dup_conn.putrequest("POST", "/webhook")
                dup_conn.putheader("Content-Length", "2")
                dup_conn.putheader("Content-Length", "10")
                dup_conn.endheaders(b"{}")
                dup_resp = dup_conn.getresponse()
                _ = dup_resp.read()
                self.assertEqual(dup_resp.status, 400, "duplicate Content-Length headers must fail closed")
            finally:
                dup_conn.close()

            short_conn = http.client.HTTPConnection(host, port, timeout=3)
            try:
                short_conn.putrequest("POST", "/webhook")
                short_conn.putheader("Content-Length", "32")
                short_conn.endheaders()
                short_conn.sock.sendall(b"{}")
                short_conn.sock.shutdown(1)
                short_resp = short_conn.getresponse()
                _ = short_resp.read()
                self.assertEqual(short_resp.status, 400, "truncated body must fail closed")
            finally:
                short_conn.close()
        finally:
            svc.stop()
            http_srv.shutdown()
            http_srv.server_close()
            upstream_srv.shutdown()
            upstream_srv.server_close()

        unconfigured_svc = enricher.EnricherService(
            memos_url="http://localhost:9",
            memos_token="memos-tok",
            ai_base_url="https://api.deepseek.com",
            ai_api_key="ai-tok",
            ai_model="deepseek-flash",
            webhook_secret="",
        )
        unconfigured_srv = enricher.create_http_server(unconfigured_svc, host="localhost", port=0)
        threading.Thread(target=unconfigured_srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        unconf_url = f"http://localhost:{unconfigured_srv.server_address[1]}"
        try:
            for endpoint in ("/webhook", "/hooks/rewind"):
                req = urllib.request.Request(f"{unconf_url}{endpoint}", data=b"{}", method="POST")
                with self.assertRaises(urllib.error.HTTPError) as unconf_ctx:
                    urllib.request.urlopen(req, timeout=3)
                self.assertEqual(unconf_ctx.exception.code, 401, f"unconfigured webhook_secret must fail closed on {endpoint}")
                unconf_ctx.exception.close()
        finally:
            unconfigured_srv.shutdown()
            unconfigured_srv.server_close()

    def test_detect_and_resolve_summary_language(self) -> None:
        self.assertEqual(
            enricher.EnricherService("http://memos", "tok", "http://ai", "key", "m").summary_language,
            "auto",
        )
        self.assertEqual(
            enricher.detect_clip_language("如何使用 Swift Actor 隔离共享状态？"),
            "zh-Hans",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "```swift\nactor Store { var items: [String] = [] }\n```",
                "Session Title: 并发重构\nPrompt: 请给出最小示例",
            ),
            "zh-Hans",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "Use actor isolation to eliminate data races:\n```swift\n// 中文注释 inside fenced code\nactor Store {}\n```\nhttps://example.com/docs",
                "Session Title: Swift Concurrency\nPrompt: How do we isolate mutable state?",
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "When parsing UTF-8 headers, reject stray characters like 中 while validating ASCII tokens across HTTP boundaries.",
                None,
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "Use `let label = \"暂存\"` when wiring localized button text inside AppKit panels.",
                None,
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "Explain unclosed code fences cleanly:\n```python\nmsg = '中文未闭合代码块'\ndef helper():\n    return msg",
                None,
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "在 AppCoordinator 的 setLanguage 方法中同步刷新 Antigravity 插件配置。",
                None,
            ),
            "zh-Hans",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "Keep actor isolation strict across module boundaries.",
                "Session Title: 旧中文标题\nPrompt: 请用英文回答并发问题",
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "```python\ndef compute_digest(payload: bytes) -> str:\n    return payload.hex()\n```",
                "Session Title: \nPrompt: \n\n### Recent Turns\nUser: ```python\nx = 1\n```\nAssistant: ```python\nx = 2\n```",
            ),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language(
                "```python\n# 计算哈希摘要并返回十六进制字符串\nx = 1\n```",
                None,
            ),
            "zh-Hans",
        )
        self.assertEqual(enricher.detect_clip_language("```\nx = 1\n```", None), "zh-Hans")
        self.assertEqual(enricher.detect_clip_language("", None), "zh-Hans")

        self.assertEqual(enricher.resolve_summary_language("zh", "English words here"), "zh-Hans")
        self.assertEqual(enricher.resolve_summary_language("zh-CN", "English words here"), "zh-Hans")
        self.assertEqual(enricher.resolve_summary_language("zh-Hans", "English words here"), "zh-Hans")
        self.assertEqual(enricher.resolve_summary_language("en", "中文内容"), "en")
        self.assertEqual(enricher.resolve_summary_language("auto", "Two English words"), "en")
        self.assertEqual(enricher.resolve_summary_language("auto", "包含中文"), "zh-Hans")

    def test_english_and_auto_summary_language_preserve_wire_headers_and_verbatim_body(self) -> None:
        raw_en = (
            "#rewind/pending #source/claude\n\n"
            "> **Source:** [Actor Isolation](https://claude.ai/chat/en-1) · 2026-11-15T04:00:00Z\n\n"
            "Keep `Sendable` checks strict across module boundaries."
        )
        parsed = enricher.parse_raw_memo(raw_en)
        assert parsed is not None

        fallback_en = enricher.build_enriched_content(parsed, {}, language="en")
        self.assertIn("> **Title:** Code Snippet Excerpt", fallback_en)
        self.assertIn("> **Session:** Direct Capture Session", fallback_en)
        self.assertIn("> **Context:** Original clip preserved for follow-up synthesis.", fallback_en)
        self.assertIn("> **Keywords:** rewind", fallback_en)

        fallback_zh = enricher.build_enriched_content(parsed, {}, language="zh-Hans")
        self.assertIn("> **Title:** 代码片段摘录", fallback_zh)
        self.assertIn("> **Session:** 直接捕获会话", fallback_zh)
        self.assertIn("> **Context:** 已保留原始片段供后续串联分析。", fallback_zh)

        state = MockBackendState()
        state.ai_response = {
            "title": "Strict Sendable Boundaries",
            "session_topic": "Actor Isolation",
            "context_summary": "Enforces strict Sendable checking across Swift module boundaries.",
            "keywords": ["Swift", "Sendable"],
        }
        srv, base_url = _start_mock_upstream(state)
        try:
            en_verbatim = "Keep `Sendable` checks strict across module boundaries.\n\n```swift\npublic struct Item: Sendable {}\n```"
            zh_verbatim = "在模块边界保持严格的 `Sendable` 检查。"
            code_only_verbatim = "```rust\nfn main() {}\n```"

            state.memos["rw-auto-en"] = {
                "name": "memos/rw-auto-en",
                "createTime": "2026-11-15T04:00:00Z",
                "content": (
                    "#rewind/pending #rewind/has-ctx #source/claude\n\n"
                    "> **Source:** [Actor Isolation](https://claude.ai/chat/en-1) · 2026-11-15T04:00:00Z\n\n"
                    + en_verbatim
                ),
            }
            state.comments["rw-auto-en"] = [
                {
                    "name": "memos/rw-auto-en-ctx",
                    "content": (
                        "<!-- rewind-context-v1 -->\n"
                        "Session Title: Actor Isolation\n"
                        "Prompt: How should we enforce Sendable across modules?\n"
                    ),
                }
            ]
            state.memos["rw-auto-zh"] = {
                "name": "memos/rw-auto-zh",
                "createTime": "2026-11-15T04:01:00Z",
                "content": "#rewind/pending #source/chatgpt\n\n" + zh_verbatim,
            }
            state.memos["rw-auto-code"] = {
                "name": "memos/rw-auto-code",
                "createTime": "2026-11-15T04:02:00Z",
                "content": "#rewind/pending #source/macos\n\n" + code_only_verbatim,
            }

            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
            )
            self.assertEqual(svc.process_memo(state.memos["rw-auto-en"]), "enriched")
            self.assertEqual(state.ai_calls[0]["messages"][0]["content"], enricher.SYSTEM_PROMPT_EN)
            en_patched = state.memos["rw-auto-en"]["content"]
            expected_en_prefix = (
                "#rewind/ready #source/claude\n\n"
                "> **Title:** Strict Sendable Boundaries\n"
                "> **Session:** Actor Isolation\n"
                "> **Context:** Enforces strict Sendable checking across Swift module boundaries.\n"
                "> **Keywords:** Swift, Sendable\n"
                "> **Source:** [Actor Isolation](https://claude.ai/chat/en-1) · 2026-11-15T04:00:00Z\n\n"
            )
            self.assertTrue(en_patched.startswith(expected_en_prefix))
            self.assertEqual(en_patched[len(expected_en_prefix) :], en_verbatim)

            self.assertEqual(svc.process_memo(state.memos["rw-auto-zh"]), "enriched")
            self.assertEqual(state.ai_calls[1]["messages"][0]["content"], enricher.SYSTEM_PROMPT)
            self.assertTrue(state.memos["rw-auto-zh"]["content"].endswith("\n\n" + zh_verbatim))

            self.assertEqual(svc.process_memo(state.memos["rw-auto-code"]), "enriched")
            self.assertEqual(state.ai_calls[2]["messages"][0]["content"], enricher.SYSTEM_PROMPT_EN)
            self.assertTrue(state.memos["rw-auto-code"]["content"].endswith("\n\n" + code_only_verbatim))

            state.ai_response = {}
            state.memos["rw-en-empty-meta"] = {
                "name": "memos/rw-en-empty-meta",
                "createTime": "2026-11-15T04:03:00Z",
                "content": "#rewind/pending #source/web\n\n" + code_only_verbatim,
            }
            en_forced = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
                summary_language="en",
            )
            self.assertEqual(en_forced.process_memo(state.memos["rw-en-empty-meta"]), "enriched")
            self.assertEqual(state.ai_calls[3]["messages"][0]["content"], enricher.SYSTEM_PROMPT_EN)
            forced_patched = state.memos["rw-en-empty-meta"]["content"]
            self.assertIn("> **Title:** Code Snippet Excerpt\n", forced_patched)
            self.assertIn("> **Session:** Direct Capture Session\n", forced_patched)
            self.assertIn("> **Context:** Original clip preserved for follow-up synthesis.\n", forced_patched)
            self.assertTrue(forced_patched.endswith("\n\n" + code_only_verbatim))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_web_page_lead_enrichment_and_cjk_detection_immunity_to_session_id_uuids(self) -> None:
        self.assertIn("历史对话或页面导语上下文", enricher.SYSTEM_PROMPT)
        self.assertIn("historical conversation or source page lead", enricher.SYSTEM_PROMPT_EN)

        code_excerpt = "```swift\nactor FrameRingBuffer { var head = 0 }\n```"
        zh_ctx_with_ascii_session_id = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: 并发整理\n"
            "Session ID: deadbeef-cafe-babe-abcd-efgh-ijkl-mnop-qrst-uvwx-swift-actor-session\n"
            "Prompt: 示例\n\n"
            "### Session Opening\n"
            "隔离共享状态\n\n"
            "### Recent Turns\n"
            "User: 示例\n"
            "Assistant: ```swift\nactor FrameRingBuffer {}\n```"
        )
        self.assertEqual(
            enricher.detect_clip_language(code_excerpt, zh_ctx_with_ascii_session_id),
            "zh-Hans",
        )

        zh_page_lead_ctx = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: 零拷贝环形队列\n\n"
            "### Page Lead\n"
            "理解共享内存通道\n"
            "§ 环形描述符布局"
        )
        self.assertEqual(
            enricher.detect_clip_language(code_excerpt, zh_page_lead_ctx),
            "zh-Hans",
        )

        en_code_only_with_session_id = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: \n"
            "Session ID: abcdef-ghijkl-mnopqr-stuvwx\n\n"
            "### Session Opening\n"
            "```python\nx = 1\n```\n\n"
            "### Page Lead\n"
            "```python\ny = 2\n```\n\n"
            "### Prompt\n"
            "```python\nz = 3\n```"
        )
        self.assertEqual(
            enricher.detect_clip_language("```python\ndef compute_hash(buf: bytes) -> str:\n    return buf.hex()\n```", en_code_only_with_session_id),
            "en",
        )
        self.assertEqual(
            enricher.detect_clip_language("```\nx = 1\n```", en_code_only_with_session_id),
            "zh-Hans",
        )

        unclosed_opening_before_zh_turns = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: Refactor Worker\n"
            "Session ID: 67f0a1b2-3344\n"
            "Prompt: Summarize the retry contract\n\n"
            "### Session Opening\n"
            "```python\n"
            "class WebhookServer:\n"
            "    def serve_forever(self):…\n\n"
            "### Recent Turns\n"
            "User: 请用中文解释为什么这里需要幂等重试以及如何避免重复写入？\n"
            "Assistant: 因为网络超时后客户端会携带相同的资源标识重发请求，服务端必须保持幂等。"
        )
        self.assertEqual(
            enricher.detect_clip_language(code_excerpt, unclosed_opening_before_zh_turns),
            "zh-Hans",
        )

        unclosed_prompt_before_zh_turns = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: Retry Notes\n"
            "Prompt: Explain this snippet:\n"
            "```python\n"
            "def compute_digest(payload: bytes) -> str:\n"
            "    return payload.hex()…\n\n"
            "### Recent Turns\n"
            "User: 请用中文说明这里的超时重发与去重逻辑。\n"
            "Assistant: 客户端重试时复用同一个剪藏标识即可避免重复创建。"
        )
        self.assertEqual(
            enricher.detect_clip_language(code_excerpt, unclosed_prompt_before_zh_turns),
            "zh-Hans",
        )

        unclosed_sections_single_cjk_title = (
            "<!-- rewind-context-v1 -->\n"
            "Session Title: 锁\n"
            "Prompt: ```python\n"
            "x = 1\n\n"
            "### Session Opening\n"
            "```python\n"
            "y = 2\n\n"
            "### Page Lead\n"
            "~~~yaml\n"
            "mode: strict\n\n"
            "### Recent Turns\n"
            "User: ```python\n"
            "z = 3\n"
            "```"
        )
        self.assertEqual(
            enricher.detect_clip_language(code_excerpt, unclosed_sections_single_cjk_title),
            "zh-Hans",
        )

        state = MockBackendState()
        state.ai_response = {
            "title": "Zero-Copy Scatter-Gather Framing",
            "session_topic": "Zero-Copy Framing",
            "context_summary": "Explains using mmap(2) and writev(2) for framed ring-buffer batches.",
            "keywords": ["mmap", "writev", "IPC"],
        }
        srv, base_url = _start_mock_upstream(state)
        try:
            source_url = (
                "https://blog.example.org/systems/zero-copy#intro:~:text="
                "allocations%3A-,use%20mmap%282%29%20%26%20writev%282%29,-for%20framed"
            )
            verbatim = "use `mmap(2)` & `writev(2)`"
            page_lead_body = (
                "Session Title: Zero-Copy Framing\n\n"
                "### Page Lead\n"
                "Zero-Copy Ring Buffers\n"
                "§ Scatter-Gather Descriptors\n"
                "Designing zero-copy ring buffers for framed IPC."
            )
            state.memos["rw-web-lead"] = {
                "name": "memos/rw-web-lead",
                "createTime": "2026-11-16T12:00:00Z",
                "content": (
                    "#rewind/pending #rewind/has-ctx #source/web\n\n"
                    f"> **Source:** [Zero-Copy Framing]({source_url}) · 2026-11-16T12:00:00Z\n\n"
                    + verbatim
                ),
            }
            state.comments["rw-web-lead"] = [
                {
                    "name": "memos/rw-web-lead-ctx",
                    "content": "<!-- rewind-context-v1 -->\n" + page_lead_body,
                }
            ]

            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="qwen-plus",
            )
            self.assertEqual(svc.reconcile_once(), 1)
            self.assertEqual(len(state.ai_calls), 1)
            self.assertEqual(state.ai_calls[0]["messages"][0]["content"], enricher.SYSTEM_PROMPT_EN)
            sent_user_payload = json.loads(state.ai_calls[0]["messages"][1]["content"])
            self.assertEqual(sent_user_payload["selected_excerpt"], verbatim)
            self.assertEqual(sent_user_payload["captured_chat_context"], page_lead_body)

            patched = state.memos["rw-web-lead"]["content"]
            expected_prefix = (
                "#rewind/ready #source/web\n\n"
                "> **Title:** Zero-Copy Scatter-Gather Framing\n"
                "> **Session:** Zero-Copy Framing\n"
                "> **Context:** Explains using mmap(2) and writev(2) for framed ring-buffer batches.\n"
                "> **Keywords:** mmap, writev, IPC\n"
                f"> **Source:** [Zero-Copy Framing]({source_url}) · 2026-11-16T12:00:00Z\n\n"
            )
            self.assertTrue(patched.startswith(expected_prefix))
            self.assertEqual(patched[len(expected_prefix) :], verbatim)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_deepseek_v4_1_flash_default_and_non_thinking_payload_by_provider(self) -> None:
        dashscope_payload = enricher._build_chat_completion_payload(
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "deepseek-v4.1-flash",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertEqual(dashscope_payload["model"], "deepseek-v4.1-flash")
        self.assertEqual(dashscope_payload["temperature"], 0.2)
        self.assertEqual(dashscope_payload["response_format"], {"type": "json_object"})
        self.assertIs(dashscope_payload["enable_thinking"], False)
        self.assertNotIn("thinking", dashscope_payload)

        workspace_dashscope_payload = enricher._build_chat_completion_payload(
            "https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            "deepseek-v4.1-flash-1017",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertIs(workspace_dashscope_payload["enable_thinking"], False)
        self.assertNotIn("thinking", workspace_dashscope_payload)

        prefixed_dashscope_payload = enricher._build_chat_completion_payload(
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "siliconflow/deepseek-v3.2",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertIs(prefixed_dashscope_payload["enable_thinking"], False)
        self.assertNotIn("thinking", prefixed_dashscope_payload)

        prefixed_r1_payload = enricher._build_chat_completion_payload(
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "vanchin/deepseek-r1",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertNotIn("enable_thinking", prefixed_r1_payload)
        self.assertNotIn("thinking", prefixed_r1_payload)

        official_payload = enricher._build_chat_completion_payload(
            "https://api.deepseek.com",
            "deepseek-flash",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertEqual(official_payload["model"], "deepseek-flash")
        self.assertEqual(official_payload["thinking"], {"type": "disabled"})
        self.assertNotIn("enable_thinking", official_payload)

        reasoner_payload = enricher._build_chat_completion_payload(
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "deepseek-r1",
            enricher.SYSTEM_PROMPT,
            '{"selected_excerpt": "x"}',
        )
        self.assertNotIn("enable_thinking", reasoner_payload)
        self.assertNotIn("thinking", reasoner_payload)

        generic_payload = enricher._build_chat_completion_payload(
            "https://api.openai.com/v1",
            "gpt-4o-mini",
            enricher.SYSTEM_PROMPT_EN,
            '{"selected_excerpt": "x"}',
        )
        self.assertNotIn("enable_thinking", generic_payload)
        self.assertNotIn("thinking", generic_payload)

        captured: dict = {}

        class _DummyServer:
            def serve_forever(self) -> None:
                return

        orig_env = os.environ.copy()
        orig_thread = enricher.threading.Thread
        orig_create_server = enricher.create_http_server
        try:
            os.environ.pop("AI_MODEL", None)
            os.environ.pop("AI_BASE_URL", None)
            os.environ["MEMOS_ACCESS_TOKEN"] = "memos-tok"
            os.environ["AI_API_KEY"] = "deepseek-tok"

            class _NoopThread:
                def __init__(self, *args, **kwargs) -> None:
                    pass

                def start(self) -> None:
                    pass

            def _capture_server(service: enricher.EnricherService, host: str = "", port: int = 8090):
                captured["service"] = service
                return _DummyServer()

            enricher.threading.Thread = _NoopThread  # type: ignore[assignment]
            enricher.create_http_server = _capture_server  # type: ignore[assignment]
            enricher.main()
            svc = captured["service"]
            self.assertEqual(svc.ai_base_url, "https://api.deepseek.com")
            self.assertEqual(svc.ai_model, "deepseek-flash")
        finally:
            os.environ.clear()
            os.environ.update(orig_env)
            enricher.threading.Thread = orig_thread  # type: ignore[assignment]
            enricher.create_http_server = orig_create_server  # type: ignore[assignment]

        state = MockBackendState()
        state.ai_raw_content = "     "
        srv, base_url = _start_mock_upstream(state)
        try:
            original_content = "#rewind/pending #source/web\n\nverbatim text"
            state.memos["rw-blank-json"] = {
                "name": "memos/rw-blank-json",
                "createTime": "2026-11-17T00:00:00Z",
                "content": original_content,
            }
            svc = enricher.EnricherService(
                memos_url=base_url,
                memos_token="memos-tok",
                ai_base_url=f"{base_url}/v1",
                ai_api_key="ai-tok",
                ai_model="deepseek-v4.1-flash",
            )
            with self.assertRaises(ValueError):
                svc.process_memo(state.memos["rw-blank-json"])
            self.assertEqual(state.memos["rw-blank-json"]["content"], original_content, "blank JSON response must not patch memo")
        finally:
            srv.shutdown()
            srv.server_close()


def _place_memo(ref: str, title: str, aliases: str = "", status: str = "active") -> str:
    return (
        f"#rewind/place #{ref}\n\n"
        f"> **Title:** {title}\n"
        f"> **Aliases:** {aliases}\n"
        f"> **Ref:** Linear XWR-12\n"
        f"> **Status:** {status}\n\n"
        "Place page notes with #rewind/pending inside the body.\n"
    )


class PlaceVocabularyTests(unittest.TestCase):
    def _run_upstream(self, state: MockBackendState):
        srv, base_url = _start_mock_upstream(state)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return enricher.EnricherService(
            memos_url=base_url,
            memos_token="memos-tok",
            ai_base_url=f"{base_url}/v1",
            ai_api_key="ai-tok",
            ai_model="fixture-model",
            summary_language="zh-Hans",
        )

    def test_parse_place_memo_wire_format(self) -> None:
        self.assertEqual(
            enricher.parse_place_memo(_place_memo("project/paper-02", "著作权法的身体预设", "论文02, 身体预设, embodiment")),
            {"place": "project/paper-02", "title": "著作权法的身体预设", "aliases": ["论文02", "身体预设", "embodiment"], "active": True},
        )
        crlf = _place_memo("person/zhang-san", "张三", status="archived").replace("\n", "\r\n")
        self.assertEqual(
            enricher.parse_place_memo(crlf),
            {"place": "person/zhang-san", "title": "张三", "aliases": [], "active": False},
        )
        rejected = [
            "#project/paper-02\n\n> **Title:** Missing marker\n",
            "#rewind/place\n\n> **Title:** No ref\n",
            "#rewind/place #project/a #topic/b\n\n> **Title:** Two refs\n",
            "#rewind/place #Project/paper-02\n\n> **Title:** Uppercase kind\n",
            "#rewind/place #project/Paper-02\n\n> **Title:** Uppercase slug\n",
            "#rewind/place #project/paper-\n\n> **Title:** Trailing hyphen\n",
            "#rewind/place #habit/paper-02\n\n> **Title:** Unknown kind\n",
            "#rewind/place #topic/" + "a" * 29 + "\n\n> **Title:** Slug too long\n",
            "#rewind/ready #source/web\n\n> **Title:** A clip\n",
        ]
        for content in rejected:
            self.assertIsNone(enricher.parse_place_memo(content), content)
        self.assertIsNotNone(enricher.parse_place_memo("#rewind/place #topic/" + "a" * 28 + "\n"))
        self.assertIsNone(enricher.parse_raw_memo("#rewind/place #rewind/pending #project/paper-02\n\nBody"))

    def test_empty_vocabulary_keeps_prompt_and_output_identical(self) -> None:
        state = MockBackendState()
        state.ai_response = {**state.ai_response, "places": ["project/paper-02"]}
        clip = "#rewind/pending #source/web\n\n> **Source:** [Page](https://example.com/a) · 2026-11-21T00:00:00Z\n\n  verbatim  body\n"
        state.memos["clip"] = {"name": "memos/clip", "createTime": "2026-11-21T00:00:00Z", "content": clip}
        state.memos["archived"] = {"name": "memos/archived", "content": _place_memo("project/paper-02", "旧论文", status="archived")}
        svc = self._run_upstream(state)

        self.assertEqual(svc.reconcile_once(), 1)

        parsed = enricher.parse_raw_memo(clip)
        messages = state.ai_calls[0]["messages"]
        self.assertEqual(messages[0]["content"], enricher.SYSTEM_PROMPT)
        self.assertEqual(messages[1]["content"], json.dumps({
            "selected_excerpt": parsed["verbatim_body"],
            "captured_chat_context": None,
            "source": parsed["source_line"],
        }, ensure_ascii=False))
        self.assertEqual(state.memos["clip"]["content"], enricher.build_enriched_content(parsed, state.ai_response, language="zh-Hans"))
        self.assertEqual(state.patch_calls, [("clip", state.memos["clip"]["content"])])

    def test_places_are_closed_over_vocabulary_and_appended_to_tag_line(self) -> None:
        state = MockBackendState()
        verbatim = "\n  身体在著作权法中被预设为作者。\n```\ncode  stays\n```\n"
        state.memos["clip"] = {
            "name": "memos/clip",
            "createTime": "2026-11-21T00:00:00Z",
            "content": "#rewind/pending #source/web #PROJECT/paper-02\n\n" + verbatim,
        }
        places = {
            "p-paper": ("project/paper-02", "著作权法的身体预设", "论文02, 身体预设, embodiment", "active"),
            "p-embodiment": ("topic/embodiment", "具身", "", "active"),
            "p-law": ("topic/law-tech", "法律与技术", "", "active"),
            "p-zhang": ("person/zhang-san", "张三", "老张", "active"),
            "p-old": ("person/old-friend", "旧友", "", "archived"),
        }
        for memo_id, (ref, title, aliases, status) in places.items():
            state.memos[memo_id] = {"name": f"memos/{memo_id}", "content": _place_memo(ref, title, aliases, status)}
        place_contents = {memo_id: state.memos[memo_id]["content"] for memo_id in places}
        state.ai_response = {
            **state.ai_response,
            "places": [
                "#project/paper-02", "project/unknown", "person/old-friend", 7, None,
                "TOPIC/Embodiment", "topic/embodiment", "person/zhang-san", "topic/law-tech",
            ],
        }
        svc = self._run_upstream(state)

        self.assertEqual(svc.reconcile_once(), 1)

        messages = state.ai_calls[0]["messages"]
        self.assertEqual(messages[0]["content"], enricher.SYSTEM_PROMPT + enricher.PLACES_PROMPT)
        self.assertEqual(json.loads(messages[1]["content"])["place_vocabulary"], [
            {"place": "person/zhang-san", "title": "张三", "aliases": ["老张"]},
            {"place": "project/paper-02", "title": "著作权法的身体预设", "aliases": ["论文02", "身体预设", "embodiment"]},
            {"place": "topic/embodiment", "title": "具身", "aliases": []},
            {"place": "topic/law-tech", "title": "法律与技术", "aliases": []},
        ])
        content = state.memos["clip"]["content"]
        self.assertEqual(content.split("\n", 1)[0], "#rewind/ready #source/web #PROJECT/paper-02 #topic/embodiment #person/zhang-san")
        self.assertTrue(content.endswith("\n\n" + verbatim))
        self.assertEqual([memo_id for memo_id, _ in state.patch_calls], ["clip"])
        self.assertEqual({memo_id: state.memos[memo_id]["content"] for memo_id in places}, place_contents)

    def test_english_prompt_appends_english_places_instruction(self) -> None:
        state = MockBackendState()
        state.memos["clip"] = {"name": "memos/clip", "content": "#rewind/pending #source/web\n\nPlain English clip about embodiment theory."}
        state.memos["p"] = {"name": "memos/p", "content": _place_memo("topic/embodiment", "Embodiment")}
        svc = self._run_upstream(state)
        svc.summary_language = "en"

        self.assertEqual(svc.reconcile_once(), 1)

        self.assertEqual(state.ai_calls[0]["messages"][0]["content"], enricher.SYSTEM_PROMPT_EN + enricher.PLACES_PROMPT_EN)

    def test_malformed_places_output_is_ignored(self) -> None:
        for raw_places in ("topic/embodiment", {"topic/embodiment": True}, None, [["topic/embodiment"]]):
            state = MockBackendState()
            state.ai_response = {**state.ai_response, "places": raw_places}
            state.memos["clip"] = {"name": "memos/clip", "content": "#rewind/pending #source/web\n\nClip body"}
            state.memos["p"] = {"name": "memos/p", "content": _place_memo("topic/embodiment", "具身")}
            svc = self._run_upstream(state)

            self.assertEqual(svc.reconcile_once(), 1)

            content = state.memos["clip"]["content"]
            self.assertTrue(content.startswith("#rewind/ready #source/web\n\n> **Title:** "), raw_places)
            self.assertTrue(content.endswith("\n\nClip body"))

    def test_vocabulary_cache_is_refreshed_by_polling_scan_and_expires(self) -> None:
        now = [1_000.0]
        list_calls = []
        place = {"name": "memos/p", "content": _place_memo("topic/embodiment", "具身")}

        def request(method, url, auth, payload=None):
            self.assertEqual((method, urlparse(url).path), ("GET", "/api/memos"))
            list_calls.append(url)
            return {"memos": [place]}

        svc = enricher.EnricherService("http://memos.invalid", "memos-tok", "http://ai.invalid", "ai-tok", "fixture", clock=lambda: now[0])
        expected = [{"place": "topic/embodiment", "title": "具身", "aliases": []}]
        with patch.object(enricher, "_json_req", side_effect=request):
            self.assertEqual(svc.reconcile_once(), 0)
            self.assertEqual(len(list_calls), 1)
            now[0] += 59
            self.assertEqual(svc.places_vocabulary(), expected)
            self.assertEqual(len(list_calls), 1)
            now[0] += 2
            self.assertEqual(svc.places_vocabulary(), expected)
            self.assertEqual(len(list_calls), 2)
            now[0] += 30
            self.assertEqual(svc.places_vocabulary(), expected)
            self.assertEqual(len(list_calls), 2)


if __name__ == "__main__":
    unittest.main()

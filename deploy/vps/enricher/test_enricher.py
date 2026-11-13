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
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import enricher  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[3]
BRIDGE_SCRIPT = REPO_ROOT / "scripts" / "memos-mcp-bridge.sh"


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
                    content_str = json.dumps(state.ai_response, ensure_ascii=False)
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

        # Tampered payload or wrong signature must fail
        self.assertFalse(enricher.verify_webhook_signature(prefixed_secret, headers, body + b" ", now=now))
        bad_headers = {"webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": "v1,dGFtcGVyZWQ="}
        self.assertFalse(enricher.verify_webhook_signature(prefixed_secret, bad_headers, body, now=now))

        # Stale timestamp outside tolerance window must fail
        self.assertFalse(enricher.verify_webhook_signature(prefixed_secret, headers, body, now=now + 600))

        # Raw non-prefixed secret also verifies per Standard Webhooks / Memos fallback
        raw_secret = "plain-hmac-secret-value"
        raw_sig = _sign_standard_webhook(raw_secret.encode("utf-8"), msg_id, ts, body)
        raw_headers = {"Webhook-Id": msg_id, "Webhook-Timestamp": ts, "Webhook-Signature": raw_sig}
        self.assertTrue(enricher.verify_webhook_signature(raw_secret, raw_headers, body, now=now))

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

            # 1) Within 15s window & comment not yet posted -> defer (0 AI calls)
            self.assertEqual(svc.reconcile_once(), 0)
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
            sent_prompt = state.ai_calls[0]["messages"][1]["content"]
            self.assertTrue(sent_prompt.endswith(f"\n\nCaptured Chat Context:\n{context}\n\nSelected Excerpt:\n{excerpt}"))
            tags, metadata, stored_excerpt = state.memos["rw-ctx-1"]["content"].split("\n\n", 2)
            self.assertEqual(tags, "#rewind/ready #source/chatgpt")
            self.assertIn(f"> **Context:** {summary}", metadata.splitlines())
            self.assertEqual(stored_excerpt, excerpt)

            # 3) Second memo with #rewind/has-ctx whose comment NEVER arrives -> proceeds gracefully after 15s
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
            self.assertEqual(svc.reconcile_once(), 1)
            self.assertEqual(len(state.ai_calls), 2)
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

            # Running reconcile_once again must be a strict no-op with zero extra AI calls
            self.assertEqual(svc.reconcile_once(), 0)
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

            # Insert a pending memo after initial startup poll
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

            # Unsigned webhook must be rejected with 401
            bad_req = urllib.request.Request(f"{enricher_url}/webhook", data=b"{}", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(bad_req, timeout=5)
            self.assertEqual(ctx.exception.code, 401)
            ctx.exception.close()

            # Valid signed Standard Webhook wakes background loop immediately (even though poll_interval=60s)
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
        finally:
            svc.stop()
            http_srv.shutdown()
            http_srv.server_close()
            upstream_srv.shutdown()
            upstream_srv.server_close()


class MemosMcpBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch_parent = REPO_ROOT / ".build"
        scratch_parent.mkdir(parents=True, exist_ok=True)
        self.temp_dir = Path(tempfile.mkdtemp(prefix="bridge-test-", dir=str(scratch_parent)))
        self.bin_dir = self.temp_dir / "bin"
        self.bin_dir.mkdir()

        # Mock npx records argv as JSON instead of hitting npm/network
        npx_stub = self.bin_dir / "npx"
        npx_stub.write_text(
            "#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n",
            encoding="utf-8",
        )
        npx_stub.chmod(0o755)

        # Mock macOS `security` binary containing ONLY personal com.codingrewind.memos token
        sec_stub = self.bin_dir / "security"
        sec_stub.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "args = sys.argv[1:]\n"
            "svc = args[args.index('-s') + 1] if '-s' in args else ''\n"
            "log_path = os.environ.get('MOCK_SECURITY_LOG')\n"
            "if log_path:\n"
            "    open(log_path, 'a', encoding='utf-8').write(svc + '\\n')\n"
            "if svc == 'com.codingrewind.memos' and os.environ.get('MOCK_PERSONAL_TOKEN'):\n"
            "    print(os.environ['MOCK_PERSONAL_TOKEN'])\n"
            "    sys.exit(0)\n"
            "sys.exit(44)\n",
            encoding="utf-8",
        )
        sec_stub.chmod(0o755)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _base_env(self) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if not k.startswith("CODING_REWIND_")}
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["CODING_REWIND_DATA_DIR"] = str(self.temp_dir / "data")
        return env

    def test_env_resolution_and_trailing_slash_normalization(self) -> None:
        env = self._base_env()
        env["CODING_REWIND_MEMOS_URL"] = "https://memos.example.com/"
        env["CODING_REWIND_MEMOS_TOKEN"] = "env-secret-token"
        proc = subprocess.run([str(BRIDGE_SCRIPT)], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(
            json.loads(proc.stdout.strip()),
            ["-y", "mcp-remote", "https://memos.example.com/mcp", "--header", "Authorization: Bearer env-secret-token"],
        )

    def test_config_json_and_keychain_resolution(self) -> None:
        env = self._base_env()
        data_dir = Path(env["CODING_REWIND_DATA_DIR"])
        data_dir.mkdir(parents=True, exist_ok=True)
        (data_dir / "config.json").write_text('{"memos_url": "https://notes.example.org"}', encoding="utf-8")
        env["MOCK_PERSONAL_TOKEN"] = "kc-token-123"
        proc = subprocess.run([str(BRIDGE_SCRIPT)], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(
            json.loads(proc.stdout.strip()),
            ["-y", "mcp-remote", "https://notes.example.org/mcp", "--header", "Authorization: Bearer kc-token-123"],
        )

    def test_missing_url_and_qa_keychain_isolation(self) -> None:
        # Missing URL fails cleanly
        env = self._base_env()
        missing_url = subprocess.run([str(BRIDGE_SCRIPT)], env=env, capture_output=True, text=True)
        self.assertNotEqual(missing_url.returncode, 0)
        self.assertIn("missing Memos URL", missing_url.stderr)

        # CODING_REWIND_QA=1 MUST query com.codingrewind.memos.qa and NEVER fall back to personal Keychain
        env["CODING_REWIND_MEMOS_URL"] = "https://qa.example.org"
        env["CODING_REWIND_QA"] = "1"
        env["CODING_REWIND_KEYCHAIN_SERVICE"] = "com.codingrewind.memos"
        env["MOCK_PERSONAL_TOKEN"] = "personal-token-must-not-leak"
        sec_log = self.temp_dir / "security_calls.log"
        env["MOCK_SECURITY_LOG"] = str(sec_log)

        qa_res = subprocess.run([str(BRIDGE_SCRIPT)], env=env, capture_output=True, text=True)
        self.assertNotEqual(qa_res.returncode, 0)
        self.assertIn("com.codingrewind.memos.qa", qa_res.stderr)
        self.assertNotIn("personal-token-must-not-leak", qa_res.stdout)
        self.assertEqual(sec_log.read_text(encoding="utf-8").splitlines(), ["com.codingrewind.memos.qa"])


if __name__ == "__main__":
    unittest.main()

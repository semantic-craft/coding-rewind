#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True


class _SessionHTTP:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar))
        self.bearer_token: str | None = None

    def request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        bearer: str | None = None,
        timeout: float = 15.0,
    ) -> tuple[int, dict | str]:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Accept": "application/json"}
        effective_bearer = bearer if bearer is not None else self.bearer_token
        if effective_bearer:
            headers["Authorization"] = f"Bearer {effective_bearer}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout) as resp:
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


def _wait_for_healthz(client: _SessionHTTP, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_error = "timeout"
    while time.monotonic() < deadline:
        try:
            status, _ = client.request("GET", "/healthz", timeout=3.0)
            if 200 <= status < 300:
                return
            last_error = f"HTTP {status}"
        except (urllib.error.URLError, OSError) as exc:
            last_error = str(exc)
        time.sleep(0.5)
    raise RuntimeError(f"Memos container at {client.base_url} did not become healthy within {timeout_seconds}s ({last_error})")


def _extract_user_id(body: dict | str) -> str | None:
    if not isinstance(body, dict):
        return None
    for candidate in (body, body.get("user")):
        if not isinstance(candidate, dict):
            continue
        name = candidate.get("name")
        if isinstance(name, str) and "/" in name:
            return name.split("/", 1)[1]
        uid = candidate.get("id")
        if uid is not None and str(uid).strip():
            return str(uid).strip()
    return None


def _extract_token(body: dict | str) -> str | None:
    if not isinstance(body, dict):
        return None
    for key in ("token", "accessToken", "access_token"):
        val = body.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    for nested_key in ("personalAccessToken", "personal_access_token", "accessToken"):
        nested = body.get(nested_key)
        if isinstance(nested, dict):
            val = nested.get("token")
            if isinstance(val, str) and val.strip():
                return val.strip()
    return None


def _verify_token(client: _SessionHTTP, token: str) -> bool:
    st, _ = client.request("GET", "/api/memos?pageSize=1", bearer=token)
    if st != 200:
        return False
    probe_id = f"rw-boot-{secrets.token_hex(4)}"
    cst, cbody = client.request(
        "POST",
        f"/api/memos?memoId={urllib.parse.quote(probe_id)}",
        payload={"content": "#rewind/ready\n\nbootstrap probe", "visibility": "PRIVATE"},
        bearer=token,
    )
    if not (200 <= cst < 300) or not isinstance(cbody, dict):
        return False
    name = str(cbody.get("name", ""))
    memo_id = name.split("/", 1)[1] if "/" in name else probe_id
    client.request("DELETE", f"/api/memos/{urllib.parse.quote(memo_id, safe='')}", bearer=token)
    return True


def bootstrap_memos(base_url: str, username: str, password: str, timeout_seconds: float) -> str:
    client = _SessionHTTP(base_url)
    _wait_for_healthz(client, timeout_seconds)

    user_id: str | None = None
    signup_attempts = [
        ("/api/users", {"username": username, "password": password, "role": "ADMIN"}),
        ("/api/users", {"username": username, "password": password, "role": "HOST"}),
        ("/api/auth/signup", {"username": username, "password": password, "role": "HOST"}),
        ("/api/auth/signup", {"username": username, "password": password, "role": "ADMIN"}),
        ("/api/v1/users", {"username": username, "password": password, "role": "ADMIN"}),
        ("/api/v1/auth/signup", {"username": username, "password": password, "role": "HOST"}),
    ]
    signup_log: list[str] = []
    for path, payload in signup_attempts:
        st, body = client.request("POST", path, payload=payload)
        signup_log.append(f"{path}:{st}")
        if 200 <= st < 300:
            user_id = _extract_user_id(body) or user_id
            tok = _extract_token(body)
            if tok:
                client.bearer_token = tok
            break
        if st == 409:
            break

    signin_attempts = [
        ("/api/auth/signin", {"passwordCredentials": {"username": username, "password": password}}),
        ("/api/auth/signin", {"username": username, "password": password}),
        ("/api/auth/sessions", {"passwordCredentials": {"username": username, "password": password}}),
        ("/api/v1/auth/signin", {"passwordCredentials": {"username": username, "password": password}}),
        ("/api/v1/auth/sessions", {"passwordCredentials": {"username": username, "password": password}}),
    ]
    signin_log: list[str] = []
    for path, payload in signin_attempts:
        st, body = client.request("POST", path, payload=payload)
        signin_log.append(f"{path}:{st}")
        if 200 <= st < 300:
            user_id = _extract_user_id(body) or user_id
            tok = _extract_token(body)
            if tok:
                client.bearer_token = tok
            break

    resolved_uid = user_id or "1"
    pat_attempts = [
        (
            f"/api/users/{resolved_uid}/personalAccessTokens",
            {"description": "coding-rewind-e2e", "expiresInDays": 1},
        ),
        (
            f"/api/users/{resolved_uid}/personal_access_tokens",
            {"description": "coding-rewind-e2e", "expiresInDays": 1},
        ),
        (
            f"/api/users/{resolved_uid}/access_tokens",
            {"description": "coding-rewind-e2e"},
        ),
        (
            f"/api/v1/users/{resolved_uid}/personalAccessTokens",
            {"description": "coding-rewind-e2e", "expiresInDays": 1},
        ),
        (
            f"/api/v1/users/{resolved_uid}/access_tokens",
            {"description": "coding-rewind-e2e"},
        ),
    ]
    pat_log: list[str] = []
    for path, payload in pat_attempts:
        st, body = client.request("POST", path, payload=payload)
        pat_log.append(f"{path}:{st}")
        if 200 <= st < 300:
            pat = _extract_token(body)
            if pat and _verify_token(client, pat):
                return pat

    if client.bearer_token and _verify_token(client, client.bearer_token):
        return client.bearer_token

    raise RuntimeError(
        "Failed to bootstrap Memos PAT "
        f"(signup={','.join(signup_log)} signin={','.join(signin_log)} pat={','.join(pat_log)})"
    )


def _write_secret_file(path: Path, content: str) -> None:
    resolved = path.expanduser().resolve()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = resolved.parent / f".{resolved.name}.{os.getpid()}.pending"
    fd = os.open(str(tmp_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, content.encode("utf-8"))
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)
    os.replace(tmp_path, resolved)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Bootstrap a fresh Memos 26.11.0 container for E2E tests.")
    parser.add_argument("--url", default="http://127.0.0.1:5230", help="Memos base URL.")
    parser.add_argument("--timeout", type=float, default=60.0, help="Healthz wait timeout in seconds.")
    parser.add_argument("--username", default="e2eadmin", help="Initial HOST admin username.")
    parser.add_argument("--password", default="RewindE2EPass2026!", help="Initial HOST admin password.")
    parser.add_argument("--output-file", required=True, type=Path, help="Secret output file (mode 0600).")
    parser.add_argument("--format", choices=("env", "json"), default="env", help="Output file format.")
    args = parser.parse_args(argv)

    base_url = args.url.rstrip("/")
    token = bootstrap_memos(base_url, args.username, args.password, args.timeout)
    if args.format == "json":
        content = json.dumps({"MEMOS_E2E_URL": base_url, "MEMOS_E2E_TOKEN": token}, indent=2) + "\n"
    else:
        content = f"MEMOS_E2E_URL={base_url}\nMEMOS_E2E_TOKEN={token}\n"
    _write_secret_file(args.output_file, content)
    print(f"Bootstrapped Memos at {base_url}; verified token written to {args.output_file} (redacted).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

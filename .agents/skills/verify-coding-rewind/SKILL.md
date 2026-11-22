---
name: verify-coding-rewind
description: "Drive and verify Coding Rewind end to end across its CLI, embedded MCP stdio server, real SQLite Memos 26.11.0 contract backend, VPS AI enricher, Web Clipper wire payload module, and formal BFS concurrency models. Use when proving behavior before shipping or reproducing bugs on the real binaries and services."
---

# Verify Coding Rewind

Drive Coding Rewind's real binaries and services against an isolated on-disk SQLite Memos 26.11.0 contract server and an isolated `CODING_REWIND_DATA_DIR` under `.build/`. Read [features/README.md](features/README.md) first, then follow the matching feature file as the literal recipe.

Surfaces covered:

- **Primary:** `coding-rewind` Swift CLI and embedded `coding-rewind mcp` JSON-RPC stdio server backed by `verification/e2e/sqlite_memos_server.py`.
- **Backend & Enricher:** `deploy/vps/enricher/enricher.py` (`EnricherService`) against `sqlite_memos_server.py` or a live `neosmemo/memos:26.11.0` container.
- **Web Clipper:** `extensions/web-clipper/memos_payload.mjs` driven directly with `node` against live HTTP `/api/memos`.
- **Concurrency Models:** `verification/formal/run_all.py` explicit-state BFS checker and historical bug replays.

Isolation rule: every run owns a unique directory `.build/verify-<run-id>/` holding `memos.sqlite3`, `ready.json`, `data/` (`CODING_REWIND_DATA_DIR`), and an ephemeral TCP port (`--port 0`). Never point verification commands at `~/Library/Application Support/CodingRewind`, a user's live Memos server, or `/tmp/`.

## Launch

Build the `coding-rewind` CLI once, then launch an isolated `sqlite_memos_server.py` instance bound to an ephemeral loopback port:

```bash
export RUN_ID="run-$(date +%s)-$$"
export VERIFY_ROOT="$(pwd)/.build/verify-${RUN_ID}"
export CODING_REWIND_DATA_DIR="${VERIFY_ROOT}/data"
export CODING_REWIND_MEMOS_TOKEN="verify-tok-${RUN_ID}"
export CODING_REWIND_AI_ACCESS="read_write"
mkdir -p "${CODING_REWIND_DATA_DIR}"

swift build --product coding-rewind
export CODING_REWIND_BIN="$(swift build --show-bin-path)/coding-rewind"

python3 -B verification/e2e/sqlite_memos_server.py \
  --db "${VERIFY_ROOT}/memos.sqlite3" \
  --port 0 \
  --token "${CODING_REWIND_MEMOS_TOKEN}" \
  --ready-file "${VERIFY_ROOT}/ready.json" \
  >"${VERIFY_ROOT}/memos-server.log" 2>&1 &
```

Wait until `${VERIFY_ROOT}/ready.json` appears (atomic rename guarantees the socket is bound and listening before the file exists), then load `CODING_REWIND_MEMOS_URL` and `MEMOS_SERVER_PID`:

```bash
for _ in $(seq 1 50); do
  [[ -f "${VERIFY_ROOT}/ready.json" ]] && break
  sleep 0.1
done
test -f "${VERIFY_ROOT}/ready.json"

export CODING_REWIND_MEMOS_URL="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["url"])' "${VERIFY_ROOT}/ready.json")"
export MEMOS_SERVER_PID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "${VERIFY_ROOT}/ready.json")"
```

Usable state is reached when `ready.json` exists, `kill -0 "${MEMOS_SERVER_PID}"` succeeds, and `GET ${CODING_REWIND_MEMOS_URL}/healthz` returns HTTP `200` with `{"ok": true}`. Teardown is defined in **Cleanup** below and must run even after a failed verification step.

## Doctor

Run this single read-only check before driving any feature, and re-run it immediately if any command behaves unexpectedly:

```bash
set -euo pipefail
test -x "${CODING_REWIND_BIN}"
"${CODING_REWIND_BIN}" --version --json
kill -0 "${MEMOS_SERVER_PID}"
case "${CODING_REWIND_DATA_DIR}" in
  "$(pwd)/.build/verify-"*) ;;
  *) echo "FAIL: CODING_REWIND_DATA_DIR is not isolated under .build/verify-*" >&2; exit 1 ;;
esac

python3 -B - <<'PY'
import json, os, sys, urllib.error, urllib.request

base = os.environ["CODING_REWIND_MEMOS_URL"].rstrip("/")
tok = os.environ["CODING_REWIND_MEMOS_TOKEN"]

def req(path, auth=False):
    headers = {"Accept": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {tok}"
    r = urllib.request.Request(f"{base}{path}", headers=headers, method="GET")
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, exc.read().decode("utf-8")
        finally:
            exc.close()

st_h, body_h = req("/healthz", auth=False)
assert st_h == 200 and json.loads(body_h) == {"ok": True}, (st_h, body_h)
st_m, body_m = req("/api/memos?pageSize=1", auth=True)
assert st_m == 200 and "memos" in json.loads(body_m), (st_m, body_m)
st_u, _ = req("/api/memos?pageSize=1", auth=False)
assert st_u == 401, st_u
st_v1, _ = req("/api/v1/memos", auth=True)
assert st_v1 == 410, st_v1
print(json.dumps({"doctor": "ok", "url": base, "healthz": st_h, "api_memos": st_m, "unauth": st_u, "legacy_v1": st_v1}))
PY
```

Doctor passes only when `coding-rewind --version --json` prints the built version, `MEMOS_SERVER_PID` is alive, `CODING_REWIND_DATA_DIR` is under `.build/verify-*`, `/healthz` returns `200`, authenticated `/api/memos?pageSize=1` returns `200`, unauthenticated `/api/memos` returns `401`, and `/api/v1/memos` returns `410`.

## Drive

Select the matching feature recipe from [features/README.md](features/README.md):

- **CLI CRUD & MCP tools:** [features/clip-cli-crud-and-mcp.md](features/clip-cli-crud-and-mcp.md). Drives `"${CODING_REWIND_BIN}"` (`create`, `list`, `get`, `note`, `archive`, `place add`, `place list`) with `--json` and drives `"${CODING_REWIND_BIN}" mcp` over newline-delimited JSON-RPC 2.0 (`initialize`, `tools/list`).
- **Enricher & Places E2E:** [features/enricher-and-places-e2e.md](features/enricher-and-places-e2e.md). Drives `python3 -B -m unittest verification/e2e/test_real_memos_e2e.py -v` against local `sqlite_memos_server.py` or external `MEMOS_E2E_URL` + `MEMOS_E2E_TOKEN`.
- **Web Clipper wire contract:** [features/web-clipper-wire-contract.md](features/web-clipper-wire-contract.md). Drives `extensions/web-clipper/memos_payload.mjs` (`saveClipWithOutbox`) directly via `node` against live `/api/memos` and verifies idempotent `409` retries and verbatim preservation.
- **Formal concurrency models:** [features/formal-concurrency-verification.md](features/formal-concurrency-verification.md). Drives `python3 -B verification/formal/run_all.py --verify-bug-replays`.

## Evidence

Proof standards:

- Exercise the real user path (`coding-rewind` CLI, `coding-rewind mcp`, `node` running `memos_payload.mjs`, `EnricherService` over real HTTP, SQLite on disk). Never bypass the CLI or HTTP boundary with internal setters.
- Capture both the action and the resulting state: command invoked, exit code, structured JSON stdout, and a second read-only view (HTTP `GET /api/memos/<id>` and `GET /api/memos/<id>/comments` or SQLite row read) proving persistence.
- Store proof artifacts OUTSIDE `${VERIFY_ROOT}` (for example in the conversation scratch directory `<appDataDir>/brain/<conversation-id>/scratch/verify_skill_proof.json` or another caller-specified artifact path) so Cleanup never deletes the proof.
- Record the feature ID, entry point, server URL, and pass/fail assertions in the JSON proof artifact.

## Cleanup

Tear down ONLY the PID recorded in `${VERIFY_ROOT}/ready.json` and remove ONLY `${VERIFY_ROOT}`:

```bash
if [[ -n "${MEMOS_SERVER_PID:-}" ]]; then
  kill "${MEMOS_SERVER_PID}" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "${MEMOS_SERVER_PID}" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "${MEMOS_SERVER_PID}" 2>/dev/null || true
fi
if [[ -n "${VERIFY_ROOT:-}" && "${VERIFY_ROOT}" == "$(pwd)/.build/verify-"* ]]; then
  rm -rf "${VERIFY_ROOT}"
fi
```

Cleanup rules:

- Never run `pkill`, `killall`, or match by process name. Kill only `MEMOS_SERVER_PID` from `${VERIFY_ROOT}/ready.json`.
- Never delete proof artifacts during cleanup. Confirm the proof file still exists and parses as valid JSON after cleanup finishes.
- Run Cleanup after failed iterations too so no loopback ports or `.build/verify-*` directories are stranded.

## Helpers

All repo helpers are directly executable with pure stdlib Python 3, Node, and Swift:

- **SQLite Memos 26.11.0 server:** `python3 -B verification/e2e/sqlite_memos_server.py --db <path> --port 0 --token <tok> --ready-file <path>`
- **Real Memos E2E suite (auto-spawns SQLite server, or targets `MEMOS_E2E_URL` + `MEMOS_E2E_TOKEN`):** `python3 -B -m unittest verification/e2e/test_real_memos_e2e.py -v`
- **Container bootstrapper for CI `neosmemo/memos:26.11.0`:** `python3 -B verification/e2e/bootstrap_memos_container.py --url http://127.0.0.1:5230 --output-file <path>`
- **Formal state-machine model checker:** `python3 -B verification/formal/run_all.py --verify-bug-replays`
- **Full repository verification gate:** `./scripts/check`

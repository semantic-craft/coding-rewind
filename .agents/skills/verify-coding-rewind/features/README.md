# Coding Rewind verification map

This directory is the maintained source for verifying the user-facing behavior of Coding Rewind. Read this index before driving any binary or service, then follow the matching feature file verbatim.

## Baseline preconditions

- Build the CLI binary with `swift build --product coding-rewind` and set `CODING_REWIND_BIN="$(swift build --show-bin-path)/coding-rewind"`.
- Create an isolated scratch root `VERIFY_ROOT="$(pwd)/.build/verify-${RUN_ID}"` with `CODING_REWIND_DATA_DIR="${VERIFY_ROOT}/data"`. Never use `/tmp/` or the user's `~/Library/Application Support/CodingRewind`.
- Launch `verification/e2e/sqlite_memos_server.py` with `--db "${VERIFY_ROOT}/memos.sqlite3"`, `--port 0`, a per-run `CODING_REWIND_MEMOS_TOKEN`, and `--ready-file "${VERIFY_ROOT}/ready.json"`.
- Set `CODING_REWIND_MEMOS_URL` from `ready.json` and `CODING_REWIND_AI_ACCESS="read_write"`.
- Run the **Doctor** check in [SKILL.md](../SKILL.md) and require HTTP `200` on `/healthz`, HTTP `200` on authenticated `/api/memos?pageSize=1`, HTTP `401` without auth, and HTTP `410` on `/api/v1/memos`.
- Never drive a Memos instance or data directory that was not started by the current verification run.

## Driving conventions

- Start every recipe from a freshly launched isolated baseline unless its preconditions explicitly target an external `MEMOS_E2E_URL` container.
- Pass `--json` to `coding-rewind` CLI commands for deterministic machine-checkable output.
- Communicate with `coding-rewind mcp` over newline-delimited JSON-RPC 2.0 on stdin/stdout.
- Run Web Clipper wire tests directly with `node` against `extensions/web-clipper/memos_payload.mjs`.
- Always run **Cleanup** after both passing and failing runs without deleting proof artifacts.

## Proof and skip reporting

- Capture the exact user action and the resulting state, not only a final status code.
- CLI proof includes the command, exit code, stdout JSON, and a second read-only view from HTTP `GET /api/memos/<id>` or `GET /api/memos/<id>/comments`.
- MCP proof includes the exact JSON-RPC request and parsed JSON-RPC response lines.
- Record the feature ID, entry point, and assertion checks inside the proof artifact stored outside `VERIFY_ROOT`.
- Report an unreachable path with the attempted command and the unmet precondition. Do not report a skipped path as verified through another entry point.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior, followed by exactly four H2 sections in this order:

1. `Sub-features` lists short IDs with one line per behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with <harness>` starts with `Preconditions:` and pairs each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

## Features

- [Clip CLI CRUD and MCP](./clip-cli-crud-and-mcp.md) covers `coding-rewind` CLI create, list, note, archive, and `coding-rewind mcp` JSON-RPC tool discovery against real SQLite Memos storage.
- [Enricher and Places E2E](./enricher-and-places-e2e.md) covers multi-page pagination, the 15-second context wait window, closed-vocabulary place filtering, verbatim body preservation, note/context isolation, and SQLite restart persistence.
- [Web Clipper wire contract](./web-clipper-wire-contract.md) covers `memos_payload.mjs` upload, context comment attachment, legacy `/api/v1/memos` rejection, and idempotent `409` retries.
- [Formal concurrency verification](./formal-concurrency-verification.md) covers exhaustive BFS verification of the 3 gated concurrency/crash-recovery state machines and all 10 historical bug replays.

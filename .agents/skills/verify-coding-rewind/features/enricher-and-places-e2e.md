# Enricher and Places E2E

Enricher and Places E2E verifies that the VPS AI enricher (`deploy/vps/enricher/enricher.py`) scans across multiple Memos pages, defers enrichment while a `#rewind/has-ctx` clip is within the 15-second context wait window, filters AI-suggested places to the user's closed `#rewind/place` vocabulary, preserves verbatim excerpts byte-for-byte, isolates note comments from context comments, and persists state in SQLite across restarts.

## Sub-features

- `enricher-multipage-scan` discovers `#rewind/pending` clips beyond page 1 (`pageSize=50`).
- `enricher-ctx-wait` returns `"deferred"` when `#rewind/has-ctx` is set, no `<!-- rewind-context-v1 -->` comment exists yet, and elapsed time is under 15 seconds.
- `enricher-closed-places` applies known `#project/<slug>` place tags from `#rewind/place` memos and drops hallucinated places.
- `enricher-verbatim-preserve` leaves literal `#rewind/pending` tokens and fenced code blocks with blank lines inside the excerpt byte-identical.
- `enricher-note-isolation` prevents `<!-- rewind-note-v1 -->` comments from being read as conversation context.
- `sqlite-restart-persistence` preserves memos and comments on disk across `SQLiteMemosServer` stop and restart.

## How to get to it (user POV)

- Save clips with `#rewind/pending #rewind/has-ctx` and `#rewind/place` memos to Memos while `rewind-enricher` polls or receives webhooks.
- Run the E2E suite locally against `sqlite_memos_server.py` or in CI against a live `neosmemo/memos:26.11.0` container.

## Driving it with test_real_memos_e2e.py

Preconditions:

- Python 3.12+ and Node 22+ are available on `PATH`.
- For local SQLite mode, `MEMOS_E2E_URL` is unset (the suite auto-spawns `SQLiteMemosServer` under `.build/`).
- For live container mode, `neosmemo/memos:26.11.0` is running on `127.0.0.1:5230` and `bootstrap_memos_container.py` wrote `MEMOS_E2E_URL` and `MEMOS_E2E_TOKEN`.

- **Run local SQLite E2E.** Execute `python3 -B -m unittest verification/e2e/test_real_memos_e2e.py -v`. All 5 test cases (`test_a` through `test_e`) pass with exit code `0` and zero warnings.
- **Run against real `neosmemo/memos:26.11.0` container (CI / Docker).** Start `docker run -d --name memos-e2e -p 127.0.0.1:5230:5230 neosmemo/memos:26.11.0`, bootstrap with `python3 -B verification/e2e/bootstrap_memos_container.py --url http://127.0.0.1:5230 --output-file .build/memos-e2e.env`, source `.build/memos-e2e.env`, and execute `python3 -B -m unittest verification/e2e/test_real_memos_e2e.py -v`. All 5 tests pass with exit code `0`.
- **Observe multi-page & verbatim proof.** Confirm `test_c_multipage_pagination_enricher_wait_window_places_and_verbatim` seeds 55 memos (forcing page 2), receives `"deferred"` before the context comment arrives, enriches after posting `<!-- rewind-context-v1 -->`, attaches `#project/e2e-verify`, rejects `project/invented-hallucination`, and verifies exact byte-for-byte verbatim suffix equality.
- **Observe note/context isolation and SQLite persistence.** Confirm `test_d_note_comment_isolated_from_context_comment` and `test_e_sqlite_persistence_across_server_restart` both report `ok`.

## Gotchas

- Never print `MEMOS_E2E_TOKEN` to stdout or CI logs; `bootstrap_memos_container.py` writes the token to a mode `0600` file and redacts console output.
- In real Memos `26.11.0`, `GET /api/memos` without auth may return `200` for public memos while `POST /api/memos` without auth returns `401`; assert `401` on unauthenticated `POST /api/memos` for cross-backend parity.
- Always stop and remove the `memos-e2e` Docker container (`docker rm -f memos-e2e`) and remove `.build/memos-e2e.env` in cleanup.

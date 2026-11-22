# Web Clipper wire contract

Web Clipper wire contract verifies that the browser extension payload layer (`extensions/web-clipper/memos_payload.mjs`) uploads clips exclusively to `/api/memos`, rejects legacy `/api/v1/memos`, attaches `<!-- rewind-context-v1 -->` comments, preserves verbatim markdown including fenced code blocks with blank lines, and handles `409 Conflict` retries idempotently without duplicating memos.

## Sub-features

- `clipper-wire-upload` posts `#rewind/pending #rewind/has-ctx #source/<platform>` memos to `/api/memos?memoId=<clipId>`.
- `clipper-context-comment` posts `<!-- rewind-context-v1 -->` to `/api/memos/<serverId>/comments?commentId=<clipId>-ctx`.
- `clipper-409-idempotent-retry` replays the same `clientClipId` after a `409 Conflict` and returns `status: "saved"` with zero duplicate memos.
- `clipper-legacy-v1-rejection` proves `/api/v1/memos` is rejected (`410` on `SQLiteMemosServer`, `404` or `410` on live Memos `26.11.0`) and never emitted by `memos_payload.mjs`.

## How to get to it (user POV)

- Highlight text in Chrome on ChatGPT, Claude, Gemini, or a web page and trigger the Coding Rewind Web Clipper save action.
- Exercise the exact production upload function `saveClipWithOutbox` in `extensions/web-clipper/memos_payload.mjs` via Node against a live Memos HTTP endpoint.

## Driving it with node and test_real_memos_e2e.py

Preconditions:

- Node 22+ is available on `PATH`.
- Either `Launch` and `Doctor` in `SKILL.md` succeeded, or `test_real_memos_e2e.py` is run in local SQLite mode.

- **Run Web Clipper extractor & payload unit suite.** Execute `node --test extensions/web-clipper/test_extractors.mjs`. All tests pass with exit code `0`.
- **Drive live upload and `409` idempotent replay.** Execute `python3 -B -m unittest verification.e2e.test_real_memos_e2e.RealMemosE2ETest.test_b_web_clipper_payload_upload_and_idempotent_409_retry -v`. Node invokes `saveClipWithOutbox` twice with the same `clipId`, receives `status: "saved"` both times, verifies `GET /api/memos/<serverId>` preserves the exact verbatim markdown (including literal `#rewind/pending` and blank lines inside a fenced code block), verifies `GET /api/memos/<serverId>/comments` contains `<!-- rewind-context-v1 -->`, and asserts only one memo exists across pagination.
- **Verify legacy route rejection and contract parity.** Execute `python3 -B -m unittest verification.e2e.test_real_memos_e2e.RealMemosE2ETest.test_a_legacy_v1_memos_route_rejected -v` and `python3 -B scripts/lint_invariants.py`. Both exit `0`, proving `/api/v1/memos` returns `410` (or `404` on live Memos) and `contracts/wire-contract.json` matches Swift, Python, and JS.

## Gotchas

- `normalizeMemosBaseUrl` only permits `https://` URLs or loopback `http://` URLs (`127.0.0.1`, `localhost`, `[::1]`). Non-loopback `http://` URLs return `status: "unconfigured"`.
- Both `clipId` and `${clipId}-ctx` must match `CLIP_ID_PATTERN` (`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$`, max 36 characters), so keep `clipId` at most 32 characters.
- Do not embed ordinary JS comments inside files under `extensions/` or `verification/`; `scripts/lint_invariants.py` enforces zero ordinary comments.

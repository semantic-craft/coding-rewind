# Clip CLI CRUD and MCP

Clip CLI CRUD and MCP lets a user or AI coding agent create a snippet, list it back, append an isolated follow-up note, archive it to `#rewind/synthesized`, and inspect available MCP tools over stdio JSON-RPC backed by a real Memos server.

## Sub-features

- `cli-create` creates a snippet memo via `/api/memos` with verbatim text preserved.
- `cli-list` lists active snippets from Memos and returns the created record.
- `cli-note` appends a `<!-- rewind-note-v1 -->` comment to a snippet without altering its verbatim text.
- `cli-archive` transitions the snippet to `synthesized` (`#rewind/synthesized`) and removes it from default active lists.
- `mcp-tools-list` starts `coding-rewind mcp`, completes JSON-RPC `initialize`, and advertises all registered read and write tools via `tools/list`.

## How to get to it (user POV)

- Run `coding-rewind create`, `coding-rewind list`, `coding-rewind get`, `coding-rewind note`, and `coding-rewind archive` in a terminal.
- Connect an MCP client (such as Antigravity or Codex) to `coding-rewind mcp` over stdin/stdout JSON-RPC 2.0.

## Driving it with coding-rewind CLI and sqlite_memos_server.py

Preconditions:

- `Launch` and `Doctor` in `SKILL.md` succeeded.
- `CODING_REWIND_BIN`, `CODING_REWIND_DATA_DIR`, `CODING_REWIND_MEMOS_URL`, `CODING_REWIND_MEMOS_TOKEN`, and `CODING_REWIND_AI_ACCESS=read_write` are exported.
- The isolated SQLite database starts empty.

- **Create snippet.** Save a code snippet with title and tags. Run `"${CODING_REWIND_BIN}" create --text "let answer = 42" --title "Verify CLI Create" --keywords "verify,cli" --source "cli" --json`. Exit code is `0` and stdout JSON contains `id`, `status: "ready"`, and `verbatimText: "let answer = 42"`. Capture `SNIPPET_ID` from `.id`.
- **List active snippets.** Confirm the snippet appears in user-facing list output. Run `"${CODING_REWIND_BIN}" list --window all --status active --json`. Exit code is `0` and stdout JSON `.snippets` contains the record with `id == SNIPPET_ID` and `dataOrigin == "remote"`.
- **Append follow-up note.** Attach a note to the snippet. Run `"${CODING_REWIND_BIN}" note "${SNIPPET_ID}" --text "Follow-up verification note" --author "verifier" --json`. Exit code is `0` and stdout JSON `.notes[].content` contains `"Follow-up verification note"`.
- **Confirm second read-only view.** Query the backend directly with `GET ${CODING_REWIND_MEMOS_URL}/api/memos/${SNIPPET_ID}/comments` using `Authorization: Bearer ${CODING_REWIND_MEMOS_TOKEN}`. HTTP status is `200` and the comment body contains `<!-- rewind-note-v1 -->` and `"Follow-up verification note"`.
- **Archive snippet.** Mark the snippet synthesized. Run `"${CODING_REWIND_BIN}" archive "${SNIPPET_ID}" --json`. Exit code is `0` and stdout JSON has `status: "synthesized"`.
- **Verify archived state in second view.** Run `"${CODING_REWIND_BIN}" list --window all --status active --json` and `GET ${CODING_REWIND_MEMOS_URL}/api/memos/${SNIPPET_ID}`. Active list omits `SNIPPET_ID`, and the raw memo first line contains `#rewind/synthesized` while preserving `"let answer = 42"`.
- **Drive MCP stdio server.** Pipe `initialize` and `tools/list` JSON-RPC 2.0 lines into `"${CODING_REWIND_BIN}" mcp`:
  `printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | "${CODING_REWIND_BIN}" mcp`.
  Exit code is `0`, line 1 returns `serverInfo.name == "coding-rewind"`, and line 2 returns `.result.tools` including `list_snippets`, `search_snippets`, `get_snippet`, `create_snippet`, `update_snippet_metadata`, `append_snippet_note`, and `archive_snippet`.
- **Proof.** Write the Doctor summary, CLI outputs, HTTP read-back, and MCP JSON-RPC responses to the proof JSON path outside `VERIFY_ROOT`, run `Cleanup`, and verify the proof JSON still exists afterward.

## Gotchas

- Mutating CLI commands (`create`, `note`, `archive`, `update`, `delete`, `place add`) fail with `aiWriteDisabled` unless `CODING_REWIND_AI_ACCESS=read_write` (or `config.json` allows writes).
- `coding-rewind list` defaults to `--window 72h` and `--status active`; pass `--status synthesized` or `--status all` to inspect archived snippets after `archive`.
- Do not write proof files inside `VERIFY_ROOT`; Cleanup deletes `VERIFY_ROOT`.

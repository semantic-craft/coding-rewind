#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"

DATA_DIR="${CODING_REWIND_DATA_DIR:-$HOME/Library/Application Support/CodingRewind}"
CONFIG_FILE="$DATA_DIR/config.json"

MEMOS_URL="${CODING_REWIND_MEMOS_URL:-}"
if [[ -z "$MEMOS_URL" && -f "$CONFIG_FILE" ]]; then
  MEMOS_URL="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("memos_url","").strip())' "$CONFIG_FILE" 2>/dev/null || true)"
fi
if [[ -z "$MEMOS_URL" ]]; then
  echo "coding-rewind: missing Memos URL (set CODING_REWIND_MEMOS_URL or memos_url in $CONFIG_FILE)" >&2
  exit 1
fi

if [[ "${CODING_REWIND_QA:-0}" == "1" ]]; then
  KEYCHAIN_SERVICE="com.codingrewind.memos.qa"
else
  KEYCHAIN_SERVICE="${CODING_REWIND_KEYCHAIN_SERVICE:-com.codingrewind.memos}"
fi

MEMOS_TOKEN="${CODING_REWIND_MEMOS_TOKEN:-}"
if [[ -z "$MEMOS_TOKEN" ]]; then
  MEMOS_TOKEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi
if [[ -z "$MEMOS_TOKEN" ]]; then
  echo "coding-rewind: missing Memos token (set CODING_REWIND_MEMOS_TOKEN or store Keychain service $KEYCHAIN_SERVICE)" >&2
  exit 1
fi

exec npx -y mcp-remote "${MEMOS_URL%/}/mcp" --header "Authorization: Bearer ${MEMOS_TOKEN}"

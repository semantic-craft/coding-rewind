#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

CONTENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER_CONFIG="${CONTENTS_DIR}/Resources/DeveloperCredentials.plist"
OP_EXECUTABLE="$(/usr/bin/plutil -extract op_executable raw -o - "${LAUNCHER_CONFIG}")"
CODING_REWIND_MEMOS_TOKEN="$(/usr/bin/plutil -extract token_reference raw -o - "${LAUNCHER_CONFIG}")"
export CODING_REWIND_MEMOS_TOKEN

case "${CODING_REWIND_MEMOS_TOKEN}" in
    op://?*/?*/?*) ;;
    *)
        echo "Coding Rewind: invalid developer credential reference" >&2
        exit 78
        ;;
esac

exec "${OP_EXECUTABLE}" run -- /bin/bash -c '
    case "${CODING_REWIND_MEMOS_TOKEN:-}" in
        ""|*[[:space:]]*|op://*)
            echo "Coding Rewind: credential injection failed; application was not started" >&2
            exit 78
            ;;
    esac
    exec "$@"
' coding-rewind-with-token "${CONTENTS_DIR}/MacOS/CodingRewindApp-native" "$@"

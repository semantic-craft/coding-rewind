#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_DIST="$(mktemp -d "${REPO_ROOT}/.build/qa-signing-check.XXXXXX")"
trap 'rm -rf "${TEST_DIST}"' EXIT

CODING_REWIND_QA=1 "${REPO_ROOT}/scripts/build-app-bundle.sh" "${TEST_DIST}" >/dev/null

APP_BUNDLE="${TEST_DIST}/CodingRewind.app"
CODESIGN_INFO="$(codesign -dvvv "${APP_BUNDLE}" 2>&1)"

if ! echo "${CODESIGN_INFO}" | grep -q "Signature=adhoc"; then
    echo "FAIL: Expected Signature=adhoc under CODING_REWIND_QA=1" >&2
    exit 1
fi

if ! echo "${CODESIGN_INFO}" | grep -q "Identifier=dev.codingrewind.app.qa"; then
    echo "FAIL: Expected Identifier=dev.codingrewind.app.qa under CODING_REWIND_QA=1" >&2
    exit 1
fi

LS_DUMP="$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump || true)"
if echo "${LS_DUMP}" | grep -F -q "${APP_BUNDLE}"; then
    echo "FAIL: ${APP_BUNDLE} remained registered in LaunchServices" >&2
    exit 1
fi

echo "PASS: bundle signing and LaunchServices unregistration verified."

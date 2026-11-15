#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

TEST_ROOT="$(mktemp -d "${REPO_ROOT}/.build/qa-signing-check.XXXXXX")"
TEST_DIST="${TEST_ROOT}/default-qa"
TEST_SKIP_DIST="${TEST_ROOT}/skip-creds-qa"
TEST_RELEASE_DIR="${TEST_ROOT}/release-out"

cleanup() {
    if [[ -x "${LSREGISTER}" ]]; then
        for app_candidate in "${TEST_DIST}/CodingRewind.app" "${TEST_SKIP_DIST}/CodingRewind.app"; do
            if [[ -d "${app_candidate}" ]]; then
                "${LSREGISTER}" -u "${app_candidate}" >/dev/null 2>&1 || true
            fi
        done
    fi
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

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

for locale_dir in zh-Hans.lproj en.lproj; do
    strings_file="${APP_BUNDLE}/Contents/Resources/${locale_dir}/InfoPlist.strings"
    if [[ ! -f "${strings_file}" ]]; then
        echo "FAIL: Missing localized InfoPlist.strings at ${strings_file}" >&2
        exit 1
    fi
    /usr/bin/plutil -lint "${strings_file}" >/dev/null
done

SKIP_DEVELOPER_CREDENTIALS=1 \
    CODING_REWIND_MEMOS_TOKEN_REFERENCE="op://Private/Test/item" \
    CODING_REWIND_QA=1 \
    "${REPO_ROOT}/scripts/build-app-bundle.sh" "${TEST_SKIP_DIST}" >/dev/null

if [[ -e "${TEST_SKIP_DIST}/CodingRewind.app/Contents/Resources/DeveloperCredentials.plist" ]]; then
    echo "FAIL: DeveloperCredentials.plist must be omitted when SKIP_DEVELOPER_CREDENTIALS=1" >&2
    exit 1
fi

CODING_REWIND_QA=1 "${REPO_ROOT}/scripts/package-release.sh" "${TEST_RELEASE_DIR}" >/dev/null

EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")"
MACOS_ARCHIVE="${TEST_RELEASE_DIR}/CodingRewind-v${EXPECTED_VERSION}-macos-arm64.zip"
CLIPPER_ARCHIVE="${TEST_RELEASE_DIR}/CodingRewind-WebClipper-v${EXPECTED_VERSION}.zip"
CHECKSUMS_FILE="${TEST_RELEASE_DIR}/SHA256SUMS.txt"

for artifact in "${MACOS_ARCHIVE}" "${CLIPPER_ARCHIVE}" "${CHECKSUMS_FILE}"; do
    if [[ ! -s "${artifact}" ]]; then
        echo "FAIL: Expected release artifact missing or empty: ${artifact}" >&2
        exit 1
    fi
done

(
    cd "${TEST_RELEASE_DIR}"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null
)

CLIPPER_ENTRIES="$(/usr/bin/unzip -Z1 "${CLIPPER_ARCHIVE}")"
if ! echo "${CLIPPER_ENTRIES}" | grep -Fxq "i18n.js"; then
    echo "FAIL: WebClipper archive is missing i18n.js" >&2
    exit 1
fi
if ! echo "${CLIPPER_ENTRIES}" | grep -Fxq "_locales/en/messages.json"; then
    echo "FAIL: WebClipper archive is missing _locales/en/messages.json" >&2
    exit 1
fi
if echo "${CLIPPER_ENTRIES}" | grep -Fq "test_extractors.mjs"; then
    echo "FAIL: WebClipper archive leaked test_extractors.mjs" >&2
    exit 1
fi

LS_DUMP="$("${LSREGISTER}" -dump || true)"
for forbidden_path in "${APP_BUNDLE}" "${TEST_SKIP_DIST}/CodingRewind.app" "${REPO_ROOT}/.build/release-stage."; do
    if echo "${LS_DUMP}" | grep -F -q "${forbidden_path}"; then
        echo "FAIL: ${forbidden_path} remained registered in LaunchServices" >&2
        exit 1
    fi
done

echo "PASS: bundle signing, localization resources, release packaging, and LaunchServices unregistration verified."

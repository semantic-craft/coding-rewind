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

for helper_name in coding-rewind-sidecar coding-rewind; do
    helper_path="${APP_BUNDLE}/Contents/Helpers/${helper_name}"
    if [[ ! -x "${helper_path}" ]]; then
        echo "FAIL: Missing executable helper at ${helper_path}" >&2
        exit 1
    fi
    if [[ "$(/usr/bin/file -b "${helper_path}")" != Mach-O* ]]; then
        echo "FAIL: Expected Mach-O helper at ${helper_path}" >&2
        exit 1
    fi
    codesign --verify --strict "${helper_path}"
done

if [[ -e "${APP_BUNDLE}/Contents/Helpers/memos-mcp-bridge.sh" ]]; then
    echo "FAIL: Retired memos-mcp-bridge.sh must not be bundled in Contents/Helpers" >&2
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
if [[ -z "${EXPECTED_VERSION}" ]]; then
    echo "FAIL: CFBundleShortVersionString is empty in ${APP_BUNDLE}/Contents/Info.plist" >&2
    exit 1
fi

HELPER_VERSION_OUT="$("${APP_BUNDLE}/Contents/Helpers/coding-rewind" --version)"
if [[ "${HELPER_VERSION_OUT}" != "coding-rewind ${EXPECTED_VERSION}" ]]; then
    echo "FAIL: coding-rewind --version (${HELPER_VERSION_OUT}) did not match Info.plist (${EXPECTED_VERSION})" >&2
    exit 1
fi

CLIPPER_MANIFEST_VERSION_NAME="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("version_name", ""))' "${REPO_ROOT}/extensions/web-clipper/manifest.json")"
if [[ "${CLIPPER_MANIFEST_VERSION_NAME}" != "${EXPECTED_VERSION}" ]]; then
    echo "FAIL: WebClipper manifest version_name (${CLIPPER_MANIFEST_VERSION_NAME}) did not match Info.plist (${EXPECTED_VERSION})" >&2
    exit 1
fi

if CODING_REWIND_RELEASE_VERSION="v9.9.9" CODING_REWIND_QA=1 "${REPO_ROOT}/scripts/package-release.sh" "${TEST_ROOT}/mismatch-out" >/dev/null 2>&1; then
    echo "FAIL: package-release.sh must fail when CODING_REWIND_RELEASE_VERSION mismatches Info.plist" >&2
    exit 1
fi
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

MACOS_ENTRIES="$(/usr/bin/unzip -Z1 "${MACOS_ARCHIVE}")"
for expected_entry in \
    "CodingRewind.app/Contents/Helpers/coding-rewind-sidecar" \
    "CodingRewind.app/Contents/Helpers/coding-rewind"; do
    if ! echo "${MACOS_ENTRIES}" | grep -Fxq "${expected_entry}"; then
        echo "FAIL: macOS release archive is missing ${expected_entry}" >&2
        exit 1
    fi
done
if echo "${MACOS_ENTRIES}" | grep -Fq "memos-mcp-bridge.sh"; then
    echo "FAIL: macOS release archive leaked retired memos-mcp-bridge.sh" >&2
    exit 1
fi

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

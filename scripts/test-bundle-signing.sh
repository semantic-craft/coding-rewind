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

STUB_ROOT="${TEST_ROOT}/notary-stubs"
STUB_BIN="${STUB_ROOT}/bin"
FAKE_HOME="${STUB_ROOT}/fake-home"
mkdir -p "${STUB_BIN}" "${FAKE_HOME}/.local/bin"

SANITIZED_PATH="$(python3 -c 'import os; home = os.path.expanduser("~"); entries = [p for p in os.environ.get("PATH", "").split(":") if p and not p.startswith(home + "/.local/bin")]; print(":".join(entries))')"
STUB_PATH="${STUB_BIN}:${SANITIZED_PATH}"

cat > "${STUB_BIN}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${CODESIGN_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${CODESIGN_LOG}"
fi
if [[ "${1:-}" == "--verify" ]]; then
    exit 0
fi
if [[ "${CODESIGN_REQUIRE_RUNTIME_TS:-0}" == "1" ]]; then
    case " $* " in
        *" --options runtime "*) ;;
        *)
            echo "stub codesign: missing --options runtime in: $*" >&2
            exit 1
            ;;
    esac
    case " $* " in
        *" --timestamp "*) ;;
        *)
            echo "stub codesign: missing --timestamp in: $*" >&2
            exit 1
            ;;
    esac
    case " $* " in
        *"--timestamp=none"*)
            echo "stub codesign: forbidden --timestamp=none in: $*" >&2
            exit 1
            ;;
    esac
fi
exit 0
EOF
chmod +x "${STUB_BIN}/codesign"

cat > "${FAKE_HOME}/.local/bin/macos-notary-profile" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${NOTARY_PROFILE_STUB_FAIL:-0}" == "1" ]]; then
    echo "stub macos-notary-profile: unavailable" >&2
    exit 1
fi
printf '%s\n' "${STUB_PROFILE_NAME:-ci-release-profile}"
EOF
chmod +x "${FAKE_HOME}/.local/bin/macos-notary-profile"

cat > "${FAKE_HOME}/.local/bin/macos-notary" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${NOTARY_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${NOTARY_LOG}"
fi
if [[ "${1:-}" != "submit" ]]; then
    echo "stub macos-notary: expected submit subcommand, got $*" >&2
    exit 1
fi
TARGET_APP="${2:-}"
shift 2 || true
PROFILE_VAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE_VAL="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [[ -z "${TARGET_APP}" || ! -d "${TARGET_APP}" ]]; then
    echo "stub macos-notary: missing target app ${TARGET_APP}" >&2
    exit 1
fi
if [[ -z "${PROFILE_VAL}" ]]; then
    echo "stub macos-notary: missing --profile" >&2
    exit 1
fi
if [[ "${NOTARY_STUB_FAIL:-0}" == "1" ]]; then
    echo "stub macos-notary: submission rejected" >&2
    exit 1
fi
mkdir -p "${TARGET_APP}/Contents/_CodeSignature"
printf '%s\n' "${PROFILE_VAL}" > "${TARGET_APP}/Contents/_CodeSignature/stapled-ticket.stub"
EOF
chmod +x "${FAKE_HOME}/.local/bin/macos-notary"

CODESIGN_LOG_DEV="${TEST_ROOT}/codesign-devid.log"
DEV_SIGN_DIST="${TEST_ROOT}/dev-id-dist"
HOME="${FAKE_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_LOG="${CODESIGN_LOG_DEV}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    SKIP_DEVELOPER_CREDENTIALS=1 \
    "${REPO_ROOT}/scripts/build-app-bundle.sh" --release "${DEV_SIGN_DIST}" >/dev/null

python3 - "${CODESIGN_LOG_DEV}" <<'PY'
import pathlib
import sys

lines = [ln for ln in pathlib.Path(sys.argv[1]).read_text().splitlines() if ln.strip()]
sign_lines = [ln for ln in lines if "--force" in ln]
if len(sign_lines) < 3:
    sys.exit(f"FAIL: expected at least 3 signing invocations, got {len(sign_lines)}")
for ln in sign_lines:
    if "--options runtime" not in ln or "--timestamp" not in ln or "--timestamp=none" in ln:
        sys.exit(f"FAIL: signing line missing hardened runtime or timestamp: {ln}")
    if " --sign - " in f" {ln} ":
        sys.exit(f"FAIL: ad-hoc signing used in Developer ID release mode: {ln}")
if "Contents/Helpers/" not in sign_lines[0] or "Contents/Helpers/" not in sign_lines[1]:
    sys.exit(f"FAIL: expected helpers signed before bundle: {sign_lines}")
if not sign_lines[2].rstrip().endswith("CodingRewind.app"):
    sys.exit(f"FAIL: expected CodingRewind.app signed last: {sign_lines}")
PY

if CODING_REWIND_QA=1 "${REPO_ROOT}/scripts/build-app-bundle.sh" --release "${TEST_ROOT}/qa-release-fail" >/dev/null 2>&1; then
    echo "FAIL: build-app-bundle.sh --release must reject CODING_REWIND_QA=1" >&2
    exit 1
fi

if CODING_REWIND_SIGN_IDENTITY="-" "${REPO_ROOT}/scripts/build-app-bundle.sh" --release "${TEST_ROOT}/adhoc-release-fail" >/dev/null 2>&1; then
    echo "FAIL: build-app-bundle.sh --release must reject ad-hoc identity '-'" >&2
    exit 1
fi

NOTARY_LOG_PRIMARY="${TEST_ROOT}/notary-primary.log"
NOTARIZED_OUT="${TEST_ROOT}/notarized-release"
HOME="${FAKE_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    NOTARY_LOG="${NOTARY_LOG_PRIMARY}" \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    "${REPO_ROOT}/scripts/package-release.sh" --notarize "${NOTARIZED_OUT}" >/dev/null

if ! grep -Fq "submit " "${NOTARY_LOG_PRIMARY}" || ! grep -Fq -- "--profile ci-release-profile" "${NOTARY_LOG_PRIMARY}"; then
    echo "FAIL: package-release.sh --notarize did not invoke macos-notary with resolved profile" >&2
    exit 1
fi

NOTARIZED_MACOS_ARCHIVE="${NOTARIZED_OUT}/CodingRewind-v${EXPECTED_VERSION}-macos-arm64.zip"
if ! /usr/bin/unzip -Z1 "${NOTARIZED_MACOS_ARCHIVE}" | grep -Fxq "CodingRewind.app/Contents/_CodeSignature/stapled-ticket.stub"; then
    echo "FAIL: notarized archive is missing stapled ticket from pre-zip stapling" >&2
    exit 1
fi
(
    cd "${NOTARIZED_OUT}"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null
)

NOTARY_LOG_ENV="${TEST_ROOT}/notary-env.log"
HOME="${FAKE_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    NOTARY_LOG="${NOTARY_LOG_ENV}" \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    CODING_REWIND_NOTARIZE=1 \
    CODING_REWIND_NOTARY_PROFILE="override-profile" \
    NOTARY_PROFILE="secondary-profile" \
    "${REPO_ROOT}/scripts/package-release.sh" "${TEST_ROOT}/notarized-env" >/dev/null

if ! grep -Fq -- "--profile override-profile" "${NOTARY_LOG_ENV}"; then
    echo "FAIL: CODING_REWIND_NOTARY_PROFILE must take precedence over NOTARY_PROFILE and macos-notary-profile" >&2
    exit 1
fi

NOTARY_LOG_SECONDARY="${TEST_ROOT}/notary-secondary.log"
HOME="${FAKE_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    NOTARY_LOG="${NOTARY_LOG_SECONDARY}" \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    CODING_REWIND_NOTARIZE=1 \
    NOTARY_PROFILE="secondary-profile" \
    "${REPO_ROOT}/scripts/package-release.sh" "${TEST_ROOT}/notarized-secondary" >/dev/null

if ! grep -Fq -- "--profile secondary-profile" "${NOTARY_LOG_SECONDARY}"; then
    echo "FAIL: NOTARY_PROFILE must take precedence over macos-notary-profile" >&2
    exit 1
fi

REJECTED_OUT="${TEST_ROOT}/notary-rejected"
if HOME="${FAKE_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    NOTARY_STUB_FAIL=1 \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    "${REPO_ROOT}/scripts/package-release.sh" --notarize "${REJECTED_OUT}" >/dev/null 2>&1; then
    echo "FAIL: package-release.sh --notarize must fail when notarization rejects" >&2
    exit 1
fi
if [[ -e "${REJECTED_OUT}/CodingRewind-v${EXPECTED_VERSION}-macos-arm64.zip" || -e "${REJECTED_OUT}/SHA256SUMS.txt" ]]; then
    echo "FAIL: rejected notarization must not leave release zip or SHA256SUMS.txt behind" >&2
    exit 1
fi

EMPTY_HOME="${STUB_ROOT}/empty-home"
mkdir -p "${EMPTY_HOME}"
if HOME="${EMPTY_HOME}" \
    PATH="${STUB_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    "${REPO_ROOT}/scripts/package-release.sh" --notarize "${TEST_ROOT}/missing-profile-out" >/dev/null 2>&1; then
    echo "FAIL: package-release.sh --notarize must fail when no notary profile can be resolved" >&2
    exit 1
fi

FALLBACK_BIN="${STUB_ROOT}/fallback-bin"
mkdir -p "${FALLBACK_BIN}"
cp "${STUB_BIN}/codesign" "${FALLBACK_BIN}/codesign"
FALLBACK_LOG="${TEST_ROOT}/fallback-notarization.log"
cat > "${FALLBACK_BIN}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "${FALLBACK_LOG}"
case "${1:-} ${2:-}" in
    "notarytool submit")
        case " $* " in
            *" --keychain-profile fallback-profile "*) ;;
            *)
                echo "stub xcrun: missing --keychain-profile fallback-profile" >&2
                exit 1
                ;;
        esac
        ;;
    "stapler staple")
        mkdir -p "${3}/Contents/_CodeSignature"
        printf 'fallback-stapled\n' > "${3}/Contents/_CodeSignature/stapled-ticket.stub"
        ;;
    "stapler validate")
        [[ -f "${3}/Contents/_CodeSignature/stapled-ticket.stub" ]]
        ;;
    *)
        echo "stub xcrun: unexpected invocation $*" >&2
        exit 1
        ;;
esac
EOF
cat > "${FALLBACK_BIN}/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >> "${FALLBACK_LOG}"
echo "${5}: accepted"
echo "source=Notarized Developer ID"
EOF
chmod +x "${FALLBACK_BIN}/xcrun" "${FALLBACK_BIN}/spctl"

HOME="${EMPTY_HOME}" \
    PATH="${FALLBACK_BIN}:${SANITIZED_PATH}" \
    CODESIGN_REQUIRE_RUNTIME_TS=1 \
    FALLBACK_LOG="${FALLBACK_LOG}" \
    CODING_REWIND_SIGN_IDENTITY="Developer ID Application: Test Signer" \
    CODING_REWIND_NOTARIZE=1 \
    CODING_REWIND_NOTARY_PROFILE="fallback-profile" \
    "${REPO_ROOT}/scripts/package-release.sh" "${TEST_ROOT}/fallback-out" >/dev/null

if ! grep -Fq "xcrun notarytool submit" "${FALLBACK_LOG}" || ! grep -Fq "xcrun stapler staple" "${FALLBACK_LOG}" || ! grep -Fq "spctl --assess --type execute --verbose=4" "${FALLBACK_LOG}"; then
    echo "FAIL: fallback notarization chain did not execute notarytool + stapler + spctl" >&2
    exit 1
fi
if ! /usr/bin/unzip -Z1 "${TEST_ROOT}/fallback-out/CodingRewind-v${EXPECTED_VERSION}-macos-arm64.zip" | grep -Fxq "CodingRewind.app/Contents/_CodeSignature/stapled-ticket.stub"; then
    echo "FAIL: fallback notarized archive missing pre-zip stapled ticket" >&2
    exit 1
fi

DRY_CI_OUT="${TEST_ROOT}/dry-ci-out"
SKIP_DEVELOPER_CREDENTIALS=1 \
    HOME="${EMPTY_HOME}" \
    PATH="${STUB_PATH}" \
    CODING_REWIND_SIGN_IDENTITY="-" \
    "${REPO_ROOT}/scripts/package-release.sh" "${DRY_CI_OUT}" >/dev/null
if [[ ! -s "${DRY_CI_OUT}/CodingRewind-v${EXPECTED_VERSION}-macos-arm64.zip" ]]; then
    echo "FAIL: dry CI SKIP_DEVELOPER_CREDENTIALS=1 path failed to emit macOS release zip" >&2
    exit 1
fi

echo "PASS: bundle signing, localization resources, release packaging, notarization, and LaunchServices unregistration verified."

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVED_REPO_ROOT="$(cd "${REPO_ROOT}" && pwd -P)"
RAW_OUT_DIR="${OUT_DIR:-${1:-${REPO_ROOT}/.build/release-artifacts}}"

FORBIDDEN_TMP="/tmp"
FORBIDDEN_PRIVATE_TMP="/private/tmp"
FORBIDDEN_DIST="${REPO_ROOT}/dist"
FORBIDDEN_RESOLVED_DIST="${RESOLVED_REPO_ROOT}/dist"

reject_forbidden_dir() {
    local candidate="$1"
    local label="$2"
    case "${candidate}" in
        "${FORBIDDEN_TMP}"|"${FORBIDDEN_TMP}"/*|"${FORBIDDEN_PRIVATE_TMP}"|"${FORBIDDEN_PRIVATE_TMP}"/*|"${FORBIDDEN_DIST}"|"${FORBIDDEN_DIST}"/*|"${FORBIDDEN_RESOLVED_DIST}"|"${FORBIDDEN_RESOLVED_DIST}"/*)
            echo "Error: ${label} must not point into temporary or dist directory (${candidate})" >&2
            exit 1
            ;;
    esac
}

reject_forbidden_dir "${RAW_OUT_DIR}" "OUT_DIR"

mkdir -p "${RAW_OUT_DIR}"
RESOLVED_OUT_DIR="$(cd "${RAW_OUT_DIR}" && pwd -P)"
reject_forbidden_dir "${RESOLVED_OUT_DIR}" "resolved OUT_DIR"

mkdir -p "${REPO_ROOT}/.build"
STAGE_DIR="$(mktemp -d "${REPO_ROOT}/.build/release-stage.XXXXXX")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
    if [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR}" ]]; then
        if [[ -x "${LSREGISTER}" && -d "${STAGE_DIR}/CodingRewind.app" ]]; then
            "${LSREGISTER}" -u "${STAGE_DIR}/CodingRewind.app" >/dev/null 2>&1 || true
        fi
        rm -rf "${STAGE_DIR}"
    fi
}
trap cleanup EXIT

SKIP_DEVELOPER_CREDENTIALS=1 DIST_DIR="${STAGE_DIR}" "${REPO_ROOT}/scripts/build-app-bundle.sh"

STAGED_APP="${STAGE_DIR}/CodingRewind.app"
if [[ ! -d "${STAGED_APP}" ]]; then
    echo "Error: staged app bundle was not created at ${STAGED_APP}" >&2
    exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${STAGED_APP}/Contents/Info.plist")"
if [[ -z "${PLIST_VERSION}" ]]; then
    echo "Error: CFBundleShortVersionString could not be read from ${STAGED_APP}/Contents/Info.plist" >&2
    exit 1
fi

if [[ -n "${CODING_REWIND_RELEASE_VERSION:-}" ]]; then
    VERSION="${CODING_REWIND_RELEASE_VERSION#v}"
    VERSION="${VERSION#V}"
    if [[ -z "${VERSION}" || "${VERSION}" != "${PLIST_VERSION}" ]]; then
        echo "Error: CODING_REWIND_RELEASE_VERSION (${CODING_REWIND_RELEASE_VERSION}) does not match Info.plist CFBundleShortVersionString (${PLIST_VERSION})" >&2
        exit 1
    fi
else
    VERSION="${PLIST_VERSION}"
fi

CLI_VERSION_OUTPUT="$("${STAGED_APP}/Contents/Helpers/coding-rewind" --version)"
if [[ "${CLI_VERSION_OUTPUT}" != "coding-rewind ${PLIST_VERSION}" ]]; then
    echo "Error: coding-rewind --version (${CLI_VERSION_OUTPUT}) does not match Info.plist CFBundleShortVersionString (${PLIST_VERSION})" >&2
    exit 1
fi

CLIPPER_VERSION_NAME="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("version_name", ""))' "${REPO_ROOT}/extensions/web-clipper/manifest.json")"
if [[ "${CLIPPER_VERSION_NAME}" != "${PLIST_VERSION}" ]]; then
    echo "Error: extensions/web-clipper/manifest.json version_name (${CLIPPER_VERSION_NAME}) does not match Info.plist CFBundleShortVersionString (${PLIST_VERSION})" >&2
    exit 1
fi

MACOS_ZIP="CodingRewind-v${VERSION}-macos-arm64.zip"
CLIPPER_ZIP="CodingRewind-WebClipper-v${VERSION}.zip"

rm -f "${RESOLVED_OUT_DIR}/${MACOS_ZIP}" "${RESOLVED_OUT_DIR}/${CLIPPER_ZIP}" "${RESOLVED_OUT_DIR}/SHA256SUMS.txt"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${STAGED_APP}" "${RESOLVED_OUT_DIR}/${MACOS_ZIP}"

CLIPPER_SRC="${REPO_ROOT}/extensions/web-clipper"
CLIPPER_STAGE="${STAGE_DIR}/web-clipper-stage"
mkdir -p "${CLIPPER_STAGE}"

for runtime_file in manifest.json i18n.js extractors.mjs memos_payload.mjs content.js background.js options.html options.js; do
    install -m 0644 "${CLIPPER_SRC}/${runtime_file}" "${CLIPPER_STAGE}/${runtime_file}"
done
cp -R "${CLIPPER_SRC}/_locales" "${CLIPPER_STAGE}/_locales"
cp -R "${CLIPPER_SRC}/icons" "${CLIPPER_STAGE}/icons"
find "${CLIPPER_STAGE}" \( -name 'test_*.mjs' -o -name '.DS_Store' \) -delete

/usr/bin/ditto -c -k --norsrc "${CLIPPER_STAGE}" "${RESOLVED_OUT_DIR}/${CLIPPER_ZIP}"

(
    cd "${RESOLVED_OUT_DIR}"
    /usr/bin/shasum -a 256 "${MACOS_ZIP}" "${CLIPPER_ZIP}" > SHA256SUMS.txt
)

echo "Packaged release artifacts in ${RESOLVED_OUT_DIR}"

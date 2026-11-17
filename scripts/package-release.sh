#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVED_REPO_ROOT="$(cd "${REPO_ROOT}" && pwd -P)"
CALLER_SKIP_DEV_CREDS="${SKIP_DEVELOPER_CREDENTIALS:-}"
NOTARIZE_FLAG=""
POSITIONAL_OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            if [[ "${NOTARIZE_FLAG}" == "0" ]]; then
                echo "Error: cannot combine --notarize with --skip-notarize" >&2
                exit 1
            fi
            NOTARIZE_FLAG="1"
            shift
            ;;
        --skip-notarize)
            if [[ "${NOTARIZE_FLAG}" == "1" ]]; then
                echo "Error: cannot combine --notarize with --skip-notarize" >&2
                exit 1
            fi
            NOTARIZE_FLAG="0"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option $1" >&2
            exit 1
            ;;
        *)
            if [[ -n "${POSITIONAL_OUT_DIR}" ]]; then
                echo "Error: unexpected argument $1" >&2
                exit 1
            fi
            POSITIONAL_OUT_DIR="$1"
            shift
            ;;
    esac
done

if [[ $# -gt 0 ]]; then
    if [[ -n "${POSITIONAL_OUT_DIR}" || $# -gt 1 ]]; then
        echo "Error: unexpected extra arguments: $*" >&2
        exit 1
    fi
    POSITIONAL_OUT_DIR="$1"
fi

if [[ -n "${NOTARIZE_FLAG}" ]]; then
    SHOULD_NOTARIZE="${NOTARIZE_FLAG}"
elif [[ -n "${CODING_REWIND_NOTARIZE:-}" ]]; then
    SHOULD_NOTARIZE="${CODING_REWIND_NOTARIZE}"
elif [[ "${CODING_REWIND_QA:-0}" == "1" || "${CALLER_SKIP_DEV_CREDS}" == "1" ]]; then
    SHOULD_NOTARIZE="0"
else
    SHOULD_NOTARIZE="1"
fi

if [[ "${SHOULD_NOTARIZE}" == "1" && "${CODING_REWIND_QA:-0}" == "1" ]]; then
    echo "Error: notarization cannot be enabled with CODING_REWIND_QA=1" >&2
    exit 1
fi

RAW_OUT_DIR="${OUT_DIR:-${POSITIONAL_OUT_DIR:-${REPO_ROOT}/.build/release-artifacts}}"

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

resolve_notary_profile() {
    if [[ -n "${CODING_REWIND_NOTARY_PROFILE:-}" ]]; then
        printf '%s\n' "${CODING_REWIND_NOTARY_PROFILE}"
        return 0
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        printf '%s\n' "${NOTARY_PROFILE}"
        return 0
    fi
    local profile_tool=""
    if profile_tool="$(command -v macos-notary-profile 2>/dev/null)" && [[ -x "${profile_tool}" ]]; then
        :
    elif [[ -x "${HOME}/.local/bin/macos-notary-profile" ]]; then
        profile_tool="${HOME}/.local/bin/macos-notary-profile"
    else
        echo "Error: cannot resolve notary profile; set CODING_REWIND_NOTARY_PROFILE or NOTARY_PROFILE, or install macos-notary-profile" >&2
        return 1
    fi
    local resolved=""
    resolved="$("${profile_tool}")"
    if [[ -z "${resolved}" ]]; then
        echo "Error: ${profile_tool} returned an empty notary profile" >&2
        return 1
    fi
    printf '%s\n' "${resolved}"
}

notarize_app() {
    local app_path="$1"
    local profile="$2"
    local notary_tool=""
    if notary_tool="$(command -v macos-notary 2>/dev/null)" && [[ -x "${notary_tool}" ]]; then
        TMPDIR="${STAGE_DIR}" "${notary_tool}" submit "${app_path}" --profile "${profile}"
        return $?
    elif [[ -x "${HOME}/.local/bin/macos-notary" ]]; then
        TMPDIR="${STAGE_DIR}" "${HOME}/.local/bin/macos-notary" submit "${app_path}" --profile "${profile}"
        return $?
    fi

    local submit_zip="${STAGE_DIR}/notary-submit.zip"
    rm -f "${submit_zip}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${submit_zip}"
    xcrun notarytool submit "${submit_zip}" --keychain-profile "${profile}" --wait
    rm -f "${submit_zip}"
    xcrun stapler staple "${app_path}"
    xcrun stapler validate "${app_path}"
    local spctl_out=""
    spctl_out="$(spctl --assess --type execute --verbose=4 "${app_path}" 2>&1)"
    echo "${spctl_out}"
    if ! echo "${spctl_out}" | grep -q "Notarized Developer ID"; then
        echo "Error: Gatekeeper spctl assessment did not report 'Notarized Developer ID'" >&2
        return 1
    fi
}

NOTARY_PROFILE_RESOLVED=""
BUILD_ARGS=()
if [[ "${SHOULD_NOTARIZE}" == "1" ]]; then
    NOTARY_PROFILE_RESOLVED="$(resolve_notary_profile)"
    BUILD_ARGS+=(--release)
fi

SKIP_DEVELOPER_CREDENTIALS=1 DIST_DIR="${STAGE_DIR}" "${REPO_ROOT}/scripts/build-app-bundle.sh" "${BUILD_ARGS[@]}"

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

if [[ "${SHOULD_NOTARIZE}" == "1" ]]; then
    notarize_app "${STAGED_APP}" "${NOTARY_PROFILE_RESOLVED}"
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

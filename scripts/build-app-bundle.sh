#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_SIGNING="${CODING_REWIND_RELEASE_SIGNING:-${CODING_REWIND_NOTARIZE:-0}}"
POSITIONAL_DIST_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release|--notarize)
            RELEASE_SIGNING=1
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
            if [[ -n "${POSITIONAL_DIST_DIR}" ]]; then
                echo "Error: unexpected argument $1" >&2
                exit 1
            fi
            POSITIONAL_DIST_DIR="$1"
            shift
            ;;
    esac
done

if [[ $# -gt 0 ]]; then
    if [[ -n "${POSITIONAL_DIST_DIR}" || $# -gt 1 ]]; then
        echo "Error: unexpected extra arguments: $*" >&2
        exit 1
    fi
    POSITIONAL_DIST_DIR="$1"
fi

if [[ "${RELEASE_SIGNING}" == "1" && "${CODING_REWIND_QA:-0}" == "1" ]]; then
    echo "Error: --release/--notarize cannot be combined with CODING_REWIND_QA=1" >&2
    exit 1
fi

RAW_DIST_DIR="${DIST_DIR:-${POSITIONAL_DIST_DIR:-${REPO_ROOT}/.build}}"
MEMOS_TOKEN_REFERENCE="${CODING_REWIND_MEMOS_TOKEN_REFERENCE:-}"
SKIP_DEV_CREDENTIALS="${SKIP_DEVELOPER_CREDENTIALS:-0}"

if [[ "${SKIP_DEV_CREDENTIALS}" != "1" && -n "${MEMOS_TOKEN_REFERENCE}" ]]; then
    case "${MEMOS_TOKEN_REFERENCE}" in
        op://?*/?*/?*) ;;
        *)
            echo "Error: CODING_REWIND_MEMOS_TOKEN_REFERENCE must be an op secret reference" >&2
            exit 1
            ;;
    esac
    OP_EXECUTABLE="${CODING_REWIND_OP_BIN:-$(command -v op || true)}"
    if [[ "${OP_EXECUTABLE}" != /* || ! -x "${OP_EXECUTABLE}" ]]; then
        echo "Error: an executable absolute op path is required for developer credentials" >&2
        exit 1
    fi
fi

case "${RAW_DIST_DIR}" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*)
        echo "Error: DIST_DIR must not point into /tmp or /private/tmp (${RAW_DIST_DIR})" >&2
        exit 1
        ;;
esac

mkdir -p "${RAW_DIST_DIR}"
RESOLVED_DIST_DIR="$(cd "${RAW_DIST_DIR}" && pwd -P)"
case "${RESOLVED_DIST_DIR}" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*)
        echo "Error: resolved DIST_DIR must not point into /tmp or /private/tmp (${RESOLVED_DIST_DIR})" >&2
        exit 1
        ;;
esac

cd "${REPO_ROOT}"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP_BUNDLE="${RESOLVED_DIST_DIR}/CodingRewind.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICONSET_DIR="${RESOLVED_DIST_DIR}/AppIcon.iconset"

rm -rf "${APP_BUNDLE}" "${ICONSET_DIR}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"

swift "${REPO_ROOT}/scripts/generate-app-icons.swift" "${ICONSET_DIR}"
swift "${REPO_ROOT}/scripts/verify-app-icon.swift" "${ICONSET_DIR}" "${REPO_ROOT}/Resources"
/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

install -m 0644 "${REPO_ROOT}/Resources/MenuBarIcon.png" "${RESOURCES_DIR}/MenuBarIcon.png"
install -m 0644 "${REPO_ROOT}/Resources/MenuBarIcon@2x.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"

for lproj_dir in "${REPO_ROOT}"/Resources/*.lproj; do
    [[ -d "${lproj_dir}" ]] || continue
    dest_lproj="${RESOURCES_DIR}/$(basename "${lproj_dir}")"
    mkdir -p "${dest_lproj}"
    chmod 0755 "${dest_lproj}"
    if [[ -f "${lproj_dir}/InfoPlist.strings" ]]; then
        install -m 0644 "${lproj_dir}/InfoPlist.strings" "${dest_lproj}/InfoPlist.strings"
    fi
done

for resource_bundle in "${BIN_DIR}"/*.bundle; do
    [[ -d "${resource_bundle}" ]] || continue
    cp -R "${resource_bundle}" "${RESOURCES_DIR}/"
done
if [[ ! -d "${RESOURCES_DIR}/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]; then
    echo "Error: KeyboardShortcuts resource bundle is missing" >&2
    exit 1
fi
install -m 0644 "${REPO_ROOT}/Vendor/KeyboardShortcuts/license" "${RESOURCES_DIR}/KeyboardShortcuts-LICENSE.txt"

DSH_PLUGIN_SRC="${REPO_ROOT}/dsh-plugin/coding-rewind-dsh"
DSH_PLUGIN_DST="${RESOURCES_DIR}/dsh-plugin/coding-rewind-dsh"
if [[ ! -f "${DSH_PLUGIN_SRC}/package.json" ]]; then
    echo "Error: DSH plugin source is missing at ${DSH_PLUGIN_SRC}" >&2
    exit 1
fi
mkdir -p "${DSH_PLUGIN_DST}"
install -m 0644 "${DSH_PLUGIN_SRC}/package.json" "${DSH_PLUGIN_DST}/package.json"
install -m 0644 "${DSH_PLUGIN_SRC}/cordis.patch.yml" "${DSH_PLUGIN_DST}/cordis.patch.yml"
install -m 0644 "${DSH_PLUGIN_SRC}/client.js" "${DSH_PLUGIN_DST}/client.js"
if [[ -d "${DSH_PLUGIN_SRC}/lib" ]]; then
    cp -R "${DSH_PLUGIN_SRC}/lib" "${DSH_PLUGIN_DST}/lib"
    find "${DSH_PLUGIN_DST}/lib" -type d -exec chmod 0755 {} +
    find "${DSH_PLUGIN_DST}/lib" -type f -exec chmod 0644 {} +
fi
if [[ ! -f "${DSH_PLUGIN_DST}/package.json" ]]; then
    echo "Error: bundled DSH plugin package.json is missing" >&2
    exit 1
fi

install -m 0755 "${BIN_DIR}/CodingRewindApp" "${MACOS_DIR}/CodingRewindApp"
if [[ "${SKIP_DEV_CREDENTIALS}" != "1" && -n "${MEMOS_TOKEN_REFERENCE}" ]]; then
    LAUNCHER_CONFIG="${RESOURCES_DIR}/DeveloperCredentials.plist"
    /usr/bin/plutil -create xml1 "${LAUNCHER_CONFIG}"
    /usr/bin/plutil -insert token_reference -string "${MEMOS_TOKEN_REFERENCE}" "${LAUNCHER_CONFIG}"
    /usr/bin/plutil -insert op_executable -string "${OP_EXECUTABLE}" "${LAUNCHER_CONFIG}"
    chmod 0600 "${LAUNCHER_CONFIG}"
fi
install -m 0755 "${BIN_DIR}/coding-rewind-sidecar" "${HELPERS_DIR}/coding-rewind-sidecar"
install -m 0755 "${BIN_DIR}/coding-rewind" "${HELPERS_DIR}/coding-rewind"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>CodingRewindApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.codingrewind.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CodingRewind</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.0</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Coding Rewind 读取浏览器标签链接，为你选中的聊天片段保存会话出处。</string>
</dict>
</plist>
PLIST

SIGN_MODE=""
if [[ "${CODING_REWIND_QA:-0}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.codingrewind.app.qa" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Coding Rewind QA" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Coding Rewind QA" "${CONTENTS_DIR}/Info.plist"
    for strings_file in "${RESOURCES_DIR}"/*.lproj/InfoPlist.strings; do
        [[ -f "${strings_file}" ]] || continue
        /usr/bin/plutil -convert xml1 "${strings_file}"
        /usr/bin/plutil -replace CFBundleDisplayName -string "Coding Rewind QA" "${strings_file}"
        /usr/bin/plutil -replace CFBundleName -string "Coding Rewind QA" "${strings_file}"
    done
    SIGN_IDENTITY="-"
    SIGN_MODE="adhoc"
elif [[ -n "${CODING_REWIND_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${CODING_REWIND_SIGN_IDENTITY}"
    if [[ "${SIGN_IDENTITY}" == "-" ]]; then
        if [[ "${RELEASE_SIGNING}" == "1" ]]; then
            echo "Error: release/notarized signing cannot use ad-hoc identity '-'" >&2
            exit 1
        fi
        SIGN_MODE="adhoc"
    elif [[ "${RELEASE_SIGNING}" == "1" ]]; then
        case "${SIGN_IDENTITY}" in
            "Apple Development"*|"iPhone "*)
                echo "Error: release/notarized signing requires Developer ID Application identity (got ${SIGN_IDENTITY})" >&2
                exit 1
                ;;
        esac
        SIGN_MODE="developer_id"
    elif [[ "${SIGN_IDENTITY}" == "Developer ID Application"* ]]; then
        SIGN_MODE="developer_id"
    else
        SECURITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
        if echo "${SECURITY_OUTPUT}" | grep -F -- "${SIGN_IDENTITY}" | grep -q 'Developer ID Application:'; then
            SIGN_MODE="developer_id"
        else
            SIGN_MODE="development"
        fi
    fi
else
    SECURITY_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
    DEV_ID="$(echo "${SECURITY_OUTPUT}" | grep -E '[0-9A-Fa-f]{40} "Developer ID Application:' | grep -oE '[0-9A-Fa-f]{40}' | head -n 1 || true)"
    APPLE_DEV="$(echo "${SECURITY_OUTPUT}" | grep -E '[0-9A-Fa-f]{40} "Apple Development:' | grep -oE '[0-9A-Fa-f]{40}' | head -n 1 || true)"
    if [[ -n "${DEV_ID}" ]]; then
        SIGN_IDENTITY="${DEV_ID}"
        SIGN_MODE="developer_id"
    elif [[ "${RELEASE_SIGNING}" == "1" ]]; then
        echo "Error: release/notarized signing requires a valid Developer ID Application certificate" >&2
        exit 1
    elif [[ -n "${APPLE_DEV}" ]]; then
        SIGN_IDENTITY="${APPLE_DEV}"
        SIGN_MODE="development"
    else
        SIGN_IDENTITY="-"
        SIGN_MODE="adhoc"
    fi
fi

sign_target() {
    local target="$1"
    case "${SIGN_MODE}" in
        adhoc)
            codesign --force --sign - "${target}"
            ;;
        development)
            codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${target}"
            ;;
        developer_id)
            codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${target}"
            ;;
        *)
            echo "Error: unsupported signing mode ${SIGN_MODE}" >&2
            exit 1
            ;;
    esac
}

for helper in "${HELPERS_DIR}"/*; do
    [[ -f "${helper}" ]] || continue
    sign_target "${helper}"
done

sign_target "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"
if [[ "$(/usr/bin/file -b "${MACOS_DIR}/CodingRewindApp")" != Mach-O* ]]; then
    echo "Error: the app bundle executable must be the native Mach-O application" >&2
    exit 1
fi
for required_helper in coding-rewind-sidecar coding-rewind; do
    if [[ "$(/usr/bin/file -b "${HELPERS_DIR}/${required_helper}")" != Mach-O* ]]; then
        echo "Error: helper ${required_helper} must be a native Mach-O binary" >&2
        exit 1
    fi
done

if [[ "${APP_BUNDLE}" != "/Applications/CodingRewind.app" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi

echo "Built and verified app bundle at ${APP_BUNDLE}"

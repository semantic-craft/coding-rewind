#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RAW_DIST_DIR="${DIST_DIR:-${1:-${REPO_ROOT}/.build}}"

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
swift build

BIN_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="${RESOLVED_DIST_DIR}/CodingRewind.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}"

install -m 0755 "${BIN_DIR}/CodingRewindApp" "${MACOS_DIR}/CodingRewindApp"
install -m 0755 "${BIN_DIR}/coding-rewind-hook" "${HELPERS_DIR}/coding-rewind-hook"

if [[ -f "${REPO_ROOT}/scripts/memos-mcp-bridge.sh" ]]; then
    install -m 0755 "${REPO_ROOT}/scripts/memos-mcp-bridge.sh" "${HELPERS_DIR}/memos-mcp-bridge.sh"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleExecutable</key>
    <string>CodingRewindApp</string>
    <key>CFBundleIdentifier</key>
    <string>dev.codingrewind.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CodingRewind</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "Built and verified app bundle at ${APP_BUNDLE}"

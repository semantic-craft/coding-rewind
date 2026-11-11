#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

swift build

BIN_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="${REPO_ROOT}/.build/CodingRewind.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"

mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}"

install -m 0755 "${BIN_DIR}/CodingRewindApp" "${MACOS_DIR}/CodingRewindApp"
install -m 0755 "${BIN_DIR}/coding-rewind-hook" "${HELPERS_DIR}/coding-rewind-hook"
install -m 0755 "${BIN_DIR}/rewind-mcp" "${HELPERS_DIR}/rewind-mcp"

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
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.codingrewind.stash</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>coding-rewind</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "Built and verified app bundle at ${APP_BUNDLE}"

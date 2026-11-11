#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEMINI_CLI="${GEMINI_BIN:-${HOME}/.local/bin/gemini-api}"
STAGE_DIR="${REPO_ROOT}/.build/gemini-icons"
RESOURCES_DIR="${REPO_ROOT}/Resources"

MENUBAR_MODE="vector"
for arg in "$@"; do
  case "${arg}" in
    --keep-vector-menubar)
      MENUBAR_MODE="vector"
      ;;
    --use-gemini-menubar)
      MENUBAR_MODE="gemini"
      ;;
    *)
      echo "Usage: $0 [--keep-vector-menubar|--use-gemini-menubar]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "${GEMINI_CLI}" ]]; then
  echo "Error: gemini-api binary not found or not executable at ${GEMINI_CLI}" >&2
  exit 1
fi

api_key="${GEMINI_GAKA_AGENT_API_KEY:-}"
if [[ -z "${api_key}" ]]; then
  api_key="$(op read "op://Private/6ouy7v2pphhbmxfctdbtrykyji/credential")"
fi
if [[ -z "${api_key}" ]]; then
  echo "Error: empty Gemini API credential" >&2
  exit 1
fi

mkdir -p "${STAGE_DIR}" "${RESOURCES_DIR}"

APP_ICON_PROMPT="Full-bleed 1:1 square graphic illustration filling 100 percent of the canvas from edge to edge with deep midnight indigo-obsidian gradient background, subtle glowing cyan grid aura, a tilted translucent frosted glass code snippet card at the center, wrapped by a luminous sky-cyan to warm-amber counter-clockwise rewind arc with crisp double-chevron arrowhead and a central golden four-point spark, tactile studio lighting, clean minimalist emblem, zero text, zero rounded icon frame, zero outer border or margin"
MENUBAR_PROMPT="minimal flat monochrome black icon on pure solid white background, counter-clockwise 270-degree rounded rewind arrow arc framing two horizontal quote lines in the center, bold uniform stroke weight, clean vector silhouette for macOS menu bar template, no gradients, no gray shading, no text"

GEMINI_API_KEY="${api_key}" "${GEMINI_CLI}" --no-interactive image "${APP_ICON_PROMPT}" \
  --aspect-ratio 1:1 \
  --image-size 1K \
  --output-mime-type image/jpeg \
  --out "${STAGE_DIR}/app-icon-raw.jpg" >/dev/null
/usr/bin/sips -s format png "${STAGE_DIR}/app-icon-raw.jpg" --out "${RESOURCES_DIR}/AppIcon-artwork.png" >/dev/null

if [[ "${MENUBAR_MODE}" == "gemini" ]]; then
  GEMINI_API_KEY="${api_key}" "${GEMINI_CLI}" --no-interactive image "${MENUBAR_PROMPT}" \
    --aspect-ratio 1:1 \
    --image-size 1K \
    --output-mime-type image/jpeg \
    --out "${STAGE_DIR}/menubar-glyph-raw.jpg" >/dev/null
  /usr/bin/sips -s format png "${STAGE_DIR}/menubar-glyph-raw.jpg" --out "${STAGE_DIR}/menubar-glyph.png" >/dev/null
fi

unset api_key

ICONSET_STAGE="${STAGE_DIR}/AppIcon.iconset"
rm -rf "${ICONSET_STAGE}"

if [[ "${MENUBAR_MODE}" == "gemini" ]]; then
  swift "${REPO_ROOT}/scripts/generate-app-icons.swift" "${ICONSET_STAGE}" \
    --menubar-from-glyph "${STAGE_DIR}/menubar-glyph.png"
else
  swift "${REPO_ROOT}/scripts/generate-app-icons.swift" "${ICONSET_STAGE}"
fi

swift "${REPO_ROOT}/scripts/verify-app-icon.swift" "${ICONSET_STAGE}" "${RESOURCES_DIR}"
rm -rf "${ICONSET_STAGE}"

echo "Refreshed and verified Gemini-generated icon assets in ${RESOURCES_DIR}"

#!/usr/bin/env sh
# Offline 3D preview of the world MapBuilder builds (no Roblox needed).
#   tools/render/render.sh [outDir] [view ...]      (run from the repo root)
# Needs: lune (or $LUNE), node, and `npm install` once in tools/render.
# Chromium: $CHROMIUM or the Playwright headless shell under /opt/pw-browsers.
set -e
LUNE="${LUNE:-lune}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"; [ $# -gt 0 ] && shift
"$LUNE" run "$HERE/export_map.luau" "$HERE/map.json"
node "$HERE/render.mjs" "$OUT" "$@"

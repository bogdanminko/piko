#!/bin/bash
# Regenerate assets/icon/Piko.icns from the "Peak" icon design
# (see scripts/render-icon.swift). Run after changing the icon.
set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="build/Piko.iconset"
OUT="assets/icon/Piko.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$(dirname "$OUT")"

swift scripts/render-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "Built $OUT"

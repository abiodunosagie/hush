#!/bin/bash
# Rebuilds brand/AppIcon.icns from the logo geometry in Sources/Hush/Brand.swift.
# Run after changing the mark (and brand/generate.py for the SVG masters).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Top-level code is only allowed in a file named main.swift.
cp brand/MakeIcon.swift "$WORK/main.swift"
swiftc -O Sources/Hush/Brand.swift "$WORK/main.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o brand/AppIcon.icns
echo "Wrote brand/AppIcon.icns"

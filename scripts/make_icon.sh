#!/bin/bash
# Regenerates Resources/AppIcon.icns and Resources/logo-1024.png from LogoMark.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -parse-as-library -O scripts/icon/main.swift Sources/DevSweepApp/LogoMark.swift -o "$TMP/make_icon" 2>/dev/null \
  || swiftc -O scripts/icon/main.swift Sources/DevSweepApp/LogoMark.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" Resources/logo-1024.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns and Resources/logo-1024.png"

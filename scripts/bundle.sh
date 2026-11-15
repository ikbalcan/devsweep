#!/bin/bash
# Builds DevSweep.app (and the devsweep CLI) into dist/.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="0.1.0"
swift build -c "$CONFIG" --product DevSweepApp
swift build -c "$CONFIG" --product devsweep
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/DevSweep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DevSweepApp" "$APP/Contents/MacOS/DevSweep"
cp "$BIN/devsweep" dist/devsweep
[ -f Resources/AppIcon.icns ] || scripts/make_icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DevSweep</string>
  <key>CFBundleDisplayName</key><string>DevSweep</string>
  <key>CFBundleIdentifier</key><string>dev.devsweep.app</string>
  <key>CFBundleExecutable</key><string>DevSweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>DevSweep looks for build folders (node_modules, build, .dart_tool) of projects kept in Documents. Source files are never touched.</string>
  <key>NSDesktopFolderUsageDescription</key><string>DevSweep looks for build folders of projects kept on the Desktop. Source files are never touched.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DevSweep looks for build folders of projects kept in Downloads. Source files are never touched.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats the bundle as one app (not notarized).
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP and dist/devsweep ($CONFIG)"

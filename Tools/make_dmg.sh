#!/bin/bash
# Packs the Release build into dist/TrackSplit-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Build/Products/Release/TrackSplit.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/TrackSplit.app"
find "$STAGE/TrackSplit.app" -name __pycache__ -type d -prune -exec rm -rf {} +
ln -s /Applications "$STAGE/Aplicativos"
mkdir -p dist
rm -f "dist/TrackSplit-$VERSION.dmg"
hdiutil create -volname "TrackSplit" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "dist/TrackSplit-$VERSION.dmg" >/dev/null
echo "dist/TrackSplit-$VERSION.dmg"

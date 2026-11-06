#!/usr/bin/env bash
# Builds Macpr Flow.app and wraps it in a drag-to-install disk image at .build/MacprFlow.dmg.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
INSTALL=0 Scripts/package_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Macpr Flow.app/Contents/Info.plist")
STAGE="$ROOT/.build/dmg"
OUT="$ROOT/.build/MacprFlow-$VERSION.dmg"
rm -rf "$STAGE" "$OUT"; mkdir -p "$STAGE"
ditto "Macpr Flow.app" "$STAGE/Macpr Flow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Macpr Flow" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "$OUT"

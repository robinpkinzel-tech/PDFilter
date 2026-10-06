#!/usr/bin/env bash
# Erzeugt build/PDFilter.app aus dem Swift Package (Release-Build, ad-hoc signiert).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Release-Build"
swift build -c release --product PDFilter 2>&1 | tail -n 50

BIN=".build/release/PDFilter"
APP="build/PDFilter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFilter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  echo "==> Icon erzeugen"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE*2))
    sips -z $DOUBLE $DOUBLE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc signieren"
codesign --force --deep --sign - "$APP"

echo "==> Fertig: $APP"

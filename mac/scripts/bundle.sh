#!/usr/bin/env bash
# Builds Bass Shake.app (universal) from the SwiftPM package and zips it.
#   mac/scripts/bundle.sh [version] [build-number]
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: …"
# for a notarizable build (then run notarytool + stapler).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
APP="build/Bass Shake.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/BassShake"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BassShake"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" mac/Resources/Info.plist > "$APP/Contents/Info.plist"
cp mac/Resources/MenuBarIcon*.png "$APP/Contents/Resources/"

# App icon: render the shaker onto a rounded tile and build an .icns.
if [ -f mac/Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s mac/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) mac/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

OPTS=()
if [ "$SIGN_IDENTITY" != "-" ]; then OPTS=(--options runtime --timestamp); fi
codesign --force --sign "$SIGN_IDENTITY" "${OPTS[@]}" \
  --entitlements mac/Resources/BassShake.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"

ZIP="build/BassShake-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built $ZIP"

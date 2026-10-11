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
# Optional preset-icon artwork (PresetIcons/<sf-symbol-or-id>.png).
if [ -d mac/Resources/PresetIcons ]; then cp -R mac/Resources/PresetIcons "$APP/Contents/Resources/"; fi

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

BUNDLE_ID="app.bassshake.BassShake"
if [ "$SIGN_IDENTITY" = "-" ]; then
  # Ad-hoc, but with an identifier-only designated requirement so macOS keeps
  # the System Audio Recording grant across beta builds (a plain ad-hoc
  # signature pins the exact binary hash, re-prompting on every update).
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    --entitlements mac/Resources/BassShake.entitlements "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements mac/Resources/BassShake.entitlements "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"

ZIP="build/BassShake-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built $ZIP"

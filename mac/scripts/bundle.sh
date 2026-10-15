#!/usr/bin/env bash
# Builds The Bass Shaker.app (universal) from the SwiftPM package and zips it.
#   mac/scripts/bundle.sh [version] [build-number]
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: …"
# for a notarizable build (then run notarytool + stapler).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
APP="build/The Bass Shaker.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Universal by default (needs full Xcode). ARCHS=native builds just this Mac's
# architecture, which works with only the Command Line Tools (local installs).
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
if [ "$ARCHS" != "native" ]; then for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done; fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/BassShake"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BassShake"

# Embed Sparkle.framework (universal slice of the SwiftPM binary artifact).
BIN_DIR="$(dirname "$BIN")"
FW="$(find "$BIN_DIR" -maxdepth 3 -name Sparkle.framework -type d 2>/dev/null | head -1)"
if [ -z "$FW" ]; then
  FW="$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -type d 2>/dev/null | head -1)"
fi
if [ -z "$FW" ]; then echo "error: Sparkle.framework not found" >&2; exit 1; fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$FW" "$APP/Contents/Frameworks/Sparkle.framework"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" mac/Resources/Info.plist > "$APP/Contents/Info.plist"
cp mac/Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
# Optional preset-icon artwork (PresetIcons/<sf-symbol-or-id>.png).
if [ -d mac/Resources/PresetIcons ]; then cp -R mac/Resources/PresetIcons "$APP/Contents/Resources/"; fi

# App icon (sources: mac/scripts/make_app_icon.sh). Always an .icns from the
# pre-composited master (824 squircle body on 1024) for macOS 14.4-15 and as a
# fallback (CFBundleIconFile).
if [ -f mac/Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s mac/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) mac/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# macOS 26: compile the Icon Composer bundle (Liquid Glass, dark and tinted
# appearances) into Assets.car + CFBundleIconName. Needs full Xcode 26's actool
# (CI has it); with only the Command Line Tools the .icns above ships alone.
if [ -d mac/Resources/AppIcon.icon ]; then
  ACT_OUT="build/actool"
  rm -rf "$ACT_OUT" && mkdir -p "$ACT_OUT"
  if xcrun --find actool >/dev/null 2>&1 &&
     xcrun actool mac/Resources/AppIcon.icon --compile "$ACT_OUT" \
       --app-icon AppIcon --platform macosx --target-device mac \
       --minimum-deployment-target 14.4 --enable-on-demand-resources NO \
       --development-region en --output-partial-info-plist "$ACT_OUT/partial.plist" \
       --output-format human-readable-text --errors --warnings --notices &&
     [ -f "$ACT_OUT/Assets.car" ]; then
    cp "$ACT_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
    echo "App icon: Assets.car (Icon Composer) + AppIcon.icns fallback"
  else
    msg="App icon: actool could not compile AppIcon.icon (needs Xcode 26); shipping AppIcon.icns only"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$msg"; else echo "$msg"; fi
  fi
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

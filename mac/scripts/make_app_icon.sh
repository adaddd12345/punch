#!/usr/bin/env bash
# Rasterises the app icon from its source of truth, docs/icon-concepts/F-shaker-cube/build.mjs,
# into the files bundle.sh uses (committed, so CI needs no Node or SVG renderer):
#   node docs/icon-concepts/F-shaker-cube/build.mjs && mac/scripts/make_app_icon.sh
#   mac/Resources/AppIcon.png              pre-composited 1024 master (824 squircle body) -> AppIcon.icns
#   mac/Resources/AppIcon.icon/Assets/*.png  Icon Composer layers (default/dark/mono)      -> Assets.car (macOS 26)
#   mac/Resources/AppIconVariants/{light,dark,freezing,ember}.png  pre-composited colourways for the icon picker
# AppIcon.icon/icon.json is hand-kept: its background gradients mirror layers/*/background.svg.
# macOS only (renders with WebKit via svg2png.swift, which keeps transparency and the SVG blur filters).
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=docs/icon-concepts/F-shaker-cube
RES=mac/Resources
A="$RES/AppIcon.icon/Assets"
V="$RES/AppIconVariants"
mkdir -p "$A" "$V"
jobs=("$SRC/icon.svg" "$RES/AppIcon.png"
      "$SRC/icon.svg" "$V/light.png" "$SRC/icon-dark.svg" "$V/dark.png"
      "$SRC/icon-freezing.svg" "$V/freezing.png" "$SRC/icon-ember.svg" "$V/ember.png")
for layer in 1-cube 2-lid 3-woofer; do
  name="${layer#*-}"
  jobs+=("$SRC/layers/$layer.svg" "$A/$name.png"
         "$SRC/layers/dark/$layer.svg" "$A/$name-dark.png"
         "$SRC/layers/mono/$layer.svg" "$A/$name-mono.png")
done
swift mac/scripts/svg2png.swift "${jobs[@]}"
echo "Rasterised $RES/AppIcon.png, $A/ and $V/"

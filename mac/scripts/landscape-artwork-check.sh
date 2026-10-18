#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-landscape-artwork-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtworkContentCrop.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtRGB.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtworkCardPalette.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtworkEffects.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtworkFinishPattern.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/ArtworkFinishOverlay.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/PowerSaver.swift" \
  "$REPO_ROOT/mac/scripts/landscape-artwork-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

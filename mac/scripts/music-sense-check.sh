#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-music-sense-check.XXXXXX")"
# Kept between runs: a cold Accelerate module cache costs ~35 s.
CHECK_CACHE="$REPO_ROOT/.build/music-sense-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/MusicSenseTypes.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/MusicSenseDSP.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/MusicSense.swift" \
  "$REPO_ROOT/mac/scripts/music-sense-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

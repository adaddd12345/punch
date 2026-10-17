#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-output-groups.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
clang -std=c11 -fsanitize=address,undefined -g \
  -I "$ROOT/core/include" -I "$ROOT/mac/Sources/BassShakeRT/include" \
  "$ROOT/mac/Sources/BassShakeRT/BassShakeRT.c" "$ROOT/mac/scripts/output-groups-check.c" \
  -framework CoreAudio -framework CoreFoundation -o "$CHECK_DIR/render"
"$CHECK_DIR/render"
swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$ROOT/mac/Sources/BassShake/CoreAudioHelpers.swift" \
  "$ROOT/mac/Sources/BassShake/OutputGroups.swift" \
  "$ROOT/mac/Sources/BassShake/PlayerLayoutMigration.swift" \
  "$ROOT/mac/scripts/output-groups-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

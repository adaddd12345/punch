#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-waveform-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$REPO_ROOT/.build/eq-design-studio/module-cache" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/WaveformDesign.swift" \
  "$REPO_ROOT/mac/scripts/waveform-measurements-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

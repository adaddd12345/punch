#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-spectrum-calibration.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_DIR/module-cache" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/Spectrum.swift" \
  "$REPO_ROOT/mac/scripts/spectrum-calibration-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-bass-visualizer-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -O -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$REPO_ROOT/mac/Sources/BassShake/BassVisualizerAnalysis.swift" \
  "$REPO_ROOT/mac/scripts/bass-visualizer-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

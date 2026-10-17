#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-browser-tempo-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$REPO_ROOT/mac/Sources/BassShake/BrowserTempoScript.swift" \
  "$REPO_ROOT/mac/scripts/browser-tempo-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-market-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

# An immutable copy also permits this check while another compiler reads the
# working tree. It is the production file, with no test-specific substitutions.
cp "$REPO_ROOT/mac/Sources/BassShake/MarketData.swift" "$CHECK_DIR/MarketData.swift"

swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$CHECK_DIR/MarketData.swift" \
  "$REPO_ROOT/mac/scripts/market-data-check.swift" \
  -o "$CHECK_DIR/market-data-check"
"$CHECK_DIR/market-data-check"

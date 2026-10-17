#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-menu-bar-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

# Compile an immutable snapshot when this check runs alongside app work.
cp "$REPO_ROOT/mac/Sources/BassShake/MenuBarAccessory.swift" "$CHECK_DIR/MenuBarAccessory.swift"
cp "$REPO_ROOT/mac/scripts/menu-bar-check.swift" "$CHECK_DIR/menu-bar-check.swift"
swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$CHECK_DIR/MenuBarAccessory.swift" \
  "$CHECK_DIR/menu-bar-check.swift" -o "$CHECK_DIR/check"
# Optional first argument: directory for light/dark native-control PNGs.
"$CHECK_DIR/check" "$@" | tee "$CHECK_DIR/output"
# macOS can terminate an AppKit CLI during sandboxed Launch Services setup
# with status 0. Require the completion marker rather than mistaking that for
# a passing regression suite.
rg -q '^PASS:' "$CHECK_DIR/output"

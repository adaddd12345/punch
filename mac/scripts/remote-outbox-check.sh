#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-remote-outbox-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/remote-outbox-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/RemoteWire.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/RemoteCrypto.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/RemoteLink.swift" \
  "$REPO_ROOT/mac/scripts/remote-outbox-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

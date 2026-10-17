#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-prism-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/prism-play-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/PrismPlayButton.swift" \
  "$REPO_ROOT/mac/scripts/prism-play-check.swift" -o "$CHECK_DIR/check"
python3 - "$CHECK_DIR/check" "$@" <<'PY' | tee "$CHECK_DIR/output"
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=20)
    print(result.stdout, end='')
    print(result.stderr, end='')
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit('FAIL: shield fixture exceeded 20 seconds')
PY
rg -q '^PASS: glass has' "$CHECK_DIR/output"

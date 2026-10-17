#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-footer-icon-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/footer-icon-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/FooterFlatIcon.swift" \
  "$REPO_ROOT/mac/scripts/footer-icon-check.swift" -o "$CHECK_DIR/check"
python3 - "$CHECK_DIR/check" "$@" <<'PY' | tee "$CHECK_DIR/output"
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=15)
    print(result.stdout, end='')
    print(result.stderr, end='')
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit('FAIL: footer fixture exceeded 15 seconds')
PY
# Restricted Launch Services can exit without ever reaching the fixture.
rg -q '^PASS: layout stays fixed' "$CHECK_DIR/output"

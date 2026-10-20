#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-site-icon-stream-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/site-icon-stream-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/SiteIcon.swift" \
  "$REPO_ROOT/mac/scripts/site-icon-stream-check.swift" -o "$CHECK_DIR/check"
python3 - "$CHECK_DIR/check" <<'PY'
import subprocess, sys
result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=25)
print(result.stdout, end='')
print(result.stderr, end='')
sys.exit(result.returncode)
PY

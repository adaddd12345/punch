#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-device-power-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/device-battery-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" -parse-as-library \
  "$REPO_ROOT/mac/Sources/BassShake/CoreAudioHelpers.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/PowerSaver.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/DeviceBattery.swift" \
  "$REPO_ROOT/mac/scripts/device-battery-check.swift" -o "$CHECK_DIR/check"
python3 - "$CHECK_DIR/check" "$@" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=15)
    print(result.stdout, end='')
    print(result.stderr, end='')
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit('FAIL: device battery check exceeded 15 seconds')
PY

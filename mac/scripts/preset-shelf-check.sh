#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-preset-shelf-check.XXXXXX")"
CHECK_CACHE="$REPO_ROOT/.build/preset-shelf-check/module-cache"
mkdir -p "$CHECK_CACHE"
trap 'rm -rf "$CHECK_DIR"' EXIT

for SOURCE in PresetQuadShelf DragScroll PopupMotion; do
  cp "$REPO_ROOT/mac/Sources/BassShake/$SOURCE.swift" "$CHECK_DIR/$SOURCE.swift"
done
cp "$REPO_ROOT/mac/scripts/preset-shelf-check.swift" "$CHECK_DIR/preset-shelf-check.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$CHECK_CACHE" \
  "$CHECK_DIR/PresetQuadShelf.swift" "$CHECK_DIR/DragScroll.swift" "$CHECK_DIR/PopupMotion.swift" \
  "$CHECK_DIR/preset-shelf-check.swift" -o "$CHECK_DIR/check"

# The native fixture has no children; timeout kills and reaps only this process.
python3 - "$CHECK_DIR/check" "$@" <<'PY' | tee "$CHECK_DIR/output"
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    print(result.stdout, end='')
    sys.exit(result.returncode)
except subprocess.TimeoutExpired as error:
    print('FAIL: isolated preset shelf fixture exceeded 30 seconds')
    if error.stdout:
        print(error.stdout.decode() if isinstance(error.stdout, bytes) else error.stdout)
    sys.exit(1)
PY
# AppKit startup can exit 0 under a restricted Launch Services sandbox.
rg -q '^PASS:' "$CHECK_DIR/output"

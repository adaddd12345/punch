#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-sound-like.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Compile the production model and fitter without the unrelated SwiftUI menu
# or the full settings/controller graph. The actual headphone data is included.
python3 - "$REPO_ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
for source, marker in [('Model.swift', 'extension Preset {'), ('SoundLike.swift', 'struct SoundLikeMenu:')]:
    text = (root / 'mac/Sources/BassShake' / source).read_text()
    assert marker in text, f'Missing model boundary in {source}'
    (out / source).write_text(text.split(marker)[0])
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -I "$REPO_ROOT/core/include" -module-cache-path "$CHECK_DIR/module-cache" -parse-as-library \
  "$CHECK_DIR/Model.swift" "$CHECK_DIR/SoundLike.swift" \
  "$REPO_ROOT/mac/Sources/BassShake/HeadphonePresets.swift" \
  "$REPO_ROOT/mac/scripts/sound-like-check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"

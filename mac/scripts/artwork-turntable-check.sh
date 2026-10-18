#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/artwork-turntable.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
swiftc -module-cache-path "$task_tmp/modules" \
  "$root/mac/Sources/BassShake/ArtworkTurntableScene.swift" \
  "$root/mac/scripts/artwork-turntable-check.swift" \
  -o "$task_tmp/check"
"$task_tmp/check"

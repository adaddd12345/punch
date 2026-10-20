#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bassshake-inventory-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 -O -module-cache-path "$work/modules" \
  "$repo/mac/Sources/BassShake/CoreAudioHelpers.swift" \
  "$repo/mac/scripts/device-inventory-check.swift" \
  -o "$work/device-inventory-check"
"$work/device-inventory-check"

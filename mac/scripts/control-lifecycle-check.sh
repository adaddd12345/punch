#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bassshake-lifecycle-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
flags=(-swift-version 5 -O)
if [[ "${1:-}" == "--tsan" ]]; then flags+=(-sanitize=thread); fi
swiftc "${flags[@]}" -module-cache-path "$work/modules" \
  "$repo/mac/Sources/BassShake/SingleFlightProbe.swift" \
  "$repo/mac/Sources/BassShake/OperationEpoch.swift" \
  "$repo/mac/Sources/BassShake/RescueLatch.swift" \
  "$repo/mac/scripts/control-lifecycle-check.swift" \
  -o "$work/control-lifecycle-check"
"$work/control-lifecycle-check"

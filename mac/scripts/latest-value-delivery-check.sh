#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bassshake-delivery-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
flags=(-swift-version 5 -O)
if [[ "${1:-}" == "--tsan" ]]; then flags+=(-sanitize=thread); fi
swiftc "${flags[@]}" -module-cache-path "$work/modules" \
  "$repo/mac/Sources/BassShake/LatestValueDelivery.swift" \
  "$repo/mac/scripts/latest_value_delivery_check.swift" \
  -o "$work/latest-value-delivery-check"
"$work/latest-value-delivery-check"

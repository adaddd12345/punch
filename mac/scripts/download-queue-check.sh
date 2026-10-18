#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOB="$(mktemp -d "${TMPDIR:-/tmp}/bass-download-check-build.XXXXXX")"
trap 'rm -rf "$JOB"' EXIT
swiftc -module-cache-path "$ROOT/.build/download-check-module-cache" \
  "$ROOT/mac/Sources/BassShake/DownloadQueue.swift" \
  "$ROOT/mac/tests/DownloadQueueCheck.swift" -o "$JOB/check"
"$JOB/check" "$@"

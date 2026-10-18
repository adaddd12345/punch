#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOB="$(mktemp -d "${TMPDIR:-/tmp}/bass-download-options-check.XXXXXX")"
trap 'rm -rf "$JOB"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swiftc -module-cache-path "$ROOT/.build/download-check-module-cache" \
  "$ROOT/mac/Sources/BassShake/DownloadQueue.swift" \
  "$ROOT/mac/Sources/BassShake/DownloadInboxOptions.swift" \
  "$ROOT/mac/tests/DownloadInboxOptionsCheck.swift" -o "$JOB/check"
"$JOB/check"

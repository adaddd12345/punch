#!/usr/bin/env bash
# Regenerates only the menu-bar template and native fallback; never AppIcon.
# Generated outputs are committed, so bundle.sh needs no renderer at build time.
set -euo pipefail
cd "$(dirname "$0")/../.."
cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/punch-menubar-cache.XXXXXX")"
trap 'rm -rf "$cache_dir"' EXIT
swift -module-cache-path "$cache_dir" mac/scripts/make_menubar_icon.swift "$@"

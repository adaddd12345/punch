#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUDIO_DIR="$REPO_ROOT/build/EQ Design Studio.app"
STUDIO_CACHE="$REPO_ROOT/.build/eq-design-studio/module-cache"
STUDIO_SOURCES="$(mktemp -d "${TMPDIR:-/tmp}/punch-eq-studio.XXXXXX")"
trap 'rm -rf "$STUDIO_SOURCES"' EXIT
mkdir -p "$STUDIO_DIR/Contents/MacOS" "$STUDIO_CACHE"
# Compile a fixed snapshot while the creative team refines the source files.
cp "$REPO_ROOT/mac/Sources/BassShake/WaveformDesign.swift" "$STUDIO_SOURCES/"
cp "$REPO_ROOT/mac/Sources/BassShake/EQLineArtwork.swift" "$STUDIO_SOURCES/"
cp "$REPO_ROOT/mac/Sources/BassShake/EQDesignPreview.swift" "$STUDIO_SOURCES/"
cp "$REPO_ROOT/mac/scripts/eq-design-studio.swift" "$STUDIO_SOURCES/"
cp "$REPO_ROOT/mac/scripts/eq-studio-response.h" "$STUDIO_SOURCES/"
cp "$REPO_ROOT/mac/scripts/eq-studio-response.cpp" "$STUDIO_SOURCES/"
clang++ -std=c++20 -O2 -mmacosx-version-min=14.4 -I "$REPO_ROOT/core/include" -c \
  "$STUDIO_SOURCES/eq-studio-response.cpp" -o "$STUDIO_SOURCES/response.o"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$STUDIO_CACHE" -parse-as-library \
  -import-objc-header "$STUDIO_SOURCES/eq-studio-response.h" \
  "$STUDIO_SOURCES/WaveformDesign.swift" \
  "$STUDIO_SOURCES/EQLineArtwork.swift" \
  "$STUDIO_SOURCES/EQDesignPreview.swift" \
  "$STUDIO_SOURCES/eq-design-studio.swift" \
  "$STUDIO_SOURCES/response.o" -lc++ \
  -o "$STUDIO_DIR/Contents/MacOS/EQDesignStudio"
cat > "$STUDIO_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.bassshake.EQDesignStudio</string>
<key>CFBundleName</key><string>EQ Design Studio</string>
<key>CFBundleExecutable</key><string>EQDesignStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.4</string>
</dict></plist>
PLIST
if [ "${1:-}" = "--build-only" ]; then
  echo "Built $STUDIO_DIR"
elif [ "${1:-}" = "--snapshot" ]; then
  "$STUDIO_DIR/Contents/MacOS/EQDesignStudio" "$@"
else
  open "$STUDIO_DIR"
fi

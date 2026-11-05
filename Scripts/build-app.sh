#!/bin/bash
# Builds Atlas.app into ./build. Usage: Scripts/build-app.sh [debug|release] (default release)
# Release builds are universal (Apple silicon and Intel); debug builds are for this Mac only,
# which keeps them quick.
set -euo pipefail
source "$(dirname "$0")/toolchain-env.sh"
CONFIG="${1:-release}"
cd "$ROOT"

SLICES=()
if [ "$CONFIG" = release ]; then
  for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH" --product Atlas
    SLICES+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/Atlas")
  done
else
  swift build -c "$CONFIG" --product Atlas
  SLICES+=("$(swift build -c "$CONFIG" --show-bin-path)/Atlas")
fi

APP="$ROOT/build/Atlas.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Atlas"
else
  cp "${SLICES[0]}" "$APP/Contents/MacOS/Atlas"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Ad-hoc signature so macOS treats it as a proper app (calendar access prompts etc.).
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($CONFIG)"

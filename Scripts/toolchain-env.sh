#!/bin/bash
# Sourced by the other scripts. Works around two quirks of building with the Command Line
# Tools alone (no Xcode). Neither changes anything outside this project folder.
#
#  1. An older CLT install can leave a stale PackageDescription *.private.swiftinterface
#     behind; the compiler prefers it, so every Package.swift fails to link. When that file
#     exists we give SwiftPM a clean copy of its manifest library (in .build-support/).
#  2. `swift test` does not find the Swift Testing framework on its own, so TEST_FLAGS
#     carries the search paths.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FLAGS=()

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null)"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
  CLT="$DEVELOPER_DIR_PATH"
  PM_LIBS="$CLT/usr/lib/swift/pm"
  if ls "$PM_LIBS/ManifestAPI/PackageDescription.swiftmodule/"*.private.swiftinterface >/dev/null 2>&1; then
    SHIM="$ROOT/.build-support/pm"
    if [ ! -f "$SHIM/ManifestAPI/libPackageDescription.dylib" ] || \
       [ "$PM_LIBS/ManifestAPI/libPackageDescription.dylib" -nt "$SHIM/ManifestAPI/libPackageDescription.dylib" ]; then
      rm -rf "$SHIM"
      mkdir -p "$SHIM"
      cp -R "$PM_LIBS/ManifestAPI" "$PM_LIBS/PluginAPI" "$SHIM/"
      find "$SHIM" -name "*.private.swiftinterface" -delete
    fi
    export SWIFTPM_CUSTOM_LIBS_DIR="$SHIM"
  fi

  DEV="$CLT/Library/Developer"
  if [ -d "$DEV/Frameworks/Testing.framework" ]; then
    TEST_FLAGS=(
      -Xswiftc -F -Xswiftc "$DEV/Frameworks"
      -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing"
      -Xlinker -F -Xlinker "$DEV/Frameworks"
      -Xlinker -rpath -Xlinker "$DEV/Frameworks"
      -Xlinker -rpath -Xlinker "$DEV/usr/lib"
    )
  fi
fi

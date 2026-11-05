#!/bin/bash
# Runs the unit tests. Extra arguments go to `swift test` (e.g. --filter MapTree).
set -euo pipefail
source "$(dirname "$0")/toolchain-env.sh"
cd "$ROOT"
swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} "$@"

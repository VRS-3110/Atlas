#!/bin/bash
# Builds a debug Atlas.app and opens it.
set -euo pipefail
"$(dirname "$0")/build-app.sh" "${1:-debug}"
open "$(cd "$(dirname "$0")/.." && pwd)/build/Atlas.app"

#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:-$root/build/Build/Products/Release/Pisya.app}"
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run-interface-layout-test.sh [path/to/Pisya.app]' >&2
  exit 2
fi
if [[ ! -x "$app/Contents/MacOS/Pisya" ]]; then
  printf 'Build Pisya first, then pass the app bundle to this test: %s\n' "$app" >&2
  exit 2
fi
"$app/Contents/MacOS/Pisya" --interface-layout-self-test

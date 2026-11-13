#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:-$root/build/Build/Products/Release/Pisya.app}"
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run-interface-layout-test.sh [path/to/Pisya.app]' >&2
  exit 2
fi
binary="$app/Contents/MacOS/Pisya"
if [[ ! -x "$binary" ]]; then
  printf 'Build Pisya first, then pass the app bundle to this test: %s\n' "$app" >&2
  exit 2
fi
# An older app ignores an unknown argument and opens the normal library.
if ! LC_ALL=C grep -Faq -- '--interface-layout-self-test' "$binary"; then
  printf 'This build does not contain the interface layout tests: %s\n' "$app" >&2
  exit 2
fi
"$binary" --interface-layout-self-test

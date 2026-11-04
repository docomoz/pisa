#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="$(mktemp -t pisya-status-menu)"
trap 'rm -f "$binary"' EXIT
swiftc "$root/Sources/Pisya/AppTypography.swift" "$root/Sources/Pisya/StatusBarController.swift" "$root/Tests/Native/StatusBarMenuProbe.swift" -o "$binary"
"$binary" "$@"

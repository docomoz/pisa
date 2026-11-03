#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="$(mktemp -t pisya-capture-window)"
trap 'rm -f "$binary"' EXIT
swiftc "$root/Sources/Pisya/CaptureWindow.swift" "$root/Tests/Native/CaptureWindowProbe.swift" -o "$binary"
"$binary"

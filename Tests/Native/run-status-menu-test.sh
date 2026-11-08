#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="$(mktemp -t pisya-status-menu)"
trap 'rm -f "$binary"' EXIT
toolchain="$(xcrun --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
plugin_path="$platform/Developer/usr/lib/swift/host/plugins"
"$toolchain" -sdk "$sdk" -plugin-path "$plugin_path" "$root/Sources/Pisya/AppTypography.swift" "$root/Sources/Pisya/StatusBarController.swift" "$root/Tests/Native/StatusBarMenuProbe.swift" -o "$binary"
"$binary" "$@"

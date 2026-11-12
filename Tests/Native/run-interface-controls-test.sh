#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'BLOCKED: interface controls require macOS AppKit/SwiftUI and a WindowServer session' >&2
  exit 77
fi
binary="$(mktemp -t pisya-interface-controls)"
trap 'rm -f "$binary"' EXIT
toolchain="$(xcrun --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
plugin_path="$platform/Developer/usr/lib/swift/host/plugins"
"$toolchain" -swift-version 5 -sdk "$sdk" -plugin-path "$plugin_path" \
  -target "$(uname -m)-apple-macosx15.0" \
  "$root/Sources/PisyaCore/Models.swift" \
  "$root/Sources/PisyaCore/MeetingTitles.swift" \
  "$root/Sources/PisyaCore/LiveTranscriptionSchedule.swift" \
  "$root/Sources/Pisya/Appearance.swift" \
  "$root/Sources/Pisya/AppTypography.swift" \
  "$root/Sources/Pisya/ScreenTypography.swift" \
  "$root/Sources/Pisya/DesignComponents.swift" \
  "$root/Sources/Pisya/SlimScrollbars.swift" \
  "$root/Sources/Pisya/SettingsSectionPicker.swift" \
  "$root/Tests/Native/InterfaceControlsProbe.swift" -o "$binary"
"$binary" "$@"

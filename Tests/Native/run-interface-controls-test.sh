#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'BLOCKED: interface controls require macOS AppKit/SwiftUI and a WindowServer session' >&2
  exit 77
fi
if ! platform="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)"; then
  xcode="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' | head -n 1)"
  if [[ -z "$xcode" && -d /Applications/Xcode.app ]]; then
    xcode=/Applications/Xcode.app
  fi
  if [[ -z "$xcode" ]]; then
    printf '%s\n' 'BLOCKED: this test requires Xcode with SwiftUI compiler plugins' >&2
    exit 77
  fi
  export DEVELOPER_DIR="$xcode/Contents/Developer"
  platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
fi
binary="$(mktemp -t pisya-interface-controls)"
trap 'rm -f "$binary"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -plugin-path "$platform/Developer/usr/lib/swift/host/plugins" \
  "$root/Sources/PisyaCore/Models.swift" \
  "$root/Sources/PisyaCore/MeetingTitles.swift" \
  "$root/Sources/PisyaCore/LiveTranscriptionSchedule.swift" \
  "$root/Sources/Pisya/Appearance.swift" \
  "$root/Sources/Pisya/AppTypography.swift" \
  "$root/Sources/Pisya/ScreenTypography.swift" \
  "$root/Sources/Pisya/DesignComponents.swift" \
  "$root/Sources/Pisya/SlimScrollbars.swift" \
  "$root/Tests/Native/InterfaceControlsProbe.swift" -o "$binary"
"$binary" "$@"

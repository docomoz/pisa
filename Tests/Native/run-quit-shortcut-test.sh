#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
probe="$(mktemp -t pisya-quit-shortcut)"
trap 'rm -f "$probe"' EXIT
swiftc "$root/Sources/Pisya/QuitShortcut.swift" "$root/Tests/Native/QuitShortcutProbe.swift" -o "$probe"
"$probe"

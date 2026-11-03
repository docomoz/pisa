#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app_bundle="$PWD/build/Build/Products/Release/Pisya.app"
mkdir -p "$app_bundle/Contents/Helpers" "$app_bundle/Contents/Resources/Licenses"
cp build/Build/Products/Release/pisya-mcp "$app_bundle/Contents/Helpers/"
python3 - <<'PY'
from pathlib import Path
import shutil
out = Path('build/Build/Products/Release/Pisya.app/Contents/Resources/Licenses')
roots = [Path('Vendor/mlx-audio-swift'), Path('Vendor/Sherpa'), Path('Vendor/WebRTCAEC'), Path('Vendor/SpeexDSP')]
checkouts = Path('build/SourcePackages/checkouts')
if checkouts.exists(): roots += list(checkouts.iterdir())
for root in roots:
    for pattern in ('LICENSE*', 'COPYING*', 'NOTICE*', 'PATENTS', 'AUTHORS', '*-LICENSE', '*-NOTICE', 'ONNX-RUNTIME-LICENSE'):
        for source in root.glob(pattern):
            if source.is_file(): shutil.copyfile(source, out / (root.name + '-' + source.name))
PY
# Local identity is optional and must never be committed (contains machine-specific paths).
if [[ -f .signing.env ]]; then source .signing.env; fi
sign_args=(--sign "${PISYA_SIGNING_IDENTITY:--}")
if [[ -n "${PISYA_SIGNING_KEYCHAIN:-}" ]]; then
    sign_args+=(--keychain "$PISYA_SIGNING_KEYCHAIN")
fi
# Sign every bundled native component with the same optional release identity.
for library in "$app_bundle"/Contents/Frameworks/*.dylib(N); do
    codesign --force "${sign_args[@]}" "$library"
done
codesign --force "${sign_args[@]}" "$app_bundle/Contents/Helpers/pisya-mcp"
codesign --force "${sign_args[@]}" --entitlements Resources/Pisya.entitlements "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

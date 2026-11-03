#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init --recursive
if [[ ! -f Vendor/Sherpa/lib/libonnxruntime.dylib ]]; then ./scripts/setup-runtime.sh; fi
if git -C Vendor/mlx-audio-swift apply --check ../../patches/mlx-audio-fft.patch 2>/dev/null; then
  git -C Vendor/mlx-audio-swift apply ../../patches/mlx-audio-fft.patch
fi
cp dependencies.resolved.json Vendor/mlx-audio-swift/Package.resolved
xcodegen generate
xcodebuild -project Pisya.xcodeproj -scheme Pisya -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
./scripts/package.sh
./scripts/make-dmg.sh
printf '%s\n' "Готово: $PWD/build/Build/Products/Release/Pisya.app"

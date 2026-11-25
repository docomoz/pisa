#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/pretest.py
git submodule update --init --recursive
if [[ ! -f Vendor/Sherpa/lib/libonnxruntime.dylib ]]; then ./scripts/setup-runtime.sh; fi
for patch in mlx-audio-fft.patch mlx-audio-qwen-prefill.patch mlx-audio-qwen-encoder-reuse.patch; do
  if git -C Vendor/mlx-audio-swift apply --check "../../patches/$patch" 2>/dev/null; then
    git -C Vendor/mlx-audio-swift apply "../../patches/$patch"
  elif ! git -C Vendor/mlx-audio-swift apply --reverse --check "../../patches/$patch" 2>/dev/null; then
    print -u2 "Не удалось применить исправление зависимости: $patch"
    exit 1
  fi
done
cp dependencies.resolved.json Vendor/mlx-audio-swift/Package.resolved
xcodegen generate
xcodebuild -project Pisa.xcodeproj -scheme Pisa -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
./scripts/package.sh
./scripts/make-dmg.sh
printf '%s\n' "Готово: $PWD/build/Build/Products/Release/Pisa.app"

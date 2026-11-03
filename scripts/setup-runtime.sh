#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor/Sherpa/lib
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
curl --fail --location --retry 3 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2' -o "$scratch/runtime.tar.bz2"
printf "%s  %s\n" "ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3" "$scratch/runtime.tar.bz2" | shasum -a 256 --check
tar -xjf "$scratch/runtime.tar.bz2" -C "$scratch"
cp "$scratch"/sherpa-onnx-*/lib/libonnxruntime.dylib "$scratch"/sherpa-onnx-*/lib/libsherpa-onnx-c-api.dylib Vendor/Sherpa/lib/

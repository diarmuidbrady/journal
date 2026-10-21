#!/bin/sh
# Downloads the pinned llama.cpp XCFramework (same release and checksum as
# Packages/LlamaCpp) into build/llama, for the Mac-side model checks.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/llama"
TAG=b11457
SHA=4c344f0b9ec2c972b2262eb45b2c5b23d6ff4a644135f40642a7a37336e94f1c

if [ ! -d "$WORK/llama.xcframework" ]; then
  mkdir -p "$WORK"
  curl -sSL -o "$WORK/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
  echo "$SHA  $WORK/llama.zip" | shasum -a 256 -c - >&2
  unzip -q -o "$WORK/llama.zip" -d "$WORK"
  mv "$WORK/build-apple/llama.xcframework" "$WORK/llama.xcframework"
fi
echo "$WORK/llama.xcframework/macos-arm64_x86_64"

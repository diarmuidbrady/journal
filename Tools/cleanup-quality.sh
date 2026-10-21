#!/bin/sh
# Runs the cleanup quality check on this Mac with the app's real cleanup code.
# Usage: Tools/cleanup-quality.sh path/to/model.gguf [report.md]
# The model file is the one the app downloads (see ModelSpec.current); keep it out of git.
set -eu

MODEL="${1:?usage: Tools/cleanup-quality.sh path/to/model.gguf [report.md]}"
REPORT="${2:-build/cleanup-quality.md}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/cleanup-quality"
TAG=b11457
SHA=4c344f0b9ec2c972b2262eb45b2c5b23d6ff4a644135f40642a7a37336e94f1c

mkdir -p "$WORK"
if [ ! -d "$WORK/llama.xcframework" ]; then
  curl -sSL -o "$WORK/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
  echo "$SHA  $WORK/llama.zip" | shasum -a 256 -c -
  unzip -q -o "$WORK/llama.zip" -d "$WORK"
  mv "$WORK/build-apple/llama.xcframework" "$WORK/llama.xcframework"
fi

FRAMEWORKS="$WORK/llama.xcframework/macos-arm64_x86_64"
AI="$ROOT/Journal/AI"
swiftc -O -swift-version 6 -F "$FRAMEWORKS" -framework llama -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$AI/TextModel.swift" "$AI/LlamaRunner.swift" "$AI/ModelSpec.swift" "$AI/Prompts.swift" "$AI/Cleanup.swift" \
  "$ROOT/Tools/CleanupQuality/main.swift" -o "$WORK/cleanup-quality"

"$WORK/cleanup-quality" "$ROOT/JournalTests/Fixtures/cleanup-samples.json" "$MODEL" "$REPORT" 2>/dev/null
echo "Report: $REPORT"

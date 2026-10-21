#!/bin/sh
# Runs the cleanup quality check on this Mac with the app's real cleanup code.
# Usage: Tools/cleanup-quality.sh path/to/model.gguf [report.md]
# The model file is the one the app downloads (see ModelSpec.current); keep it out of git.
set -eu

MODEL="${1:?usage: Tools/cleanup-quality.sh path/to/model.gguf [report.md]}"
REPORT="${2:-build/cleanup-quality.md}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$("$ROOT/Tools/fetch-llama.sh")"
AI="$ROOT/Journal/AI"

swiftc -O -swift-version 6 -F "$FRAMEWORKS" -framework llama -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$AI/TextModel.swift" "$AI/LlamaRunner.swift" "$AI/ModelSpec.swift" "$AI/Prompts.swift" "$AI/Cleanup.swift" \
  "$ROOT/Tools/CleanupQuality/main.swift" -o "$ROOT/build/cleanup-quality"

"$ROOT/build/cleanup-quality" "$ROOT/JournalTests/Fixtures/cleanup-samples.json" "$MODEL" "$REPORT" 2>/dev/null
echo "Report: $REPORT"

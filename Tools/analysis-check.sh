#!/bin/sh
# Runs the mood/summary/category analysis on this Mac with the app's real code and
# grammar over the invented sample entries, printing each result.
# Usage: Tools/analysis-check.sh path/to/model.gguf
set -eu

MODEL="${1:?usage: Tools/analysis-check.sh path/to/model.gguf}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$("$ROOT/Tools/fetch-llama.sh")"
AI="$ROOT/Journal/AI"

swiftc -O -swift-version 6 -F "$FRAMEWORKS" -framework llama -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$AI/TextModel.swift" "$AI/LlamaRunner.swift" "$AI/ModelSpec.swift" "$AI/Prompts.swift" "$AI/Cleanup.swift" "$AI/Analysis.swift" \
  "$ROOT/Tools/AnalysisCheck/main.swift" -o "$ROOT/build/analysis-check"

"$ROOT/build/analysis-check" "$ROOT/JournalTests/Fixtures/cleanup-samples.json" "$MODEL" 2>/dev/null

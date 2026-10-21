#!/bin/sh
# Checks search and Ask on this Mac with the app's real code and both models.
# Usage: Tools/ask-check.sh path/to/text-model.gguf path/to/embedding-model.gguf
set -eu

TEXT="${1:?usage: Tools/ask-check.sh text-model.gguf embedding-model.gguf}"
EMBEDDING="${2:?usage: Tools/ask-check.sh text-model.gguf embedding-model.gguf}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$("$ROOT/Tools/fetch-llama.sh")"
AI="$ROOT/Journal/AI"

swiftc -O -swift-version 6 -F "$FRAMEWORKS" -framework llama -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$AI/TextModel.swift" "$AI/LlamaRunner.swift" "$AI/ModelSpec.swift" "$AI/Prompts.swift" "$AI/Cleanup.swift" \
  "$AI/Citations.swift" "$ROOT/Journal/Storage/DayDate.swift" \
  "$ROOT/Tools/AskCheck/main.swift" -o "$ROOT/build/ask-check"

"$ROOT/build/ask-check" "$ROOT/JournalTests/Fixtures/cleanup-samples.json" "$TEXT" "$EMBEDDING" 2>/dev/null

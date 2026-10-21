// Cleanup quality check (SPEC.md, Quality check). Runs the app's real cleanup code
// with llama.cpp on a Mac over invented sample entries and reports which must-keep
// facts (names, numbers, negations) are missing. Run via Tools/cleanup-quality.sh.
import Foundation

struct Sample: Decodable {
    let id: String
    let text: String
    let must_keep: [String]
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: cleanup-quality <samples.json> <model.gguf> <report.md>")
    exit(2)
}
let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let modelURL = URL(fileURLWithPath: arguments[2])
let spec = [ModelSpec.qwen35_4B, .ministral3_3B].first { $0.fileName == modelURL.lastPathComponent } ?? .current
let model = LlamaTextModel(spec: spec, fileURL: modelURL)
let engine = CleanupEngine(model: model)

/// Curly apostrophes and case don't count as a change.
func normalised(_ text: String) -> String {
    text.lowercased().replacing("’", with: "'")
}

var report = "# Cleanup quality: \(spec.displayName)\n"
var kept = 0
var total = 0
var seconds = 0.0
try await model.runner.load()
for sample in samples {
    let start = Date.now
    let result = try await engine.clean(sample.text) { _, _, _ in }
    let elapsed = Date.now.timeIntervalSince(start)
    seconds += elapsed
    let missing = sample.must_keep.filter { !normalised(result.text).contains(normalised($0)) }
    kept += sample.must_keep.count - missing.count
    total += sample.must_keep.count
    print("\(sample.id): missing \(missing), \(result.warnings.count) warning(s)")
    report += """

        ## \(sample.id) (\(elapsed.formatted(.number.precision(.fractionLength(1))))s)
        Missing: \(missing)
        Warnings: \(result.warnings)

        \(result.text)

        """
}
await model.runner.unload()
let summary = "Kept \(kept)/\(total) must-keep items; average \((seconds / Double(samples.count)).formatted(.number.precision(.fractionLength(1))))s per entry"
print(summary)
try (report + "\n" + summary + "\n").write(toFile: arguments[3], atomically: true, encoding: .utf8)

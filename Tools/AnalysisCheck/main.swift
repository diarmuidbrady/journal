// Analysis check: runs the app's real mood/summary/category analysis with llama.cpp
// on a Mac over the invented sample entries and prints each result.
// Run via Tools/analysis-check.sh.
import Foundation

struct Sample: Decodable {
    let id: String
    let text: String
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: analysis-check <samples.json> <model.gguf>")
    exit(2)
}
let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let model = LlamaTextModel(spec: .current, fileURL: URL(fileURLWithPath: arguments[2]))
let analyzer = Analyzer(model: model)
let categories = ["Work", "Relationships", "Family", "Health", "Mind and emotions", "Money", "Personal growth", "Creativity", "Travel", "Dreams"]

try await model.runner.load()
var seconds = 0.0
for sample in samples {
    let start = Date.now
    let analysis = try await analyzer.analyze(sample.text, categories: categories)
    let elapsed = Date.now.timeIntervalSince(start)
    seconds += elapsed
    print("""
        \(sample.id) (\(elapsed.formatted(.number.precision(.fractionLength(1))))s): \(analysis.moodScore) \(analysis.moodLabel) \(analysis.emotions) | \(analysis.primaryCategory) + \(analysis.secondaryCategories) | themes \(analysis.themes) | suggest \(analysis.suggestedCategory ?? "-") | journal \(analysis.isJournal)
          \(analysis.summary)
        """)
}
await model.runner.unload()
print("Average \((seconds / Double(samples.count)).formatted(.number.precision(.fractionLength(1))))s per entry")

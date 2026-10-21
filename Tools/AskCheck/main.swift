// Ask check: embeds the invented sample entries with the real search model, checks
// that questions retrieve the expected entries, then answers one question with the
// real text model and lists its citations. Run via Tools/ask-check.sh.
import Foundation

struct Sample: Decodable {
    let id: String
    let text: String
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: ask-check <samples.json> <text-model.gguf> <embedding-model.gguf>")
    exit(2)
}
let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let textModel = LlamaTextModel(spec: .current, fileURL: URL(fileURLWithPath: arguments[2]))
let embedder = LlamaEmbeddingModel(spec: .currentEmbedding, fileURL: URL(fileURLWithPath: arguments[3]))

// Invented dates: one sample a day from 1 October 2026.
let dated = samples.enumerated().map { (index, sample) in (sample, DayDate(year: 2026, month: 10, day: index + 1)) }

var start = Date.now
var vectors: [String: [Float]] = [:]
for (sample, _) in dated { vectors[sample.id] = try await embedder.embed(document: sample.text) }
print("Embedded \(samples.count) entries in \(Date.now.timeIntervalSince(start).formatted(.number.precision(.fractionLength(2))))s (\(vectors.first!.value.count) dimensions)")

let retrievalChecks: [(question: String, expected: String)] = [
    ("Why am I sleeping badly?", "anxiety"),
    ("How do I feel about my friend moving abroad?", "swim"),
    ("What are my money worries?", "money"),
    ("How is my relationship with Conor?", "argument"),
    ("Am I making progress with exercise?", "run"),
]
var hits = 0
for check in retrievalChecks {
    let query = try await embedder.embed(query: check.question)
    let ranked = vectors.map { ($0.key, Vectors.dot(query, $0.value)) }.sorted { $0.1 > $1.1 }
    let top = ranked.prefix(3).map { "\($0.0) \($0.1.formatted(.number.precision(.fractionLength(2))))" }
    if ranked.first?.0 == check.expected { hits += 1 }
    print("\(ranked.first?.0 == check.expected ? "ok  " : "MISS") \(check.question) → \(top.joined(separator: ", "))")
}
print("Retrieval: \(hits)/\(retrievalChecks.count) expected entries ranked first")

let question = "What are my current blind spots?"
let context = dated.map { "\($0.1.string): \($0.0.text)" }.joined(separator: "\n")
start = .now
let answer = CleanupEngine.tidy(try await textModel.generate(
    [ChatMessage(role: .user, content: Prompts.ask(question, context: context))],
    options: GenerationOptions(maxTokens: 600, temperature: 0.4),
    onText: { _ in }
))
let cited = Citations.dates(in: answer)
let valid = Set(dated.map(\.1))
print("\nQ: \(question) (\(Date.now.timeIntervalSince(start).formatted(.number.precision(.fractionLength(1))))s)\n\(answer)")
print("\nCited \(cited.count) dates, \(cited.filter { !valid.contains($0) }.count) not in the entries")
await textModel.runner.unload()
await embedder.runner.unload()

import Foundation
import Testing
@testable import Journal

/// Deterministic stand-in for the search model: a hashed bag of words, so texts that
/// share words come out similar.
struct FakeEmbedder: EmbeddingModel {
    var identifier = "fake-embedder"

    func embed(document: String) async throws -> [Float] { Self.vector(document) }
    func embed(query: String) async throws -> [Float] { Self.vector(query) }

    static func vector(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 64)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count > 3 {
            vector[abs(word.hashValue) % 64] += 1
        }
        return Vectors.normalised(vector)
    }
}

/// Stand-in for the text model when answering: batch prompts get a note citing the
/// first date in the batch; the final prompt gets an answer citing that date and a
/// date that isn't in the journal.
final class FakeAskModel: TextModel, @unchecked Sendable {
    var identifier: String { "fake-model" }
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }

    func generate(_ messages: [ChatMessage], options: GenerationOptions, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let prompt = messages.last?.content ?? ""
        lock.withLock { _prompts.append(prompt) }
        let entries = prompt.components(separatedBy: "Entries").last ?? ""
        let firstDate = entries.firstMatch(of: /\d{4}-\d{2}-\d{2}/).map { String($0.output) } ?? "none"
        if prompt.contains("Write short notes") { return "You mention the pier. [\(firstDate)]" }
        let answer = "**You keep returning to the pier.** [\(firstDate)] You also wrote about it [1999-01-01]."
        onText(answer)
        return answer
    }
}

struct CitationTests {
    @Test func findsSingleAndListedDates() {
        let text = "One point [2026-10-14]. Two points [2026-10-15, 2026-10-16]. Not a citation 2026-10-17. Bad [2026-13-40]."
        #expect(Citations.dates(in: text) == [
            DayDate(year: 2026, month: 10, day: 14),
            DayDate(year: 2026, month: 10, day: 15),
            DayDate(year: 2026, month: 10, day: 16),
        ])
    }

    @Test func linksOnlyRealEntryDatesAndRendersMarkdown() {
        let real = DayDate(year: 2026, month: 10, day: 14)
        let linked = Citations.linked("**Bold** point [2026-10-14] and invented [1999-01-01].", validDates: [real])
        #expect(!String(linked.characters).contains("**"))
        let links = linked.runs.compactMap(\.link)
        #expect(links == [URL(string: "journal://day/2026-10-14")!])
    }

    @Test func citedEntriesComeFromSourcesOnly() {
        let id = UUID()
        let sources = [AskSource(entryID: id, date: DayDate(year: 2026, month: 10, day: 14), line: "")]
        #expect(Citations.entryIDs(citedIn: "[2026-10-14] [1999-01-01]", sources: sources) == [id])
    }
}

struct AskEngineTests {
    private func add(_ test: TestDatabase, daysAgo: Int, text: String, summary: String? = nil, mood: Double? = nil, category: String? = nil) async throws -> Entry {
        var entry = Entry.newTyped(on: DayDate(Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!))
        entry.originalText = text
        entry.summary = summary
        entry.moodScore = mood
        entry.primaryCategory = category
        entry.needsAnalysis = false
        try await test.store.save(entry)
        return entry
    }

    @Test func rangeUsesSummariesWithMoodAndCitesEntries() async throws {
        let test = try TestDatabase()
        let recent = try await add(test, daysAgo: 1, text: "Long text about the pier.", summary: "You walked to the pier.", mood: 0.5, category: "Health")
        _ = try await add(test, daysAgo: 30, text: "Old entry.", summary: "Too old.")
        let model = FakeAskModel()
        let engine = AskEngine(model: model, embedder: nil, store: test.store)

        let answer = try await engine.answer(
            "What did I do?",
            scope: .range(DayDate(Calendar.current.date(byAdding: .day, value: -6, to: .now)!), .today)
        ) { _ in }

        #expect(answer.sources.count == 1)
        #expect(answer.sources[0].line == "\(recent.entryDate.string) (mood 0.5): You walked to the pier.")
        #expect(model.prompts.count == 1)
        #expect(model.prompts[0].contains("Question: What did I do?"))
        #expect(answer.citedEntryIDs == [recent.id])
        #expect(answer.aiVersion == "ask-v1@fake-model")
    }

    @Test func categoryFilterAndEmptyScope() async throws {
        let test = try TestDatabase()
        _ = try await add(test, daysAgo: 1, text: "Work stuff.", summary: "Work.", category: "Work")
        let engine = AskEngine(model: FakeAskModel(), embedder: nil, store: test.store)
        let week = AskScope.range(DayDate(Calendar.current.date(byAdding: .day, value: -6, to: .now)!), .today)

        let sources = try await engine.gatherSources(question: "q", scope: week, category: "Health")
        #expect(sources.isEmpty)
        await #expect(throws: AskError.self) {
            _ = try await engine.answer("q", scope: week, category: "Health") { _ in }
        }
    }

    @Test func allEntriesNeedsSearchModelAndRetrievesBySimilarity() async throws {
        let test = try TestDatabase()
        let pier = try await add(test, daysAgo: 2, text: "Walked along the pier watching boats and seagulls.")
        _ = try await add(test, daysAgo: 1, text: "Spreadsheet budgets and invoices at the office.")
        for entry in try await test.store.fetchAll() {
            try await test.store.applyEmbedding(FakeEmbedder.vector(entry.analysisText), to: entry.id, embeddedText: entry.analysisText, aiVersion: "e")
        }

        await #expect(throws: AskError.self) {
            _ = try await AskEngine(model: FakeAskModel(), embedder: nil, store: test.store).answer("q", scope: .all) { _ in }
        }

        let engine = AskEngine(model: FakeAskModel(), embedder: FakeEmbedder(), store: test.store)
        let sources = try await engine.gatherSources(question: "When did I watch the boats at the pier?", scope: .all, category: nil)
        #expect(sources.first?.entryID == pier.id || sources.contains { $0.entryID == pier.id })
        let ranked = try await test.store.embeddings(category: nil)
            .map { ($0.id, Vectors.dot(FakeEmbedder.vector("boats pier seagulls"), $0.vector)) }
            .sorted { $0.1 > $1.1 }
        #expect(ranked.first?.0 == pier.id)
    }

    @Test func largeRangesAreSummarisedInBatches() async throws {
        let test = try TestDatabase()
        let long = String(repeating: "A long day by the pier with lots to say. ", count: 7)
        for day in 0..<40 { _ = try await add(test, daysAgo: day, text: long) }
        let model = FakeAskModel()
        let stages = StageLog()

        let answer = try await AskEngine(model: model, embedder: nil, store: test.store).answer(
            "What happened?",
            scope: .range(DayDate(Calendar.current.date(byAdding: .day, value: -60, to: .now)!), .today)
        ) { stages.add($0) }

        let batchPrompts = model.prompts.filter { $0.contains("Write short notes") }
        #expect(batchPrompts.count >= 2)
        #expect(batchPrompts.allSatisfy { $0.count < AskEngine.contextBudget + 1_000 })
        #expect(model.prompts.last!.contains("You mention the pier."))
        #expect(stages.stages.contains(.summarising(batch: 0, of: batchPrompts.count)))
        #expect(answer.sources.count == 40)
    }

    @Test func oneEntryScope() async throws {
        let test = try TestDatabase()
        let entry = try await add(test, daysAgo: 0, text: "Just this one.")
        let answer = try await AskEngine(model: FakeAskModel(), embedder: nil, store: test.store)
            .answer("What's this about?", scope: .entry(entry.id)) { _ in }
        #expect(answer.sources.map(\.entryID) == [entry.id])
        #expect(answer.citedEntryIDs == [entry.id])
    }

    final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _stages: [AskStage] = []
        var stages: [AskStage] { lock.withLock { _stages } }
        func add(_ stage: AskStage) { lock.withLock { _stages.append(stage) } }
    }
}

@MainActor
struct EmbeddingPassTests {
    @Test func queueEmbedsAfterAnalysis() async throws {
        let test = try TestDatabase()
        var entry = Entry.newTyped()
        entry.originalText = "The clutch went again."
        try await test.store.save(entry)
        let queue = AnalysisQueue()

        let task = Task { await queue.run(store: test.store, model: FakeAnalysisModel(reply: FakeAnalysisModel.json()), embedder: FakeEmbedder()) }
        defer { task.cancel() }
        for _ in 0..<200 where try await test.store.fetch(id: entry.id)?.embedding == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let stored = try #require(try await test.store.fetch(id: entry.id))
        #expect(!stored.needsAnalysis)
        #expect(Vectors.vector(try #require(stored.embedding)) == FakeEmbedder.vector("The clutch went again."))
        #expect(stored.aiVersion?.contains("embedding-v1@fake-embedder") == true)
    }

    @Test func textChangeClearsEmbedding() async throws {
        let test = try TestDatabase()
        let model = EntryEditorModel(store: test.store, entry: .newTyped(), isPersisted: false, saveInterval: .seconds(60))
        model.text = "First version."
        await model.flush()
        try await test.store.applyEmbedding([1, 0], to: model.entry.id, embeddedText: "First version.", aiVersion: "e")

        model.text = "Second version."
        await model.flush()

        #expect(try await test.store.fetch(id: model.entry.id)?.embedding == nil)
    }

    @Test func changingSearchModelClearsEmbeddings() async throws {
        let test = try TestDatabase()
        var entry = Entry.newTyped()
        entry.originalText = "Text."
        entry.embedding = Vectors.data([1, 0])
        try await test.store.save(entry)

        try await test.store.ensureEmbeddingModel("model-a")
        #expect(try await test.store.fetch(id: entry.id)?.embedding == nil, "first run records the model and starts fresh")

        try await test.store.applyEmbedding([1, 0], to: entry.id, embeddedText: "Text.", aiVersion: "e")
        try await test.store.ensureEmbeddingModel("model-a")
        #expect(try await test.store.fetch(id: entry.id)?.embedding != nil, "same model keeps them")

        try await test.store.ensureEmbeddingModel("model-b")
        #expect(try await test.store.fetch(id: entry.id)?.embedding == nil)
    }
}

struct ReflectionTests {
    @Test func saveListDeleteAndExport() async throws {
        let test = try TestDatabase()
        let reflection = Reflection(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_760_000_000), question: "What keeps coming up?",
            answer: "The pier. [2026-10-14]", scope: "range",
            rangeStart: DayDate(year: 2026, month: 10, day: 1), rangeEnd: DayDate(year: 2026, month: 10, day: 21),
            category: "Health", citedEntryIds: [UUID()], aiVersion: "ask-v1@fake"
        )
        try await test.store.saveReflection(reflection)
        #expect(try await test.store.reflections() == [reflection])
        #expect(reflection.scopeDescription.hasSuffix("· Health"))

        let exported = try JournalExport.decode(try await JournalExport.make(from: test.store).encoded())
        #expect(exported.reflections.map(\.question) == ["What keeps coming up?"])

        try await test.store.deleteReflection(id: reflection.id)
        #expect(try await test.store.reflections().isEmpty)
    }
}

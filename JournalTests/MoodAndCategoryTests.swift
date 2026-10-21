import Foundation
import Testing
@testable import Journal

/// Stands in for the model during analysis: returns fixed JSON and records whether a
/// grammar was supplied. A `nil` reply makes it fail.
final class FakeAnalysisModel: TextModel, @unchecked Sendable {
    var identifier: String { "fake-model" }
    let reply: String?
    private let lock = NSLock()
    private var _grammars: [String?] = []
    var grammars: [String?] { lock.withLock { _grammars } }
    var calls: Int { grammars.count }

    init(reply: String?) { self.reply = reply }

    static func json(score: Double = -0.4, primary: String = "Work", secondary: [String] = ["Money"], suggestion: String? = nil) -> String {
        let secondaryList = secondary.map { "\"\($0)\"" }.joined(separator: ",")
        let suggested = suggestion.map { "\"\($0)\"" } ?? "null"
        return """
            {"mood_score": \(score), "mood_label": "Worried", "emotions": ["Worried", "tired", "worried"], "summary": " You worried about the clutch. ", "themes": ["Car", "money", "car", "garage", "bray", "extra"], "primary_category": "\(primary)", "secondary_categories": [\(secondaryList)], "suggested_category": \(suggested), "is_journal": true}
            """
    }

    func generate(_ messages: [ChatMessage], options: GenerationOptions, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { _grammars.append(options.grammar) }
        guard let reply else { throw FakeTranscriber.Failure() }
        return reply
    }
}

struct AnalysisParsingTests {
    let categories = Category.defaultNames

    @Test func parsesAndTidies() throws {
        let analysis = try Analyzer.parse(FakeAnalysisModel.json(score: -1.4, secondary: ["Money", "Work", "Nonsense"]), categories: categories)
        #expect(analysis.moodScore == -1)
        #expect(analysis.moodLabel == "worried")
        #expect(analysis.emotions == ["worried", "tired"])
        #expect(analysis.themes == ["car", "money", "garage", "bray", "extra"])
        #expect(analysis.summary == "You worried about the clutch.")
        #expect(analysis.secondaryCategories == ["Money"], "drops the primary and unknown names")
    }

    @Test func ignoresSuggestionAlreadyOnTheList() throws {
        #expect(try Analyzer.parse(FakeAnalysisModel.json(suggestion: "work"), categories: categories).suggestedCategory == nil)
        #expect(try Analyzer.parse(FakeAnalysisModel.json(suggestion: "Cars"), categories: categories).suggestedCategory == "Cars")
    }

    @Test func grammarListsEveryCategory() {
        let grammar = AnalysisGrammar.make(categories: ["Work", "Mind and emotions"])
        #expect(grammar.contains(#"category ::= "\"Work\"" | "\"Mind and emotions\"""#))
        #expect(grammar.contains("root ::="))
    }

    @Test func longEntriesAreExcerpted() {
        let long = String(repeating: "word ", count: 3_000)
        let excerpt = Analyzer.excerpt(long)
        #expect(excerpt.count < Analyzer.maxCharacters)
        #expect(excerpt.contains("[…]"))
    }

    @Test func aiVersionMergesPerPrompt() {
        let legacy = "cleanup-v1;qwen3.5-4b-q4_k_m"
        let merged = AIVersion.merging(legacy, "analysis-v1@qwen3.5-4b-q4_k_m")
        #expect(merged == "analysis-v1@qwen3.5-4b-q4_k_m;cleanup-v1@qwen3.5-4b-q4_k_m")
        #expect(AIVersion.merging(merged, "analysis-v2@other") == "analysis-v2@other;cleanup-v1@qwen3.5-4b-q4_k_m")
    }
}

struct ApplyAnalysisTests {
    private func saved(_ test: TestDatabase, text: String = "The clutch went again.", configure: (inout Entry) -> Void = { _ in }) async throws -> Entry {
        var entry = Entry.newTyped()
        entry.originalText = text
        configure(&entry)
        try await test.store.save(entry)
        return entry
    }

    @Test func storesAnalysisAndClearsFlag() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test)
        let analysis = try Analyzer.parse(FakeAnalysisModel.json(), categories: Category.defaultNames)

        let stored = try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: entry.analysisText, aiVersion: "analysis-v1@fake")

        let result = try #require(try await test.store.fetch(id: entry.id))
        #expect(stored)
        #expect(result.moodScore == -0.4)
        #expect(result.primaryCategory == "Work")
        #expect(result.secondaryCategories == ["Money"])
        #expect(result.summary == "You worried about the clutch.")
        #expect(result.isJournal == true)
        #expect(!result.needsAnalysis)
        #expect(result.aiVersion == "analysis-v1@fake")
    }

    @Test func manualValuesWin() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test)
        try await test.store.setManualMood(0.8, label: "Great", for: entry.id)
        try await test.store.setManualCategories(primary: "Travel", secondary: ["Family"], for: entry.id)

        let analysis = try Analyzer.parse(FakeAnalysisModel.json(), categories: Category.defaultNames)
        try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: entry.analysisText, aiVersion: "analysis-v1@fake")

        let result = try #require(try await test.store.fetch(id: entry.id))
        #expect(result.moodScore == 0.8)
        #expect(result.moodLabel == "great")
        #expect(result.primaryCategory == "Travel")
        #expect(result.secondaryCategories == ["Family"])
        #expect(result.summary == "You worried about the clutch.", "the model still fills the rest")
    }

    @Test func resetHandsBackToTheModel() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test)
        try await test.store.setManualMood(0.8, label: "great", for: entry.id)
        try await test.store.resetToAutomatic(mood: true, categories: false, for: entry.id)

        let result = try #require(try await test.store.fetch(id: entry.id))
        #expect(!result.moodManual)
        #expect(result.needsAnalysis)
    }

    @Test func skipsIfTextChangedWhileAnalysing() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test)
        let analysis = try Analyzer.parse(FakeAnalysisModel.json(), categories: Category.defaultNames)

        let stored = try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: "something older", aiVersion: "analysis-v1@fake")

        #expect(!stored)
        #expect(try await test.store.fetch(id: entry.id)?.needsAnalysis == true)
    }

    @Test func logEntriesGetNoMood() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test) { $0.sourceKind = .log }
        let analysis = try Analyzer.parse(FakeAnalysisModel.json(), categories: Category.defaultNames)
        try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: entry.analysisText, aiVersion: "analysis-v1@fake")

        let result = try #require(try await test.store.fetch(id: entry.id))
        #expect(result.moodScore == nil)
        #expect(result.primaryCategory == "Work")
    }

    @Test func suggestionWaitsAsPendingAndIsNotRepeatedOnceDismissed() async throws {
        let test = try TestDatabase()
        let entry = try await saved(test)
        let analysis = try Analyzer.parse(FakeAnalysisModel.json(suggestion: "Cars"), categories: Category.defaultNames)
        try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: entry.analysisText, aiVersion: "v")

        #expect(try await test.store.categories().first { $0.name == "Cars" }?.status == .pending)
        #expect(try await !test.store.activeCategoryNames().contains("Cars"))

        try await test.store.dismissSuggestion("Cars")
        try await test.store.applyAnalysis(analysis, to: entry.id, analysedText: entry.analysisText, aiVersion: "v")
        #expect(try await test.store.categories().filter { $0.name == "Cars" }.map(\.status) == [.dismissed])
    }
}

@MainActor
struct EditorAndAnalysisTests {
    @Test func editorDoesNotOverwriteAnalysis() async throws {
        let test = try TestDatabase()
        let model = EntryEditorModel(store: test.store, entry: .newTyped(), isPersisted: false, saveInterval: .seconds(60))
        model.text = "The clutch went again."
        await model.flush()
        let id = model.entry.id

        let analysis = try Analyzer.parse(FakeAnalysisModel.json(), categories: Category.defaultNames)
        try await test.store.applyAnalysis(analysis, to: id, analysedText: "The clutch went again.", aiVersion: "v")

        // The editor's copy is now stale; a title edit must keep the analysis.
        model.title = "Car trouble"
        await model.flush()
        var stored = try #require(try await test.store.fetch(id: id))
        #expect(stored.title == "Car trouble")
        #expect(stored.moodScore == -0.4)
        #expect(!stored.needsAnalysis, "a title change doesn't need analysis")

        model.text += " Rang the garage."
        await model.flush()
        stored = try #require(try await test.store.fetch(id: id))
        #expect(stored.moodScore == -0.4)
        #expect(stored.needsAnalysis, "a text change does")
    }
}

@MainActor
struct AnalysisQueueTests {
    @Test func analysesWaitingEntriesNewestFirst() async throws {
        let test = try TestDatabase()
        for daysAgo in [3, 1, 2] {
            var entry = Entry.newTyped(on: DayDate(Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!))
            entry.originalText = "Entry from \(daysAgo) days ago."
            try await test.store.save(entry)
        }
        let model = FakeAnalysisModel(reply: FakeAnalysisModel.json())
        let queue = AnalysisQueue()

        let task = Task { await queue.run(store: test.store, model: model) }
        defer { task.cancel() }
        for _ in 0..<200 where try await test.store.fetchAll().contains(where: \.needsAnalysis) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let entries = try await test.store.fetchAll()
        #expect(entries.allSatisfy { !$0.needsAnalysis && $0.moodScore == -0.4 })
        #expect(model.calls == 3)
        #expect(model.grammars.allSatisfy { $0?.contains("root ::=") == true }, "output is grammar-constrained")
    }

    @Test func waitsWhileAnEditorIsOpen() async throws {
        let test = try TestDatabase()
        var entry = Entry.newTyped()
        entry.originalText = "Something to read."
        try await test.store.save(entry)
        let model = FakeAnalysisModel(reply: FakeAnalysisModel.json())
        let queue = AnalysisQueue()
        queue.editorOpened()

        let task = Task { await queue.run(store: test.store, model: model) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        #expect(model.calls == 0)
        #expect(try await test.store.fetch(id: entry.id)?.needsAnalysis == true)
    }

    @Test func failureIsReportedAndEntryStaysQueued() async throws {
        let test = try TestDatabase()
        var entry = Entry.newTyped()
        entry.originalText = "Something to read."
        try await test.store.save(entry)
        let queue = AnalysisQueue()

        let task = Task { await queue.run(store: test.store, model: FakeAnalysisModel(reply: nil)) }
        for _ in 0..<200 where queue.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()

        #expect(queue.lastError != nil)
        #expect(try await test.store.fetch(id: entry.id)?.needsAnalysis == true)
    }
}

struct CategoryListTests {
    @Test func validatesNames() {
        #expect(CategoryName.validated("  Side   projects ") == "Side projects")
        #expect(CategoryName.validated("Health & fitness") == "Health & fitness")
        #expect(CategoryName.validated("") == nil)
        #expect(CategoryName.validated("Bad\"name") == nil)
        #expect(CategoryName.validated(String(repeating: "a", count: 31)) == nil)
    }

    @Test func addRenameDeleteKeepEntriesConsistent() async throws {
        let test = try TestDatabase()
        var entry = Entry.newTyped()
        entry.originalText = "Run."
        entry.primaryCategory = "Health"
        entry.secondaryCategories = ["Work"]
        entry.needsAnalysis = false
        try await test.store.save(entry)

        try await test.store.addCategory("Running")
        await #expect(throws: EntryStore.CategoryError.self) { try await test.store.addCategory("running") }

        try await test.store.renameCategory("Health", to: "Fitness")
        var stored = try #require(try await test.store.fetch(id: entry.id))
        #expect(stored.primaryCategory == "Fitness")

        try await test.store.deleteCategory("Work")
        stored = try #require(try await test.store.fetch(id: entry.id))
        #expect(stored.secondaryCategories.isEmpty)

        let names = try await test.store.activeCategoryNames()
        #expect(names.contains("Fitness") && names.contains("Running") && !names.contains("Health") && !names.contains("Work"))
    }

    @Test func recategoriseSkipsManualChoices() async throws {
        let test = try TestDatabase()
        var automatic = Entry.newTyped()
        automatic.originalText = "a"
        automatic.needsAnalysis = false
        var manual = Entry.newTyped()
        manual.originalText = "b"
        manual.needsAnalysis = false
        manual.categoriesManual = true
        try await test.store.save(automatic)
        try await test.store.save(manual)

        try await test.store.recategoriseAll()

        #expect(try await test.store.fetch(id: automatic.id)?.needsAnalysis == true)
        #expect(try await test.store.fetch(id: manual.id)?.needsAnalysis == false)
    }
}

struct MoodCalendarTests {
    private func entry(_ day: Int, mood: Double?, emotions: [String] = [], month: Int = 10) -> Entry {
        var entry = Entry.newTyped(on: DayDate(year: 2026, month: month, day: day))
        entry.moodScore = mood
        entry.emotions = emotions
        return entry
    }

    @Test func averagesDaysAndMonth() {
        let summary = MonthSummary(year: 2026, month: 10, entries: [
            entry(5, mood: -0.4, emotions: ["tired"]),
            entry(5, mood: 0.0, emotions: ["calm", "tired"]),
            entry(5, mood: nil),
            entry(9, mood: 0.8, emotions: ["calm"]),
            entry(20, mood: nil),
            entry(1, mood: 1.0, month: 9),
        ])
        let fifth = summary.days[DayDate(year: 2026, month: 10, day: 5)]
        #expect(fifth?.entryCount == 3)
        #expect(fifth?.averageMood == -0.2)
        #expect(summary.days[DayDate(year: 2026, month: 10, day: 20)]?.averageMood == nil)
        #expect(summary.entryCount == 5)
        #expect(abs(summary.averageMood! - 0.4 / 3) < 0.0001)
        #expect(summary.topEmotion == "calm", "tie between calm and tired broken alphabetically")
        #expect(summary.line == "5 entries · average mood +0.1 · most often calm")
    }

    @Test func noTopEmotionWithoutRepeats() {
        let summary = MonthSummary(year: 2026, month: 10, entries: [entry(1, mood: 0.2, emotions: ["calm"]), entry(2, mood: 0.2, emotions: ["tired"])])
        #expect(summary.topEmotion == nil)
        #expect(MonthSummary(year: 2026, month: 11, entries: []).line == "No entries this month")
    }

    @Test func weeksStartOnMondayInIreland() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let weeks = MonthSummary(year: 2026, month: 10, entries: []).weeks(calendar: calendar)
        // 1 October 2026 is a Thursday.
        #expect(weeks[0].prefix(3).allSatisfy { $0 == nil })
        #expect(weeks[0][3] == DayDate(year: 2026, month: 10, day: 1))
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(weeks.flatMap { $0 }.compactMap { $0 }.count == 31)
    }

    @Test func moodStepsAreSymmetric() {
        #expect(MoodScale.step(for: -1) == 0)
        #expect(MoodScale.step(for: 0) == 4)
        #expect(MoodScale.step(for: 0.1) == 4)
        #expect(MoodScale.step(for: -0.1) == 4)
        #expect(MoodScale.step(for: 1) == 8)
        #expect(MoodScale.step(for: 0.5) == 8 - MoodScale.step(for: -0.5))
    }
}

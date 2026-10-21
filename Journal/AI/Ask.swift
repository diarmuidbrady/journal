import Foundation

/// What a question is asked about (SPEC.md, Ask the journal).
enum AskScope: Hashable, Sendable {
    case entry(UUID)
    /// Inclusive.
    case range(DayDate, DayDate)
    case all

    /// Stored in `reflections.scope`.
    var kind: String {
        switch self {
        case .entry: "entry"
        case .range: "range"
        case .all: "all"
        }
    }
}

/// One entry as the model sees it: a dated line of summary or text.
struct AskSource: Sendable, Equatable {
    var entryID: UUID
    var date: DayDate
    var line: String
}

struct AskAnswer: Sendable, Equatable {
    var question: String
    var text: String
    var sources: [AskSource]
    var citedEntryIDs: [UUID]
    var aiVersion: String
}

enum AskStage: Equatable, Sendable {
    case finding
    case summarising(batch: Int, of: Int)
    case answering(String)
}

enum AskError: LocalizedError {
    case noEntries
    case needsSearchModel

    var errorDescription: String? {
        switch self {
        case .noEntries: "There are no entries to answer from in this scope."
        case .needsSearchModel: "Searching all entries needs the search model. Download it in Settings → AI models, or ask about a date range instead."
        }
    }
}

/// Gathers entries for a question, fits them to the model's context (summarising in
/// batches if needed), and answers with dated citations.
struct AskEngine: Sendable {
    let model: any TextModel
    let embedder: (any EmbeddingModel)?
    let store: EntryStore

    /// Characters of entry material per prompt: about 2,500 tokens, leaving room for
    /// the instructions and a 600-token answer in the 4,096-token context.
    static let contextBudget = 9_000
    /// Entries retrieved for "all entries".
    static let retrievalCount = 12

    func answer(
        _ question: String,
        scope: AskScope,
        category: String? = nil,
        progress: @escaping @Sendable (AskStage) -> Void
    ) async throws -> AskAnswer {
        progress(.finding)
        let sources = try await gatherSources(question: question, scope: scope, category: category)
        guard !sources.isEmpty else { throw AskError.noEntries }

        var context = sources.map(\.line).joined(separator: "\n")
        if context.count > Self.contextBudget {
            let batches = Self.batches(sources.map(\.line), budget: Self.contextBudget)
            var notes: [String] = []
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                progress(.summarising(batch: index, of: batches.count))
                let note = try await model.generate(
                    [ChatMessage(role: .user, content: Prompts.askBatch(question, entries: batch))],
                    options: GenerationOptions(maxTokens: 400, temperature: 0.3),
                    onText: { _ in }
                )
                let tidy = CleanupEngine.tidy(note)
                if !tidy.localizedCaseInsensitiveContains("nothing relevant") { notes.append(tidy) }
            }
            context = String(notes.joined(separator: "\n").prefix(Self.contextBudget))
            if context.isEmpty { context = "(None of these entries mention anything relevant.)" }
        }

        try Task.checkCancellation()
        progress(.answering(""))
        let output = try await model.generate(
            [ChatMessage(role: .user, content: Prompts.ask(question, context: context))],
            options: GenerationOptions(maxTokens: 500, temperature: 0.4),
            onText: { progress(.answering(CleanupEngine.tidy($0))) }
        )
        let text = CleanupEngine.tidy(output)
        return AskAnswer(
            question: question,
            text: text,
            sources: sources,
            citedEntryIDs: Citations.entryIDs(citedIn: text, sources: sources),
            aiVersion: "\(Prompts.askVersion)@\(model.identifier)"
        )
    }

    func gatherSources(question: String, scope: AskScope, category: String?) async throws -> [AskSource] {
        switch scope {
        case .entry(let id):
            guard let entry = try await store.fetch(id: id), !entry.analysisText.isEmpty else { return [] }
            return [AskSource(entryID: id, date: entry.entryDate, line: Self.line(entry, body: Self.excerpt(entry.analysisText, limit: Self.contextBudget)))]

        case .range(let start, let end):
            let entries = try await store.entries(from: start, through: end, category: category)
            // SPEC.md: a range is answered from summaries; text stands in until one exists.
            return entries.map { entry in
                AskSource(entryID: entry.id, date: entry.entryDate, line: Self.line(entry, body: entry.summary ?? Self.excerpt(entry.analysisText, limit: 300)))
            }

        case .all:
            guard let embedder else { throw AskError.needsSearchModel }
            let query = try await embedder.embed(query: question)
            let candidates = try await store.embeddings(category: category)
            let ranked = candidates
                .map { (id: $0.id, score: Vectors.dot(query, $0.vector)) }
                .sorted { $0.score > $1.score }
                .prefix(Self.retrievalCount)
            let entries = try await store.entries(ids: ranked.map(\.id))
            return entries.map { entry in
                AskSource(entryID: entry.id, date: entry.entryDate, line: Self.line(entry, body: Self.excerpt(entry.analysisText, limit: 700)))
            }
        }
    }

    /// "2026-10-14 (mood -0.3, worried): text"
    static func line(_ entry: Entry, body: String) -> String {
        var details: [String] = []
        if let score = entry.moodScore {
            details.append("mood \(score.formatted(.number.precision(.fractionLength(1))))")
        }
        if let label = entry.moodLabel, !label.isEmpty { details.append(label) }
        let prefix = details.isEmpty ? entry.entryDate.string : "\(entry.entryDate.string) (\(details.joined(separator: ", ")))"
        return "\(prefix): \(body.replacing(/\s*\n\s*/, with: " "))"
    }

    static func excerpt(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Groups lines into batches under `budget` characters, keeping order.
    static func batches(_ lines: [String], budget: Int) -> [String] {
        var batches: [String] = []
        var current = ""
        for line in lines {
            let line = String(line.prefix(budget))
            if !current.isEmpty, current.count + line.count + 1 > budget {
                batches.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

extension Citations {
    /// Entries the answer drew on: those in the sources whose date it cites.
    static func entryIDs(citedIn text: String, sources: [AskSource]) -> [UUID] {
        let cited = Set(dates(in: text))
        var ids: [UUID] = []
        for source in sources where cited.contains(source.date) && !ids.contains(source.entryID) {
            ids.append(source.entryID)
        }
        return ids
    }
}

import Foundation

/// Works through entries in the background, newest first, one at a time: first the
/// analysis (mood, summary, themes, categories) for entries marked `needs_analysis`,
/// then an embedding for search. Runs only while the app is active and unlocked, the
/// models are ready and nothing has paused it (an open editor, a question being
/// answered), so it never competes with foreground model use. Progress lives in the
/// database, so the pass resumes after the app closes.
@MainActor
@Observable
final class AnalysisQueue {
    private(set) var pending = 0
    private(set) var currentEntryID: UUID?
    private(set) var lastError: String?

    /// Foreground work holding the queue (open editors, questions being answered).
    private(set) var pauseCount = 0

    /// Entries that failed this session; skipped until the app restarts.
    private var failed: Set<UUID> = []

    var isWorking: Bool { currentEntryID != nil }
    var isPaused: Bool { pauseCount > 0 }

    func pause() { pauseCount += 1 }
    func resume() { pauseCount = max(0, pauseCount - 1) }

    /// Runs until cancelled. Restart it (via `.task(id:)`) when its conditions change.
    /// Without a search model, only the analysis runs.
    func run(store: EntryStore, model: any TextModel, embedder: (any EmbeddingModel)? = nil) async {
        let analyzer = Analyzer(model: model)
        do {
            if let embedder { try await store.ensureEmbeddingModel(embedder.identifier) }
            for try await count in store.observePendingAnalysisCount() {
                pending = count
                while !Task.isCancelled, !isPaused,
                      let entry = try await store.nextEntryNeedingAnalysis(excluding: failed) {
                    await analyze(entry, store: store, analyzer: analyzer)
                }
                if let embedder {
                    while !Task.isCancelled, !isPaused,
                          let entry = try await store.nextEntryNeedingEmbedding(excluding: failed) {
                        await embed(entry, store: store, embedder: embedder)
                    }
                }
                if Task.isCancelled { break }
            }
        } catch {
            lastError = error.localizedDescription
        }
        currentEntryID = nil
    }

    private func analyze(_ entry: Entry, store: EntryStore, analyzer: Analyzer) async {
        await work(on: entry) {
            let text = entry.analysisText
            // Nothing to read: clear the flag without asking the model.
            let analysis = text.isEmpty
                ? nil
                : try await analyzer.analyze(text, categories: try await store.activeCategoryNames())
            try await store.applyAnalysis(analysis, to: entry.id, analysedText: text, aiVersion: analyzer.aiVersion)
        }
    }

    private func embed(_ entry: Entry, store: EntryStore, embedder: any EmbeddingModel) async {
        await work(on: entry) {
            let text = entry.analysisText
            let vector = text.isEmpty ? [] : try await embedder.embed(document: Analyzer.excerpt(text))
            try await store.applyEmbedding(vector, to: entry.id, embeddedText: text, aiVersion: "\(Prompts.embeddingVersion)@\(embedder.identifier)")
        }
    }

    private func work(on entry: Entry, _ body: () async throws -> Void) async {
        currentEntryID = entry.id
        defer { currentEntryID = nil }
        do {
            try await body()
            lastError = nil
        } catch is CancellationError {
            // Stopped (background, paused); the entry stays queued.
        } catch {
            failed.insert(entry.id)
            lastError = error.localizedDescription
        }
    }
}

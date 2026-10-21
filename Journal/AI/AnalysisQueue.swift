import Foundation

/// Works through entries marked `needs_analysis`, newest first, one at a time, and
/// stores their mood, summary, themes and categories. Runs only while the app is
/// active, unlocked, the model is ready and no entry is open in the editor, so it
/// never competes with typing, recording or cleanup. The flag lives in the database,
/// so the pass resumes after the app closes.
@MainActor
@Observable
final class AnalysisQueue {
    private(set) var pending = 0
    private(set) var currentEntryID: UUID?
    private(set) var lastError: String?

    /// Editors currently on screen. The queue pauses while any are open.
    private(set) var openEditors = 0

    /// Entries that failed this session; skipped until the app restarts.
    private var failed: Set<UUID> = []

    var isWorking: Bool { currentEntryID != nil }

    func editorOpened() { openEditors += 1 }
    func editorClosed() { openEditors = max(0, openEditors - 1) }

    /// Runs until cancelled. Restart it (via `.task(id:)`) when its conditions change.
    func run(store: EntryStore, model: any TextModel) async {
        let analyzer = Analyzer(model: model)
        do {
            for try await count in store.observePendingAnalysisCount() {
                pending = count
                while !Task.isCancelled, openEditors == 0,
                      let entry = try await store.nextEntryNeedingAnalysis(excluding: failed) {
                    await analyze(entry, store: store, analyzer: analyzer)
                }
                if Task.isCancelled { break }
            }
        } catch {
            lastError = error.localizedDescription
        }
        currentEntryID = nil
    }

    private func analyze(_ entry: Entry, store: EntryStore, analyzer: Analyzer) async {
        currentEntryID = entry.id
        defer { currentEntryID = nil }
        let text = entry.analysisText
        do {
            // Nothing to read: clear the flag without asking the model.
            let analysis = text.isEmpty
                ? nil
                : try await analyzer.analyze(text, categories: try await store.activeCategoryNames())
            try await store.applyAnalysis(analysis, to: entry.id, analysedText: text, aiVersion: analyzer.aiVersion)
            lastError = nil
        } catch is CancellationError {
            // Stopped (background, editor opened); the entry stays queued.
        } catch {
            failed.insert(entry.id)
            lastError = error.localizedDescription
        }
    }
}

import Foundation
import GRDB

/// Reads and writes entries, their recordings and categories. Exists only while the
/// vault is unlocked.
final class EntryStore: Sendable {
    let database: AppDatabase
    let paths: VaultPaths

    init(database: AppDatabase, paths: VaultPaths) {
        self.database = database
        self.paths = paths
    }

    private static let newestFirst = [Entry.Columns.entryDate.desc, Entry.Columns.createdAt.desc]

    // MARK: Entries

    /// All entries, newest day first, newest created first within a day.
    /// Emits again whenever the entries table changes.
    func observeEntries() -> AsyncValueObservation<[Entry]> {
        ValueObservation
            .tracking { db in try Entry.order(Self.newestFirst).fetchAll(db) }
            .values(in: database.writer)
    }

    func observeEntry(id: UUID) -> AsyncValueObservation<Entry?> {
        ValueObservation
            .tracking { db in try Entry.fetchOne(db, key: id) }
            .values(in: database.writer)
    }

    func fetchAll() async throws -> [Entry] {
        try await database.writer.read { db in try Entry.order(Self.newestFirst).fetchAll(db) }
    }

    func fetch(id: UUID) async throws -> Entry? {
        try await database.writer.read { db in try Entry.fetchOne(db, key: id) }
    }

    /// Inserts or replaces the whole entry. Used for new entries and tests; the editor
    /// uses `saveFromEditor` so it never overwrites fields it doesn't own.
    func save(_ entry: Entry) async throws {
        try await database.writer.write { db in try entry.save(db) }
    }

    /// Saves the editor's fields. A text change marks the entry for analysis.
    func saveFromEditor(_ entry: Entry, isNew: Bool, textChanged: Bool) async throws {
        try await database.writer.write { db in
            if isNew {
                var entry = entry
                entry.needsAnalysis = true
                try entry.insert(db)
            } else {
                try entry.update(db, columns: Entry.editorColumns)
                if textChanged {
                    try Entry.filter(key: entry.id).updateAll(
                        db,
                        Entry.Columns.needsAnalysis.set(to: true),
                        Entry.Columns.embedding.set(to: nil)
                    )
                }
            }
        }
    }

    /// Deletes the entry and its recording.
    func delete(id: UUID) async throws {
        let audioPath = try await database.writer.write { db -> String? in
            let audioPath = try Entry.fetchOne(db, key: id)?.audioPath
            try Entry.deleteOne(db, key: id)
            return audioPath
        }
        if let audioPath { try? FileManager.default.removeItem(at: paths.url(forRelativePath: audioPath)) }
    }

    func audioURL(for entry: Entry) -> URL? {
        entry.audioPath.map(paths.url(forRelativePath:))
    }

    /// Records which prompt version and model produced an AI field (see `AIVersion`).
    func recordAIVersion(_ version: String, for id: UUID) async throws {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id) else { return }
            entry.aiVersion = AIVersion.merging(entry.aiVersion, version)
            try entry.update(db, columns: ["ai_version"])
        }
    }

    // MARK: Analysis

    func observePendingAnalysisCount() -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in try Entry.filter(Entry.Columns.needsAnalysis == true).fetchCount(db) }
            .values(in: database.writer)
    }

    /// The newest entry waiting for analysis, skipping `excluding`.
    func nextEntryNeedingAnalysis(excluding: Set<UUID>) async throws -> Entry? {
        try await database.writer.read { db in
            try Entry
                .filter(Entry.Columns.needsAnalysis == true)
                .filter(!excluding.map { $0.uuidString.lowercased() }.contains(Entry.Columns.id))
                .order(Self.newestFirst)
                .fetchOne(db)
        }
    }

    /// Stores an analysis, unless the entry's text changed while it ran. Manual mood and
    /// categories are left alone; `log` entries get no mood (SPEC.md, Rows with no body).
    /// A new category suggestion is added as `pending`. Returns whether it was stored.
    @discardableResult
    func applyAnalysis(_ analysis: EntryAnalysis?, to id: UUID, analysedText: String, aiVersion: String) async throws -> Bool {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id), entry.analysisText == analysedText else { return false }
            if let analysis {
                if !entry.moodManual, entry.sourceKind != .log {
                    entry.moodScore = analysis.moodScore
                    entry.moodLabel = analysis.moodLabel
                    entry.emotions = analysis.emotions
                }
                if !entry.categoriesManual {
                    entry.primaryCategory = analysis.primaryCategory
                    entry.secondaryCategories = analysis.secondaryCategories
                }
                entry.isJournal = analysis.isJournal
                entry.summary = analysis.summary
                entry.themes = analysis.themes
                entry.aiVersion = AIVersion.merging(entry.aiVersion, aiVersion)
                if let suggestion = analysis.suggestedCategory { try Self.addSuggestion(suggestion, db: db) }
            }
            entry.needsAnalysis = false
            try entry.update(db, columns: Entry.analysisColumns)
            return true
        }
    }

    func setManualMood(_ score: Double, label: String, for id: UUID) async throws {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id) else { return }
            entry.moodScore = min(1, max(-1, score))
            entry.moodLabel = label.trimmingCharacters(in: .whitespaces).lowercased()
            entry.moodManual = true
            try entry.update(db, columns: ["mood_score", "mood_label", "mood_manual"])
        }
    }

    func setManualCategories(primary: String?, secondary: [String], for id: UUID) async throws {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id) else { return }
            entry.primaryCategory = primary
            entry.secondaryCategories = Array(secondary.filter { $0 != primary }.prefix(2))
            entry.categoriesManual = true
            try entry.update(db, columns: ["primary_category", "secondary_categories", "categories_manual"])
        }
    }

    /// Hands mood or categories back to the model and queues the entry for analysis.
    func resetToAutomatic(mood: Bool, categories: Bool, for id: UUID) async throws {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id) else { return }
            if mood { entry.moodManual = false }
            if categories { entry.categoriesManual = false }
            entry.needsAnalysis = true
            try entry.update(db, columns: ["mood_manual", "categories_manual", "needs_analysis"])
        }
    }

    /// Queues every entry whose categories aren't set by hand for analysis again.
    func recategoriseAll() async throws {
        try await database.writer.write { db in
            _ = try Entry.filter(Column("categories_manual") == false)
                .updateAll(db, Entry.Columns.needsAnalysis.set(to: true))
        }
    }

    // MARK: Embeddings and asking

    /// Clears every embedding if the search model changed, so all entries are embedded
    /// again with the same model (vectors from different models can't be compared).
    func ensureEmbeddingModel(_ identifier: String) async throws {
        try await database.writer.write { db in
            let current = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'embedding_model'")
            guard current != identifier else { return }
            _ = try Entry.updateAll(db, Entry.Columns.embedding.set(to: nil))
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('embedding_model', ?)", arguments: [identifier])
        }
    }

    /// The newest analysed entry that has no embedding yet.
    func nextEntryNeedingEmbedding(excluding: Set<UUID>) async throws -> Entry? {
        try await database.writer.read { db in
            try Entry
                .filter(Entry.Columns.needsAnalysis == false && Entry.Columns.embedding == nil)
                .filter(!excluding.map { $0.uuidString.lowercased() }.contains(Entry.Columns.id))
                .order(Self.newestFirst)
                .fetchOne(db)
        }
    }

    /// Stores an embedding unless the text changed meanwhile. Entries with no text get
    /// an empty one so they aren't picked up again.
    @discardableResult
    func applyEmbedding(_ vector: [Float], to id: UUID, embeddedText: String, aiVersion: String) async throws -> Bool {
        try await database.writer.write { db in
            guard var entry = try Entry.fetchOne(db, key: id), entry.analysisText == embeddedText else { return false }
            entry.embedding = Vectors.data(vector)
            entry.aiVersion = AIVersion.merging(entry.aiVersion, aiVersion)
            try entry.update(db, columns: ["embedding", "ai_version"])
            return true
        }
    }

    /// Every stored embedding, optionally only for entries in a category.
    func embeddings(category: String?) async throws -> [(id: UUID, vector: [Float])] {
        try await database.writer.read { db in
            try Entry.filter(Entry.Columns.embedding != nil).fetchAll(db)
                .filter { category == nil || $0.categories.contains(category!) }
                .compactMap { entry in
                    guard let data = entry.embedding, !data.isEmpty else { return nil }
                    return (entry.id, Vectors.vector(data))
                }
        }
    }

    /// Entries dated within the range (inclusive), oldest first.
    func entries(from start: DayDate, through end: DayDate, category: String?) async throws -> [Entry] {
        try await database.writer.read { db in
            try Entry
                .filter(Entry.Columns.entryDate >= start.string && Entry.Columns.entryDate <= end.string)
                .order(Entry.Columns.entryDate, Entry.Columns.createdAt)
                .fetchAll(db)
                .filter { category == nil || $0.categories.contains(category!) }
        }
    }

    /// The given entries, oldest first.
    func entries(ids: [UUID]) async throws -> [Entry] {
        try await database.writer.read { db in
            try Entry.fetchAll(db, keys: ids)
                .sorted { ($0.entryDate, $0.createdAt) < ($1.entryDate, $1.createdAt) }
        }
    }

    // MARK: Reflections

    func observeReflections() -> AsyncValueObservation<[Reflection]> {
        ValueObservation
            .tracking { db in try Reflection.order(Column("created_at").desc).fetchAll(db) }
            .values(in: database.writer)
    }

    func saveReflection(_ reflection: Reflection) async throws {
        try await database.writer.write { db in try reflection.save(db) }
    }

    func deleteReflection(id: UUID) async throws {
        _ = try await database.writer.write { db in try Reflection.deleteOne(db, key: id) }
    }

    func reflections() async throws -> [Reflection] {
        try await database.writer.read { db in try Reflection.order(Column("created_at").desc).fetchAll(db) }
    }

    // MARK: Categories

    func observeCategories() -> AsyncValueObservation<[Category]> {
        ValueObservation
            .tracking { db in try Category.order(Column("sort_order"), Column("name")).fetchAll(db) }
            .values(in: database.writer)
    }

    func categories() async throws -> [Category] {
        try await database.writer.read { db in
            try Category.order(Column("sort_order"), Column("name")).fetchAll(db)
        }
    }

    func activeCategoryNames() async throws -> [String] {
        try await categories().filter { $0.status == .active }.map(\.name)
    }

    enum CategoryError: LocalizedError {
        case invalidName
        case duplicate

        var errorDescription: String? {
            switch self {
            case .invalidName: "Use 1–30 letters, numbers or spaces (& ' - are allowed too)."
            case .duplicate: "There's already a category with that name."
            }
        }
    }

    func addCategory(_ rawName: String) async throws {
        guard let name = CategoryName.validated(rawName) else { throw CategoryError.invalidName }
        try await database.writer.write { db in
            if var existing = try Self.category(named: name, db: db) {
                guard existing.status != .active else { throw CategoryError.duplicate }
                existing.status = .active
                existing.sortOrder = try Self.nextSortOrder(db)
                try existing.update(db)
            } else {
                try Category(name: name, sortOrder: try Self.nextSortOrder(db), status: .active, createdAt: .now).insert(db)
            }
        }
    }

    /// Renames a category and every entry that uses it.
    func renameCategory(_ old: String, to rawName: String) async throws {
        guard let new = CategoryName.validated(rawName) else { throw CategoryError.invalidName }
        guard new != old else { return }
        try await database.writer.write { db in
            if let clash = try Self.category(named: new, db: db), clash.name != old { throw CategoryError.duplicate }
            guard var category = try Category.fetchOne(db, key: old) else { return }
            try category.delete(db)
            category.name = new
            try category.insert(db)
            try Self.replaceCategory(old, with: new, db: db)
        }
    }

    /// Removes a category from the list and from the entries that use it.
    func deleteCategory(_ name: String) async throws {
        try await database.writer.write { db in
            _ = try Category.deleteOne(db, key: name)
            try Self.replaceCategory(name, with: nil, db: db)
        }
    }

    func moveCategories(to order: [String]) async throws {
        try await database.writer.write { db in
            for (index, name) in order.enumerated() {
                try Category.filter(key: name).updateAll(db, Column("sort_order").set(to: index))
            }
        }
    }

    func approveSuggestion(_ name: String) async throws {
        try await database.writer.write { db in
            guard var category = try Category.fetchOne(db, key: name) else { return }
            category.status = .active
            category.sortOrder = try Self.nextSortOrder(db)
            try category.update(db)
        }
    }

    func dismissSuggestion(_ name: String) async throws {
        try await database.writer.write { db in
            _ = try Category.filter(key: name).updateAll(db, Column("status").set(to: Category.Status.dismissed.rawValue))
        }
    }

    private static func addSuggestion(_ raw: String, db: Database) throws {
        guard let name = CategoryName.validated(raw), try category(named: name, db: db) == nil else { return }
        try Category(name: name, sortOrder: try nextSortOrder(db), status: .pending, createdAt: .now).insert(db)
    }

    private static func category(named name: String, db: Database) throws -> Category? {
        try Category.fetchAll(db).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func nextSortOrder(_ db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM categories") ?? -1) + 1
    }

    private static func replaceCategory(_ old: String, with new: String?, db: Database) throws {
        for var entry in try Entry.fetchAll(db) where entry.categories.contains(old) {
            if entry.primaryCategory == old { entry.primaryCategory = new }
            entry.secondaryCategories = entry.secondaryCategories.compactMap { $0 == old ? new : $0 }
            try entry.update(db, columns: ["primary_category", "secondary_categories"])
        }
    }
}

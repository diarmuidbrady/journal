import Foundation
import GRDB

/// Reads and writes entries and their recordings. Exists only while the vault is unlocked.
final class EntryStore: Sendable {
    let database: AppDatabase
    let paths: VaultPaths

    init(database: AppDatabase, paths: VaultPaths) {
        self.database = database
        self.paths = paths
    }

    /// All entries, newest day first, newest created first within a day.
    /// Emits again whenever the entries table changes.
    func observeEntries() -> AsyncValueObservation<[Entry]> {
        ValueObservation
            .tracking { db in
                try Entry
                    .order(Entry.Columns.entryDate.desc, Entry.Columns.createdAt.desc)
                    .fetchAll(db)
            }
            .values(in: database.writer)
    }

    func fetchAll() async throws -> [Entry] {
        try await database.writer.read { db in
            try Entry.order(Entry.Columns.entryDate.desc, Entry.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func fetch(id: UUID) async throws -> Entry? {
        try await database.writer.read { db in try Entry.fetchOne(db, key: id) }
    }

    /// Inserts or updates the entry.
    func save(_ entry: Entry) async throws {
        try await database.writer.write { db in try entry.save(db) }
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

    func categories() async throws -> [Category] {
        try await database.writer.read { db in
            try Category.order(Column("sort_order")).fetchAll(db)
        }
    }
}

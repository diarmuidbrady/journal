import Foundation
import GRDB

/// Reads and writes entries. Exists only while the vault is unlocked.
final class EntryStore: Sendable {
    let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
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

    func delete(id: UUID) async throws {
        _ = try await database.writer.write { db in try Entry.deleteOne(db, key: id) }
    }

    func categories() async throws -> [Category] {
        try await database.writer.read { db in
            try Category.order(Column("sort_order")).fetchAll(db)
        }
    }
}

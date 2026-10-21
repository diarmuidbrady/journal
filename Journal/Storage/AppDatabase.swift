import Foundation
import GRDB

/// The encrypted SQLite (SQLCipher) database and its migrations.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the database at `url`, encrypted with a 32-byte raw key.
    static func open(at url: URL, key: Data) throws -> AppDatabase {
        precondition(key.count == 32, "The database key must be 256 bits")
        var config = Configuration()
        config.prepareDatabase { db in
            // SQLCipher raw key format x'<64 hex chars>' uses the key as-is, with no
            // passphrase stretching, since it is already random.
            var rawKey = Data("x'\(key.map { String(format: "%02x", $0) }.joined())'".utf8)
            defer { rawKey.resetBytes(in: 0..<rawKey.count) }
            try db.usePassphrase(rawKey)
        }
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: config)
        return try AppDatabase(pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1: entries, categories, settings") { db in
            // Every column from SPEC.md's data model, so later phases fill fields
            // instead of migrating. JSON arrays are stored as text.
            try db.create(table: "entries") { t in
                t.primaryKey("id", .text)
                t.column("title", .text)
                t.column("entry_date", .text).notNull().indexed()
                t.column("entry_time", .text)
                t.column("date_source", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("source", .text).notNull()
                t.column("source_kind", .text).notNull()
                t.column("source_ref", .text)
                t.column("source_properties", .text)
                t.column("import_batch_id", .text)
                t.column("original_text", .text).notNull()
                t.column("cleaned_text", .text)
                t.column("show_cleaned", .boolean).notNull().defaults(to: false)
                t.column("audio_path", .text)
                t.column("audio_duration_s", .integer)
                t.column("mood_score", .double)
                t.column("mood_label", .text)
                t.column("emotions", .text).notNull().defaults(to: "[]")
                t.column("mood_manual", .boolean).notNull().defaults(to: false)
                t.column("primary_category", .text)
                t.column("secondary_categories", .text).notNull().defaults(to: "[]")
                t.column("categories_manual", .boolean).notNull().defaults(to: false)
                t.column("is_journal", .boolean)
                t.column("summary", .text)
                t.column("themes", .text).notNull().defaults(to: "[]")
                t.column("content_hash", .text).notNull().indexed()
                t.column("embedding", .blob)
                t.column("ai_version", .text)
            }

            try db.create(table: "categories") { t in
                t.primaryKey("name", .text)
                t.column("sort_order", .integer).notNull()
                t.column("status", .text).notNull().defaults(to: Category.Status.active.rawValue)
                t.column("created_at", .datetime).notNull()
            }
            let now = Date.now
            for (index, name) in Category.defaultNames.enumerated() {
                try Category(name: name, sortOrder: index, status: .active, createdAt: now).insert(db)
            }

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }

        migrator.registerMigration("v2: needs_analysis") { db in
            // Set when an entry's text changes; cleared once mood, summary, themes and
            // categories are filled in. Lets the background pass resume after a restart.
            try db.alter(table: "entries") { t in
                t.add(column: "needs_analysis", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "entries_on_needs_analysis", on: "entries", columns: ["needs_analysis"])
        }

        migrator.registerMigration("v3: reflections") { db in
            // SPEC.md, Data model, plus the category filter and ai_version of the answer.
            try db.create(table: "reflections") { t in
                t.primaryKey("id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("question", .text).notNull()
                t.column("answer", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("range_start", .text)
                t.column("range_end", .text)
                t.column("category", .text)
                t.column("cited_entry_ids", .text).notNull().defaults(to: "[]")
                t.column("ai_version", .text)
            }
        }

        return migrator
    }
}

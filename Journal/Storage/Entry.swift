import CryptoKit
import Foundation
import GRDB

/// One journal entry: a row of the `entries` table (SPEC.md, Data model).
struct Entry: Identifiable, Hashable, Codable, Sendable {
    enum DateSource: String, Codable, Sendable, DatabaseValueConvertible {
        case typed, property, title, body, file, photo, manual
    }

    enum Source: String, Codable, Sendable, DatabaseValueConvertible {
        case typed, audio, notion, appleNotes = "apple_notes", text, photo
    }

    enum SourceKind: String, Codable, Sendable, DatabaseValueConvertible {
        case journal, log
    }

    var id: UUID
    var title: String?
    var entryDate: DayDate
    var entryTime: String?
    var dateSource: DateSource
    var createdAt: Date
    var updatedAt: Date
    var source: Source
    var sourceKind: SourceKind
    var sourceRef: String?
    /// Original import properties as a JSON object string.
    var sourceProperties: String?
    var importBatchId: UUID?
    var originalText: String
    var cleanedText: String?
    var showCleaned: Bool
    var audioPath: String?
    var audioDurationS: Int?
    var moodScore: Double?
    var moodLabel: String?
    var emotions: [String]
    var moodManual: Bool
    var primaryCategory: String?
    var secondaryCategories: [String]
    var categoriesManual: Bool
    var isJournal: Bool?
    var summary: String?
    var themes: [String]
    var contentHash: String
    var embedding: Data?
    var aiVersion: String?
    /// The text changed since mood, summary, themes and categories were last worked out.
    var needsAnalysis: Bool

    /// A new, unsaved typed entry for today.
    static func newTyped(on date: DayDate = .today, now: Date = .now) -> Entry {
        Entry(
            id: UUID(), title: nil, entryDate: date, entryTime: nil, dateSource: .typed,
            createdAt: now, updatedAt: now, source: .typed, sourceKind: .journal,
            sourceRef: nil, sourceProperties: nil, importBatchId: nil,
            originalText: "", cleanedText: nil, showCleaned: false,
            audioPath: nil, audioDurationS: nil,
            moodScore: nil, moodLabel: nil, emotions: [], moodManual: false,
            primaryCategory: nil, secondaryCategories: [], categoriesManual: false,
            isJournal: nil, summary: nil, themes: [],
            contentHash: contentHash(text: "", date: date), embedding: nil, aiVersion: nil,
            needsAnalysis: true
        )
    }

    /// The text the model analyses: the accepted cleanup if there is one.
    var analysisText: String {
        (cleanedText ?? originalText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var categories: [String] {
        (primaryCategory.map { [$0] } ?? []) + secondaryCategories
    }

    /// The text the entry currently shows: the accepted cleanup or the original.
    var displayText: String {
        if showCleaned, let cleanedText { return cleanedText }
        return originalText
    }

    var trimmedTitle: String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    var isEmpty: Bool {
        trimmedTitle == nil && originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && audioPath == nil
    }

    /// SHA-256 of the normalised text (lowercased, whitespace collapsed) plus the date,
    /// used to spot duplicates when importing.
    static func contentHash(text: String, date: DayDate) -> String {
        let normalised = text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data("\(date.string)\n\(normalised)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Entry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "entries"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString

    enum Columns {
        static let entryDate = Column("entry_date")
        static let createdAt = Column("created_at")
        static let needsAnalysis = Column("needs_analysis")
        static let id = Column("id")
    }

    /// Columns the editor writes. Everything else (AI fields, manual overrides) is
    /// written by its own code path, so a stale editor copy can't overwrite it.
    static let editorColumns = [
        "title", "entry_date", "date_source", "updated_at", "source", "original_text",
        "cleaned_text", "show_cleaned", "audio_path", "audio_duration_s", "content_hash",
    ]

    static let analysisColumns = [
        "mood_score", "mood_label", "emotions", "primary_category", "secondary_categories",
        "is_journal", "summary", "themes", "ai_version", "needs_analysis",
    ]
}

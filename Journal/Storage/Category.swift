import Foundation
import GRDB

/// A row of the `categories` table. Model suggestions wait as `pending` until approved.
struct Category: Hashable, Codable, Sendable {
    /// `pending`: suggested by the model, awaiting approval. `dismissed`: a suggestion
    /// that was turned down, kept so it isn't suggested again.
    enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case active, pending, dismissed
    }

    static let defaultNames = [
        "Work", "Relationships", "Family", "Health", "Mind and emotions",
        "Money", "Personal growth", "Creativity", "Travel", "Dreams",
    ]

    var name: String
    var sortOrder: Int
    var status: Status
    var createdAt: Date
}

/// Category names: 1–30 characters of letters, digits, spaces and & ' -.
/// Keeps names tidy and safe to put in the model's output grammar.
enum CategoryName {
    static func validated(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces).replacing(/\s+/, with: " ")
        guard (1...30).contains(name.count),
              name.wholeMatch(of: /[\p{L}\p{N}][\p{L}\p{N} &'’-]*/) != nil else { return nil }
        return name
    }
}

extension Category: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

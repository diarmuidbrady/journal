import Foundation
import GRDB

/// A row of the `categories` table. Model suggestions wait as `pending` until approved.
struct Category: Hashable, Codable, Sendable {
    enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case active, pending
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

extension Category: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

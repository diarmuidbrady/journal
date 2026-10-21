import Foundation
import GRDB

/// A saved answer from "Ask the journal", linked to the entries it cited.
struct Reflection: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var question: String
    var answer: String
    /// `entry`, `range` or `all` (see AskScope.kind).
    var scope: String
    var rangeStart: DayDate?
    var rangeEnd: DayDate?
    var category: String?
    var citedEntryIds: [UUID]
    var aiVersion: String?
}

extension Reflection: FetchableRecord, PersistableRecord {
    static let databaseTableName = "reflections"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
}

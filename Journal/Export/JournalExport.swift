import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The plain JSON export: every entry with every column, plus the category list.
struct JournalExport: Codable, Sendable {
    static let currentSchemaVersion = 1

    var format = "journal-export"
    var schemaVersion = JournalExport.currentSchemaVersion
    var exportedAt: Date
    var entries: [Entry]
    var categories: [Category]

    static func make(from store: EntryStore, now: Date = .now) async throws -> JournalExport {
        JournalExport(
            exportedAt: now,
            entries: try await store.fetchAll(),
            categories: try await store.categories()
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.timestampFormat))
        }
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> JournalExport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = try? Date(string, strategy: timestampFormat) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad timestamp \(string)")
            }
            return date
        }
        return try decoder.decode(JournalExport.self, from: data)
    }

    /// ISO 8601 in UTC with milliseconds, e.g. 2026-10-21T13:52:07.123Z.
    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func fileName(on day: DayDate = .today) -> String {
        "journal-export-\(day.string).json"
    }
}

/// Builds the export only when a share target asks for it.
struct ExportFile: Transferable {
    let store: EntryStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            try await JournalExport.make(from: file.store).encoded()
        }
        .suggestedFileName(JournalExport.fileName())
    }
}

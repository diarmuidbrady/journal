import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The plain JSON export: every entry with every column, the category list and saved
/// reflections. Schema 2 added reflections.
struct JournalExport: Codable, Sendable {
    static let currentSchemaVersion = 2

    var format = "journal-export"
    var schemaVersion = JournalExport.currentSchemaVersion
    var exportedAt: Date
    var entries: [Entry]
    var categories: [Category]
    var reflections: [Reflection]

    static func make(from store: EntryStore, now: Date = .now) async throws -> JournalExport {
        JournalExport(
            exportedAt: now,
            entries: try await store.fetchAll(),
            categories: try await store.categories(),
            reflections: try await store.reflections()
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

    static func baseName(on day: DayDate = .today) -> String {
        "journal-export-\(day.string)"
    }

    /// Writes a zip of `journal.json` plus an `Audio/` folder of every recording, laid out
    /// so each entry's `audio_path` points at its file inside the zip. The zip is created
    /// in the vault's export folder, which is emptied on every unlock.
    static func makeArchive(from store: EntryStore, on day: DayDate = .today) async throws -> URL {
        let fileManager = FileManager.default
        let paths = store.paths
        paths.clearExports()

        let folder = paths.exportDirectory.appending(path: baseName(on: day), directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let export = try await make(from: store)
        try export.encoded().write(to: folder.appending(path: "journal.json"))
        for audioPath in export.entries.compactMap(\.audioPath) {
            let destination = folder.appending(path: audioPath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: paths.url(forRelativePath: audioPath), to: destination)
        }

        // Coordinated reading with .forUploading makes the system zip the folder.
        let archive = paths.exportDirectory.appending(path: "\(baseName(on: day)).zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipURL in
            do { try fileManager.copyItem(at: zipURL, to: archive) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return archive
    }
}

/// Builds the export only when a share target asks for it.
struct ExportFile: Transferable {
    let store: EntryStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { file in
            SentTransferredFile(try await JournalExport.makeArchive(from: file.store))
        }
    }
}

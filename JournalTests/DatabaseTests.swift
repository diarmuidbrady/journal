import Foundation
import Testing
@testable import Journal

struct DatabaseTests {
    @Test func fileIsEncrypted() async throws {
        let test = try TestDatabase()
        for entry in SampleEntries.all() { try await test.store.save(entry) }

        #expect(!(try Data(contentsOf: test.url)).starts(with: Data("SQLite format 3".utf8)))
        // Check the main file and the write-ahead log, where recent writes live.
        let files = try FileManager.default.contentsOfDirectory(at: test.directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        #expect(files.contains { $0.lastPathComponent == "journal.sqlite-wal" })
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data("croissant".utf8)) == nil, "plaintext in \(file.lastPathComponent)")
            #expect(bytes.range(of: Data("Maeve".utf8)) == nil, "plaintext in \(file.lastPathComponent)")
        }
    }

    @Test func wrongKeyCannotOpen() async throws {
        let test = try TestDatabase()
        try await test.store.save(SampleEntries.all()[0])

        let wrongKey = Data(repeating: 7, count: 32)
        #expect(throws: (any Error).self) {
            _ = try AppDatabase.open(at: test.url, key: wrongKey)
        }
    }

    @Test func rightKeyReopens() async throws {
        let test = try TestDatabase()
        let sample = SampleEntries.all()[0]
        try await test.store.save(sample)

        let reopened = EntryStore(database: try AppDatabase.open(at: test.url, key: test.key), paths: test.paths)
        let fetched = try await reopened.fetch(id: sample.id)
        #expect(fetched?.originalText == sample.originalText)
    }

    @Test func entriesRoundTripEveryField() async throws {
        let test = try TestDatabase()
        let samples = SampleEntries.all()
        for entry in samples { try await test.store.save(entry) }

        let fetched = try await test.store.fetchAll()
        #expect(fetched.count == 3)
        let second = try #require(fetched.first { $0.id == samples[1].id })
        #expect(second.emotions == ["calm", "tired"])
        #expect(second.themes == ["walking"])
        #expect(second.entryDate == DayDate(year: 2026, month: 3, day: 14))
        #expect(second.source == .typed)
        #expect(second.sourceKind == .journal)
    }

    @Test func entriesAreNewestDayFirstThenNewestCreated() async throws {
        let test = try TestDatabase()
        let samples = SampleEntries.all()
        for entry in samples { try await test.store.save(entry) }

        let ids = try await test.store.fetchAll().map(\.id)
        #expect(ids == [samples[1].id, samples[0].id, samples[2].id])
    }

    @Test func updateAndDelete() async throws {
        let test = try TestDatabase()
        var entry = SampleEntries.all()[0]
        try await test.store.save(entry)

        entry.originalText = "Edited text."
        try await test.store.save(entry)
        #expect(try await test.store.fetchAll().count == 1)
        #expect(try await test.store.fetch(id: entry.id)?.originalText == "Edited text.")

        try await test.store.delete(id: entry.id)
        #expect(try await test.store.fetchAll().isEmpty)
    }

    @Test func defaultCategoriesAreSeeded() async throws {
        let test = try TestDatabase()
        let categories = try await test.store.categories()
        #expect(categories.map(\.name) == Category.defaultNames)
        #expect(categories.allSatisfy { $0.status == .active })
    }

    @Test func vaultDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "VaultPathsTest-\(UUID().uuidString)")
        let paths = VaultPaths(directory: directory)
        try paths.prepare()
        #expect(paths.isExcludedFromBackup)
    }
}

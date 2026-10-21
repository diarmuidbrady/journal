import Foundation
import Testing
@testable import Journal

struct ExportTests {
    @Test func exportRoundTripsEveryEntry() async throws {
        let test = try TestDatabase()
        let samples = SampleEntries.all()
        for entry in samples { try await test.store.save(entry) }

        let data = try await JournalExport.make(from: test.store).encoded()
        let decoded = try JournalExport.decode(data)

        #expect(decoded.format == "journal-export")
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.categories.count == Category.defaultNames.count)

        let stored = try await test.store.fetchAll()
        #expect(decoded.entries.count == stored.count)
        for (exported, original) in zip(decoded.entries, stored) {
            #expect(exported.id == original.id)
            #expect(exported.title == original.title)
            #expect(exported.originalText == original.originalText)
            #expect(exported.entryDate == original.entryDate)
            #expect(exported.dateSource == original.dateSource)
            #expect(exported.emotions == original.emotions)
            #expect(exported.contentHash == original.contentHash)
            #expect(abs(exported.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
        }
    }

    @Test func exportIsReadableJSON() async throws {
        let test = try TestDatabase()
        try await test.store.save(SampleEntries.all()[0])

        let json = String(decoding: try await JournalExport.make(from: test.store).encoded(), as: UTF8.self)
        #expect(json.contains("\"entry_date\" : \"2026-03-14\""))
        #expect(json.contains("\"original_text\" : \"Um, so the ovens broke again"))
        #expect(json.contains("\"date_source\" : \"typed\""))
    }

    @Test @MainActor func archiveIsAZipAndLeavesNoLooseFiles() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, transcriber: FakeTranscriber(text: "Hello."))
        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))

        let archive = try await JournalExport.makeArchive(from: test.store, on: DayDate(year: 2026, month: 10, day: 21))

        #expect(archive.lastPathComponent == "journal-export-2026-10-21.zip")
        #expect(try Data(contentsOf: archive).starts(with: Data("PK".utf8)))
        let names = try String(decoding: Data(contentsOf: archive), as: UTF8.self)
        #expect(names.contains("journal.json"))
        #expect(names.contains(test.paths.audioRelativePath(for: entry.id)))
        // Only the zip remains; the unzipped copy is removed.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: test.paths.exportDirectory.path)
        #expect(leftovers == [archive.lastPathComponent])

        test.paths.clearExports()
        #expect(try FileManager.default.contentsOfDirectory(atPath: test.paths.exportDirectory.path).isEmpty)
    }
}

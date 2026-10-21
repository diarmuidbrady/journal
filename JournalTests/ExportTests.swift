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

    @Test func fileNameHasDate() {
        #expect(JournalExport.fileName(on: DayDate(year: 2026, month: 10, day: 21)) == "journal-export-2026-10-21.json")
    }
}

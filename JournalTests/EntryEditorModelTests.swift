import Foundation
import Testing
@testable import Journal

@MainActor
struct EntryEditorModelTests {
    @Test func blankNewEntryIsNotSaved() async throws {
        let test = try TestDatabase()
        let model = EntryEditorModel(store: test.store, entry: .newTyped(), isPersisted: false)

        await model.flush()

        #expect(try await test.store.fetchAll().isEmpty)
        #expect(model.isNew)
    }

    @Test func typingAutoSavesAfterInterval() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, saveInterval: .milliseconds(50))

        model.text = "Went sea swimming at 7am."
        #expect(model.saveState == .pending)

        try await Task.sleep(for: .milliseconds(400))
        #expect(try await test.store.fetch(id: entry.id)?.originalText == "Went sea swimming at 7am.")
        #expect(model.saveState == .saved)
        #expect(!model.isNew)
    }

    @Test func flushSavesImmediately() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, saveInterval: .seconds(60))

        model.title = "Quick note"
        model.text = "Bought a new notebook."
        await model.flush()

        let saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.title == "Quick note")
        #expect(saved.originalText == "Bought a new notebook.")
        #expect(saved.dateSource == .typed)
    }

    @Test func backdatingMarksDateAsManual() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped(on: DayDate(year: 2026, month: 10, day: 21))
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, saveInterval: .seconds(60))

        model.text = "Writing this up a few days late."
        model.date = DayDate(year: 2026, month: 10, day: 18).date()
        await model.flush()

        let saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.entryDate == DayDate(year: 2026, month: 10, day: 18))
        #expect(saved.dateSource == .manual)
        #expect(saved.contentHash == Entry.contentHash(text: "Writing this up a few days late.", date: saved.entryDate))
    }

    @Test func editingExistingEntryUpdatesTimestamp() async throws {
        let test = try TestDatabase()
        let original = SampleEntries.all()[0]
        try await test.store.save(original)
        let model = EntryEditorModel(store: test.store, entry: original, isPersisted: true, saveInterval: .seconds(60))

        model.text += " Fixed by Friday though."
        await model.flush()

        let saved = try #require(try await test.store.fetch(id: original.id))
        #expect(saved.originalText.hasSuffix("Fixed by Friday though."))
        #expect(saved.updatedAt > original.updatedAt)
        #expect(saved.createdAt == original.createdAt)
    }
}

struct DayDateTests {
    @Test func parsesAndFormats() {
        #expect(DayDate(string: "2023-03-14") == DayDate(year: 2023, month: 3, day: 14))
        #expect(DayDate(year: 2023, month: 3, day: 4).string == "2023-03-04")
        #expect(DayDate(string: "2023-13-01") == nil)
        #expect(DayDate(string: "not a date") == nil)
    }

    @Test func ordersChronologically() {
        #expect(DayDate(year: 2025, month: 12, day: 31) < DayDate(year: 2026, month: 1, day: 1))
    }

    @Test func contentHashIgnoresCaseAndSpacing() {
        let day = DayDate(year: 2026, month: 1, day: 2)
        #expect(Entry.contentHash(text: "Hello  World\n", date: day) == Entry.contentHash(text: "hello world", date: day))
        #expect(Entry.contentHash(text: "hello world", date: day) != Entry.contentHash(text: "hello world", date: DayDate(year: 2026, month: 1, day: 3)))
    }
}

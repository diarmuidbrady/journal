import Foundation
@testable import Journal

/// Invented entries for tests. Never put real journal text here.
enum SampleEntries {
    static func all(now: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> [Entry] {
        var first = Entry.newTyped(on: DayDate(year: 2026, month: 3, day: 14), now: now)
        first.title = "Rough day at the bakery"
        first.originalText = "Um, so the ovens broke again and Maeve didn't show up. I never want to see another croissant."
        first.contentHash = Entry.contentHash(text: first.originalText, date: first.entryDate)

        var second = Entry.newTyped(on: DayDate(year: 2026, month: 3, day: 14), now: now.addingTimeInterval(3_600))
        second.originalText = "Second entry the same day.\nWalked the dog to the pier, 4 km, felt calmer."
        second.emotions = ["calm", "tired"]
        second.themes = ["walking"]
        second.contentHash = Entry.contentHash(text: second.originalText, date: second.entryDate)

        var third = Entry.newTyped(on: DayDate(year: 2025, month: 12, day: 31), now: now.addingTimeInterval(7_200))
        third.title = "New Year's Eve"
        third.originalText = "Fireworks over the harbour. Called Gran at 11:58."
        third.dateSource = .manual
        third.contentHash = Entry.contentHash(text: third.originalText, date: third.entryDate)

        return [first, second, third]
    }
}

/// An encrypted database and vault folders in a fresh temporary directory.
struct TestDatabase {
    let paths: VaultPaths
    let key: Data
    let database: AppDatabase

    init() throws {
        paths = VaultPaths(directory: FileManager.default.temporaryDirectory.appending(path: "JournalTests-\(UUID().uuidString)"))
        try paths.prepare()
        key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        database = try AppDatabase.open(at: paths.databaseURL, key: key)
    }

    var directory: URL { paths.directory }
    var url: URL { paths.databaseURL }
    var store: EntryStore { EntryStore(database: database, paths: paths) }
}

#if DEBUG
import Foundation

/// Fills an empty journal with invented entries when launched with
/// `-seed-sample-entries`, for trying the UI in the simulator. Debug builds only.
enum DebugSampleData {
    static func seedIfRequested(into store: EntryStore) async throws {
        guard ProcessInfo.processInfo.arguments.contains("-seed-sample-entries"),
              try await store.fetchAll().isEmpty else { return }

        let calendar = Calendar.current
        let samples: [(daysAgo: Int, title: String?, text: String)] = [
            (0, "Sea swim", "Went in at the Forty Foot before work. Freezing, but I felt awake for the whole day.\nNeed to remember a towel next time."),
            (0, nil, "Short one. Finished the bookshelf at last, only one screw left over."),
            (1, "Planning the trip", "Booked the train to Galway for the 14th. Still haven't decided whether to stay two nights or three."),
            (3, nil, "Long day. The meeting ran over and I missed the bus, so I walked home and actually enjoyed it."),
            (9, "Gran's birthday", "Ninety-one today. She beat everyone at cards again."),
        ]
        for (index, sample) in samples.enumerated() {
            let day = calendar.date(byAdding: .day, value: -sample.daysAgo, to: .now)!
            var entry = Entry.newTyped(on: DayDate(day), now: day.addingTimeInterval(Double(-index * 3_600)))
            entry.title = sample.title
            entry.originalText = sample.text
            entry.contentHash = Entry.contentHash(text: sample.text, date: entry.entryDate)
            try await store.save(entry)
        }
    }
}
#endif

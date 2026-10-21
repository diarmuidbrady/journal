#if DEBUG
import Foundation

/// Fills an empty journal with invented entries when launched with
/// `-seed-sample-entries`, for trying the UI in the simulator. Debug builds only.
/// `-open-tab mood` starts on the Mood tab.
enum DebugSampleData {
    static var initialTab: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-open-tab"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func seedIfRequested(into store: EntryStore) async throws {
        guard ProcessInfo.processInfo.arguments.contains("-seed-sample-entries"),
              try await store.fetchAll().isEmpty else { return }

        let calendar = Calendar.current
        typealias Sample = (daysAgo: Int, title: String?, text: String, mood: Double?, label: String?, category: String?)
        let samples: [Sample] = [
            (0, "Sea swim", "Went in at the Forty Foot before work. Freezing, but I felt awake for the whole day.\nNeed to remember a towel next time.", 0.7, "energised", "Health"),
            (0, nil, "Short one. Finished the bookshelf at last, only one screw left over.", 0.5, "satisfied", "Creativity"),
            (1, "Planning the trip", "Booked the train to Galway for the 14th. Still haven't decided whether to stay two nights or three.", 0.3, "hopeful", "Travel"),
            (3, nil, "Long day. The meeting ran over and I missed the bus, so I walked home and actually enjoyed it.", 0.1, "tired", "Work"),
            (4, nil, "Couldn't sleep again. Kept going over the conversation from Tuesday.", -0.6, "anxious", "Mind and emotions"),
            (5, nil, "Argued about the rent. Neither of us backed down.", -0.4, "frustrated", "Money"),
            (5, nil, "Made it up later over dinner. Still unsettled though.", 0.0, "unsettled", "Relationships"),
            (5, nil, "Wrote a list of what I actually want from the flat.", 0.2, "clear", "Personal growth"),
            (7, nil, "Rain all day. Stayed in and read.", -0.1, "flat", "Mind and emotions"),
            (9, "Gran's birthday", "Ninety-one today. She beat everyone at cards again.", 0.8, "joyful", "Family"),
            (12, nil, "Headache most of the day. Cancelled plans.", -0.8, "drained", "Health"),
            (14, nil, "Good feedback on the Henderson draft.", 0.4, "proud", "Work"),
            (2, nil, "Quick note, not read by the model yet.", nil, nil, nil),
        ]
        for (index, sample) in samples.enumerated() {
            let day = calendar.date(byAdding: .day, value: -sample.daysAgo, to: .now)!
            var entry = Entry.newTyped(on: DayDate(day), now: day.addingTimeInterval(Double(-index * 3_600)))
            entry.title = sample.title
            entry.originalText = sample.text
            entry.moodScore = sample.mood
            entry.moodLabel = sample.label
            entry.emotions = sample.label.map { [$0] } ?? []
            entry.primaryCategory = sample.category
            entry.needsAnalysis = sample.mood == nil
            entry.contentHash = Entry.contentHash(text: sample.text, date: entry.entryDate)
            try await store.save(entry)
        }
    }
}
#endif

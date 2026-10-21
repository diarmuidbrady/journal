import Foundation

/// The numbers behind one month of the mood calendar.
struct MonthSummary: Equatable {
    struct Day: Equatable {
        var date: DayDate
        var entryCount: Int
        /// Average of the scored entries; nil if none are scored yet.
        var averageMood: Double?
    }

    let year: Int
    let month: Int
    let days: [DayDate: Day]
    let entryCount: Int
    let averageMood: Double?
    let topEmotion: String?

    init(year: Int, month: Int, entries: [Entry]) {
        self.year = year
        self.month = month
        let inMonth = entries.filter { $0.entryDate.year == year && $0.entryDate.month == month }
        var days: [DayDate: Day] = [:]
        for (date, dayEntries) in Dictionary(grouping: inMonth, by: \.entryDate) {
            let scores = dayEntries.compactMap(\.moodScore)
            days[date] = Day(
                date: date,
                entryCount: dayEntries.count,
                averageMood: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            )
        }
        self.days = days
        entryCount = inMonth.count
        let scores = inMonth.compactMap(\.moodScore)
        averageMood = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let emotionCounts = Dictionary(inMonth.flatMap(\.emotions).map { ($0, 1) }, uniquingKeysWith: +)
        // Most frequent, only if it comes up more than once; ties go alphabetically
        // so the line doesn't flicker.
        topEmotion = emotionCounts
            .filter { $0.value > 1 }
            .max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// "12 entries · average mood +0.3 · most often calm"
    var line: String {
        guard entryCount > 0 else { return "No entries this month" }
        var parts = [entryCount == 1 ? "1 entry" : "\(entryCount) entries"]
        if let averageMood {
            parts.append("average mood \(averageMood.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false))))")
        } else {
            parts.append("mood not scored yet")
        }
        if let topEmotion { parts.append("most often \(topEmotion)") }
        return parts.joined(separator: " · ")
    }

    /// Weeks of the month as rows of 7, with nil padding, starting on `firstWeekday`.
    func weeks(calendar: Calendar = .current) -> [[DayDate?]] {
        let first = DayDate(year: year, month: month, day: 1)
        let firstDate = first.date(in: calendar)
        let dayCount = calendar.range(of: .day, in: .month, for: firstDate)!.count
        let weekday = calendar.component(.weekday, from: firstDate)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [DayDate?] = Array(repeating: nil, count: leading)
        cells += (1...dayCount).map { DayDate(year: year, month: month, day: $0) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

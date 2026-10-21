import Foundation

/// Dates cited in an answer, like [2026-10-14] or [2026-10-14, 2026-10-15].
enum Citations {
    static func dates(in text: String) -> [DayDate] {
        var dates: [DayDate] = []
        for match in text.matches(of: /\[(\d{4}-\d{2}-\d{2}(?:\s*[,;]\s*\d{4}-\d{2}-\d{2})*)\]/) {
            for part in match.1.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                if let date = DayDate(string: part.trimmingCharacters(in: .whitespaces)), !dates.contains(date) {
                    dates.append(date)
                }
            }
        }
        return dates
    }

    /// The answer with inline markdown (bold, italics) rendered and each cited date
    /// that matches an entry turned into a tappable link (journal://day/yyyy-MM-dd).
    /// Dates the model made up stay plain.
    static func linked(_ text: String, validDates: Set<DayDate>) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let plain = String(result.characters)
        for match in plain.matches(of: /\d{4}-\d{2}-\d{2}/) {
            guard let date = DayDate(string: String(match.output)), validDates.contains(date),
                  let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = URL(string: "journal://day/\(date.string)")
        }
        return result
    }
}

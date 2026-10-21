import Foundation

/// Word-level diff between the original and cleaned text, for the inline review.
enum WordDiff {
    enum Kind: Equatable {
        case same, removed, inserted
    }

    struct Segment: Equatable {
        var kind: Kind
        var text: String
    }

    static let paragraphBreak = "\n"

    /// Words with paragraph breaks kept as their own token.
    static func tokens(_ text: String) -> [String] {
        let paragraphs = text.split(separator: /\n\s*\n|\n/).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var tokens: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { tokens.append(paragraphBreak) }
            tokens += paragraph.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return tokens
    }

    static func segments(original: String, cleaned: String) -> [Segment] {
        let old = tokens(original)
        let new = tokens(cleaned)
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var segments: [Segment] = []
        func emit(_ kind: Kind, _ token: String) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += token == paragraphBreak || last.text.hasSuffix(paragraphBreak) ? token : " " + token
            } else {
                segments.append(Segment(kind: kind, text: token))
            }
        }

        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                emit(.removed, old[i])
                i += 1
            } else if j < new.count, inserted.contains(j) {
                emit(.inserted, new[j])
                j += 1
            } else {
                emit(.same, new[j])
                i += 1
                j += 1
            }
        }
        return segments
    }

    /// Inline rendering: removed words struck through in red, added words in green.
    static func attributed(original: String, cleaned: String) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in segments(original: original, cleaned: cleaned).enumerated() {
            // Paragraph breaks only count when they're in the cleaned text.
            let text = segment.kind == .removed
                ? segment.text.replacing(paragraphBreak, with: " ")
                : segment.text.replacing(paragraphBreak, with: "\n\n")
            let needsSpace = index > 0 && !result.characters.last!.isNewline && !text.hasPrefix("\n")
            var part = AttributedString((needsSpace ? " " : "") + text.trimmingCharacters(in: .init(charactersIn: " ")))
            switch segment.kind {
            case .same:
                break
            case .removed:
                part.foregroundColor = .red
                part.strikethroughStyle = .single
            case .inserted:
                part.foregroundColor = .green
            }
            result += part
        }
        return result
    }
}

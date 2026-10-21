import Foundation
import NaturalLanguage

struct CleanupResult: Sendable, Equatable {
    var text: String
    var warnings: [String]
    var aiVersion: String
}

/// Runs the cleanup prompt over an entry in paragraph-sized chunks (SPEC.md, AI cleanup).
struct CleanupEngine: Sendable {
    let model: any TextModel

    /// `progress` gets (chunk index, chunk count, text so far for this chunk).
    func clean(
        _ text: String,
        progress: @escaping @Sendable (_ chunk: Int, _ of: Int, _ partial: String) -> Void
    ) async throws -> CleanupResult {
        let chunks = Chunker.chunks(text)
        var cleaned: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(index, chunks.count, "")
            let output = try await model.generate(
                [ChatMessage(role: .user, content: Prompts.cleanup(chunk))],
                options: GenerationOptions(maxTokens: Self.maxTokens(for: chunk), temperature: 0.2),
                onText: { progress(index, chunks.count, $0) }
            )
            cleaned.append(Self.tidy(output))
        }
        let result = cleaned.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return CleanupResult(
            text: result,
            warnings: FactCheck.warnings(original: text, cleaned: result),
            aiVersion: "\(Prompts.cleanupVersion)@\(model.identifier)"
        )
    }

    /// Room for the chunk to come back a little longer (punctuation, paragraphs).
    static func maxTokens(for chunk: String) -> Int {
        Int(Double(chunk.count) / 3.0 * 1.3) + 64
    }

    /// Strips things small models sometimes add around the answer.
    static func tidy(_ output: String) -> String {
        var text = output.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        text = text.replacing("<<<", with: "").replacing(">>>", with: "")
        text = text.replacing(/^\s*(Text|Rewritten text|Here is the rewritten text)\s*:\s*/.ignoresCase(), with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits text into chunks of whole paragraphs, or whole sentences for long paragraphs
/// such as unbroken transcripts, so each fits the small model's context comfortably.
enum Chunker {
    static func chunks(_ text: String, target: Int = 1_200) -> [String] {
        let paragraphs = text
            .split(separator: /\n\s*\n/)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pieces = paragraphs.flatMap { $0.count > target ? sentenceGroups($0, target: target) : [$0] }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, current.count + piece.count + 2 > target {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func sentenceGroups(_ paragraph: String, target: Int) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        var groups: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count + 1 > target {
                groups.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}

/// Spots facts the cleanup may have dropped: names, numbers and negations
/// (SPEC.md, Quality check). Cheap heuristics, shown as "check these" in the review.
enum FactCheck {
    static let negations: Set<String> = [
        "not", "no", "never", "nothing", "nobody", "none", "neither", "nor", "cannot", "without",
    ]

    static func warnings(original: String, cleaned: String) -> [String] {
        var warnings: [String] = []
        let cleanedWords = Set(words(cleaned))
        let cleanedLower = Set(words(cleaned).map { $0.lowercased() })

        let missingNumbers = unique(numbers(original).filter { !numbers(cleaned).contains($0) })
        if !missingNumbers.isEmpty {
            warnings.append("Numbers not found in the cleaned text: \(missingNumbers.joined(separator: ", "))")
        }

        let missingNames = unique(names(original).filter { name in
            !words(name).allSatisfy { cleanedWords.contains($0) || cleanedLower.contains($0.lowercased()) }
        })
        if !missingNames.isEmpty {
            warnings.append("Names not found in the cleaned text: \(missingNames.joined(separator: ", "))")
        }

        let before = negationCount(original)
        let after = negationCount(cleaned)
        if after < before {
            warnings.append("Fewer negations (\"not\", \"never\", \"didn't\"…) than the original: \(after) instead of \(before). Check nothing flipped meaning.")
        }
        return warnings
    }

    static func numbers(_ text: String) -> [String] {
        text.matches(of: /\d+(?:[.,:]\d+)*/).map { String($0.output) }
    }

    /// People, places and organisations found by Apple's on-device name tagger, plus
    /// capitalised words that aren't the first word of a sentence or "I".
    static func names(_ text: String) -> [String] {
        var names: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                names.append(String(text[range]))
            }
            return true
        }
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            for word in words(sentence).dropFirst() {
                guard let first = word.first, first.isUppercase, word.count > 1 else { continue }
                if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { continue }
                if !names.contains(where: { $0.split(separator: " ").contains(Substring(word)) }) { names.append(word) }
            }
        }
        return names
    }

    static func negationCount(_ text: String) -> Int {
        words(text).map { $0.lowercased() }.filter { word in
            negations.contains(word) || word.hasSuffix("n't") || word.hasSuffix("n’t")
        }.count
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || "—–/".contains($0) })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))) }
            .filter { !$0.isEmpty }
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

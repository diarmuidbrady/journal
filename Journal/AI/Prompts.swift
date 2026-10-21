import Foundation

/// Prompts from SPEC.md, versioned. The version goes into `ai_version`.
enum Prompts {
    static let cleanupVersion = "cleanup-v1"

    static func cleanup(_ chunk: String) -> String {
        """
        You edit personal journal entries for readability.
        Rewrite the text below so it reads cleanly, following these rules:
        - Remove filler words (um, uh, like, you know, kind of, sort of, basically, I mean) when they add no meaning.
        - Remove false starts and repeated words or phrases. If the same point is made twice, keep the clearest version.
        - Fix punctuation and capitalisation. Split into paragraphs where the topic changes.
        - Keep the first person, the writer's own words, tone and feelings.
        - Keep every fact, name, number, event and emotion. Do not summarise.
        - Do not add anything new: no advice, no interpretation, no headings.
        Return only the rewritten text.

        Text:
        <<<\(chunk)>>>
        """
    }

    /// Entries are embedded as their text (excerpted like the analysis input).
    static let embeddingVersion = "embedding-v1"

    static let askVersion = "ask-v1"

    static func ask(_ question: String, context: String) -> String {
        """
        You help me reflect on my own journal. Answer my question using only the entries below.
        Be direct and specific. Point out patterns, contradictions and things I may be avoiding when the entries support it.
        If the entries do not contain enough to answer, say so.
        After each point, cite the entry date in brackets, e.g. [YYYY-MM-DD].
        Keep the whole answer under 200 words.

        Entries (date: text or summary):
        \(context)

        Question: \(question)
        """
    }

    /// Used when the material doesn't fit: each batch is reduced to notes first.
    static func askBatch(_ question: String, entries: String) -> String {
        """
        Here are some of my journal entries. Write short notes on everything in them that helps answer the question below: facts, feelings, patterns and contradictions.
        End each note with the entry date in brackets, e.g. [YYYY-MM-DD].
        If nothing is relevant, reply only: Nothing relevant.

        Entries:
        \(entries)

        Question: \(question)
        """
    }

    static let analysisVersion = "analysis-v1"

    static func analysis(_ text: String, categories: [String]) -> String {
        let list = categories.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            Read this journal entry and return JSON only:
            {"mood_score": number from -1.0 (very negative) to 1.0 (very positive); 0 is neutral, and an entry that is mostly stressed, worried, sad, angry, uneasy or tired is below 0,
             "mood_label": one word,
             "emotions": up to 3 single words,
             "summary": one or two sentences in the second person ("You..."),
             "themes": up to 5 short lowercase tags,
             "primary_category": exactly one of [\(list)],
             "secondary_categories": up to 2 of [\(list)],
             "suggested_category": a short new category name only if none fit, else null,
             "is_journal": true if this reads like a personal journal entry, false if it is a list, recipe or reference note}
            Base everything only on what the entry says.

            Entry:
            <<<\(text)>>>
            """
    }
}

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

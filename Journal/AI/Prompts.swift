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
}

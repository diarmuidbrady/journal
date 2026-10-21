import Foundation

/// The mood, summary, themes and categories the model gives one entry (SPEC.md, Prompts).
struct EntryAnalysis: Codable, Equatable, Sendable {
    var moodScore: Double
    var moodLabel: String
    var emotions: [String]
    var summary: String
    var themes: [String]
    var primaryCategory: String
    var secondaryCategories: [String]
    var suggestedCategory: String?
    var isJournal: Bool
}

/// Runs the analysis prompt with JSON output constrained by a grammar, so the reply
/// always parses and categories can only come from the list.
struct Analyzer: Sendable {
    let model: any TextModel

    /// Long entries are cut to their start and end so the prompt fits the context.
    static let maxCharacters = 6_000

    func analyze(_ text: String, categories: [String]) async throws -> EntryAnalysis {
        let output = try await model.generate(
            [ChatMessage(role: .user, content: Prompts.analysis(Self.excerpt(text), categories: categories))],
            options: GenerationOptions(maxTokens: 400, temperature: 0.2, grammar: AnalysisGrammar.make(categories: categories)),
            onText: { _ in }
        )
        return try Self.parse(output, categories: categories)
    }

    var aiVersion: String { "\(Prompts.analysisVersion)@\(model.identifier)" }

    static func excerpt(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(4_000)) + "\n[…]\n" + String(text.suffix(1_800))
    }

    /// Decodes and tidies the reply: clamps the score, normalises tags, drops
    /// duplicates, and ignores a "suggestion" that is already on the list.
    static func parse(_ output: String, categories: [String]) throws -> EntryAnalysis {
        let json = output.firstMatch(of: /\{[\s\S]*\}/).map { String($0.output) } ?? output
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var analysis = try decoder.decode(EntryAnalysis.self, from: Data(json.utf8))

        analysis.moodScore = min(1, max(-1, analysis.moodScore))
        analysis.moodLabel = analysis.moodLabel.trimmingCharacters(in: .whitespaces).lowercased()
        analysis.emotions = unique(analysis.emotions.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }).prefix(3).map { $0 }
        analysis.themes = unique(analysis.themes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }).prefix(5).map { $0 }
        analysis.summary = analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        analysis.secondaryCategories = unique(analysis.secondaryCategories)
            .filter { $0 != analysis.primaryCategory && categories.contains($0) }
            .prefix(2).map { $0 }
        if let suggestion = analysis.suggestedCategory?.trimmingCharacters(in: .whitespaces),
           !suggestion.isEmpty,
           !categories.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }) {
            analysis.suggestedCategory = suggestion
        } else {
            analysis.suggestedCategory = nil
        }
        return analysis
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// GBNF grammar for the analysis JSON (llama.cpp grammar-constrained sampling).
enum AnalysisGrammar {
    static func make(categories: [String]) -> String {
        let categoryRule = categories
            .map { "\"\\\"\(escape($0))\\\"\"" }
            .joined(separator: " | ")
        return #"""
            root ::= "{" ws "\"mood_score\":" ws score "," ws "\"mood_label\":" ws word "," ws "\"emotions\":" ws emotions "," ws "\"summary\":" ws text "," ws "\"themes\":" ws themes "," ws "\"primary_category\":" ws category "," ws "\"secondary_categories\":" ws secondary "," ws "\"suggested_category\":" ws suggestion "," ws "\"is_journal\":" ws boolean ws "}"
            score ::= "-"? ("0" ("." [0-9] [0-9]?)? | "1" (".0" "0"?)?)
            word ::= "\"" [a-zA-Z] [a-zA-Z-]{0,19} "\""
            emotions ::= "[" ws word (ws "," ws word){0,2} ws "]"
            tag ::= "\"" [a-z0-9] [a-z0-9 -]{0,29} "\""
            themes ::= "[" ws tag (ws "," ws tag){0,4} ws "]"
            text ::= "\"" char{1,400} "\""
            char ::= [^"\\\x00-\x1F] | "\\" ["\\/nt]
            secondary ::= "[" ws (category (ws "," ws category)?)? ws "]"
            suggestion ::= "null" | "\"" [A-Za-z] [A-Za-z &'-]{0,29} "\""
            boolean ::= "true" | "false"
            ws ::= [ \n]{0,2}
            """# + "\ncategory ::= \(categoryRule)\n"
    }

    /// Category names are limited to letters, digits, spaces and & ' - (see CategoryName),
    /// so only backslashes and quotes would need escaping; handle them anyway.
    private static func escape(_ name: String) -> String {
        name.replacing("\\", with: "\\\\\\\\").replacing("\"", with: "\\\\\\\"")
    }
}

/// `ai_version` records which prompt version and model produced each AI field, e.g.
/// "analysis-v1@qwen3.5-4b-q4_k_m;cleanup-v1@qwen3.5-4b-q4_k_m".
enum AIVersion {
    static func merging(_ existing: String?, _ version: String) -> String {
        let family = version.split(separator: "-v").first.map(String.init) ?? version
        var parts = parse(existing).filter { !$0.hasPrefix(family + "-v") }
        parts.append(version)
        return parts.sorted().joined(separator: ";")
    }

    static func parse(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let parts = value.split(separator: ";").map(String.init)
        // Phase 3 wrote "cleanup-v1;<model>".
        if parts.count == 2, !parts[0].contains("@"), !parts[1].contains("@"), !parts[1].contains("-v") {
            return ["\(parts[0])@\(parts[1])"]
        }
        return parts
    }
}

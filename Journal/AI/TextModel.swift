import Foundation

struct ChatMessage: Sendable {
    enum Role: String, Sendable {
        case system, user, assistant
    }

    var role: Role
    var content: String
}

struct GenerationOptions: Sendable {
    var maxTokens: Int
    var temperature: Float
}

/// An on-device text model. Implementations can be swapped (SPEC.md, Model choice):
/// llama.cpp today; Apple Foundation Models or a home server later.
protocol TextModel: Sendable {
    /// Recorded in `ai_version` with the prompt version.
    var identifier: String { get }

    /// Generates a reply. `onText` receives the text so far as it streams.
    func generate(
        _ messages: [ChatMessage],
        options: GenerationOptions,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

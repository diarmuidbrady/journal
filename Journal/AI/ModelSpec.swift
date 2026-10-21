import Foundation

/// A downloadable GGUF model, pinned to a repository revision and checksum
/// (SPEC.md, Installation: pinned URL with a checksum check).
struct ModelSpec: Sendable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64
    let licence: String
    /// Appended after the chat template's assistant header. For Qwen, an empty
    /// think block turns off "thinking" so it answers directly.
    let assistantPrefix: String
    var kind: Kind = .text

    enum Kind: Sendable {
        /// Writes: cleanup, analysis, answers.
        case text
        /// Turns text into vectors for "all entries" search.
        case embedding
    }
}

extension ModelSpec {
    static let qwen35_4B = ModelSpec(
        id: "qwen3.5-4b-q4_k_m",
        displayName: "Qwen3.5 4B (Q4_K_M)",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        sizeBytes: 2_740_937_888,
        licence: "Apache 2.0",
        assistantPrefix: "<think>\n\n</think>\n\n"
    )

    static let ministral3_3B = ModelSpec(
        id: "ministral-3-3b-instruct-2512-q4_k_m",
        displayName: "Ministral 3 3B Instruct (Q4_K_M)",
        fileName: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/eb599d408350ea2bb60452cb86be7c7b2fc28227/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf")!,
        sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
        sizeBytes: 2_147_023_008,
        licence: "Apache 2.0",
        assistantPrefix: ""
    )

    static let qwen3Embedding06B = ModelSpec(
        id: "qwen3-embedding-0.6b-q8_0",
        displayName: "Qwen3-Embedding 0.6B (Q8_0)",
        fileName: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf")!,
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439",
        sizeBytes: 639_150_592,
        licence: "Apache 2.0",
        assistantPrefix: "",
        kind: .embedding
    )

    /// The model the app downloads and uses for writing.
    static let current = qwen35_4B

    /// The model the app downloads and uses for search.
    static let currentEmbedding = qwen3Embedding06B
}

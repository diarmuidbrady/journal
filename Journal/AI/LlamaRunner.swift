import Foundation
#if canImport(llama)
import llama
#endif

enum LlamaError: LocalizedError {
    case unavailable
    case loadFailed
    case contextFailed
    case templateFailed
    case grammarInvalid
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The AI model only runs on a real iPhone, not in the Simulator."
        case .loadFailed: "The AI model couldn't be loaded. There may not be enough free memory; close other apps and try again."
        case .contextFailed: "The AI model couldn't start. There may not be enough free memory."
        case .templateFailed: "The prompt couldn't be prepared for this model."
        case .grammarInvalid: "The output format for the model is invalid."
        case .promptTooLong(let tokens, let limit): "The text is too long for the model (\(tokens) of \(limit) tokens)."
        case .decodeFailed(let code): "The AI model stopped unexpectedly (code \(code))."
        }
    }
}

#if canImport(llama)
/// Owns one llama.cpp model and context. The actor serialises all use of them.
actor LlamaRunner {
    let modelURL: URL
    let contextLength: Int

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?

    private static let backend: Void = {
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil)
    }()

    init(modelURL: URL, contextLength: Int = 4096) {
        self.modelURL = modelURL
        self.contextLength = contextLength
    }

    var isLoaded: Bool { context != nil }

    func load() throws {
        guard context == nil else { return }
        _ = Self.backend

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 999
        #endif
        guard let model = llama_model_load_from_file(modelURL.path(percentEncoded: false), modelParams) else {
            throw LlamaError.loadFailed
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = 512
        contextParams.n_threads = 4
        contextParams.n_threads_batch = 4
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
    }

    /// Frees the model's memory. It is loaded again on next use.
    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
    }

    /// Formats `messages` with the model's chat template, appends `assistantPrefix`,
    /// and samples a reply until end-of-generation or `maxTokens`.
    func generate(
        _ messages: [ChatMessage],
        options: GenerationOptions,
        assistantPrefix: String,
        onText: @Sendable (String) -> Void
    ) throws -> String {
        try load()
        guard let context, let vocab else { throw LlamaError.contextFailed }
        llama_memory_clear(llama_get_memory(context), true)

        var tokens = tokenize(try format(messages) + assistantPrefix)
        guard tokens.count + options.maxTokens <= contextLength else {
            throw LlamaError.promptTooLong(tokens: tokens.count + options.maxTokens, limit: contextLength)
        }

        // Prompt in batches.
        var start = 0
        while start < tokens.count {
            let count = min(512, tokens.count - start)
            let result = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
            }
            guard result == 0 else { throw LlamaError.decodeFailed(result) }
            start += count
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar = options.grammar {
            guard let grammarSampler = llama_sampler_init_grammar(vocab, grammar, "root") else {
                throw LlamaError.grammarInvalid
            }
            llama_sampler_chain_add(sampler, grammarSampler)
        }
        if options.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(options.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        var bytes: [UInt8] = []
        for _ in 0..<options.maxTokens {
            if Task.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            // Only report text that is valid UTF-8 so far (a character can span tokens).
            if let text = String(validating: bytes, as: UTF8.self) { onText(text) }
            let result = llama_decode(context, llama_batch_get_one(&token, 1))
            guard result == 0 else { throw LlamaError.decodeFailed(result) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func format(_ messages: [ChatMessage]) throws -> String {
        var allocations: [UnsafeMutablePointer<CChar>] = []
        defer { allocations.forEach { free($0) } }
        var chat = messages.map { message -> llama_chat_message in
            let role = strdup(message.role.rawValue)!
            let content = strdup(message.content)!
            allocations += [role, content]
            return llama_chat_message(role: role, content: content)
        }

        let template = llama_model_chat_template(model, nil)
        var capacity = messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 1024
        var buffer = [CChar](repeating: 0, count: capacity)
        var length = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(capacity))
        if length > capacity {
            capacity = Int(length)
            buffer = [CChar](repeating: 0, count: capacity)
            length = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(capacity))
        }
        guard length >= 0 else { throw LlamaError.templateFailed }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(count, 0))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }
}
#else
/// llama.cpp publishes no iOS Simulator build, so the app links it on devices only
/// and the Simulator gets this stand-in.
actor LlamaRunner {
    let modelURL: URL
    let contextLength: Int

    init(modelURL: URL, contextLength: Int = 4096) {
        self.modelURL = modelURL
        self.contextLength = contextLength
    }

    var isLoaded: Bool { false }

    func load() throws { throw LlamaError.unavailable }

    func unload() {}

    func generate(
        _ messages: [ChatMessage],
        options: GenerationOptions,
        assistantPrefix: String,
        onText: @Sendable (String) -> Void
    ) throws -> String {
        throw LlamaError.unavailable
    }
}
#endif

/// A GGUF model run on the phone with llama.cpp (Metal on device).
struct LlamaTextModel: TextModel {
    let spec: ModelSpec
    let runner: LlamaRunner

    init(spec: ModelSpec, fileURL: URL) {
        self.spec = spec
        self.runner = LlamaRunner(modelURL: fileURL)
    }

    var identifier: String { spec.id }

    func generate(
        _ messages: [ChatMessage],
        options: GenerationOptions,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await runner.generate(messages, options: options, assistantPrefix: spec.assistantPrefix, onText: onText)
    }
}

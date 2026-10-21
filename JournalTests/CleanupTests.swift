import Foundation
import Testing
@testable import Journal

/// Stands in for the on-device model: "cleans" by removing fillers from the chunk
/// inside <<< >>>, and records the prompts it received.
final class FakeTextModel: TextModel, @unchecked Sendable {
    var identifier: String { "fake-model" }
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }

    func generate(_ messages: [ChatMessage], options: GenerationOptions, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let prompt = messages.last?.content ?? ""
        lock.withLock { _prompts.append(prompt) }
        let chunk = prompt.firstMatch(of: /<<<([\s\S]*)>>>/).map { String($0.1) } ?? ""
        let cleaned = chunk.replacing(/\b(um|uh|like|you know),?\s*/.ignoresCase(), with: "")
        onText(cleaned)
        return cleaned
    }
}

struct ChunkerTests {
    @Test func keepsShortTextAsOneChunk() {
        #expect(Chunker.chunks("One paragraph.\n\nAnother one.") == ["One paragraph.\n\nAnother one."])
    }

    @Test func splitsLongUnbrokenTranscriptAtSentences() {
        let sentence = "I walked along the pier and thought about the week. "
        let transcript = String(repeating: sentence, count: 80)
        let chunks = Chunker.chunks(transcript, target: 1_200)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 1_200 })
        #expect(chunks.allSatisfy { $0.hasSuffix(".") }, "chunks end on sentence boundaries")
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        #expect(words(chunks.joined(separator: " ")) == words(transcript), "no words lost or added")
    }

    @Test func groupsParagraphsUpToTarget() {
        let paragraph = String(repeating: "a", count: 500)
        let chunks = Chunker.chunks([paragraph, paragraph, paragraph].joined(separator: "\n\n"), target: 1_200)
        #expect(chunks.count == 2)
        #expect(chunks[0] == paragraph + "\n\n" + paragraph)
    }
}

struct CleanupEngineTests {
    @Test func cleansEachChunkWithTheSpecPrompt() async throws {
        let model = FakeTextModel()
        let paragraph = String(repeating: "So um I went to the shop and, like, bought bread. ", count: 30)
        let text = paragraph + "\n\n" + paragraph

        let result = try await CleanupEngine(model: model).clean(text) { _, _, _ in }

        #expect(model.prompts.count > 1)
        #expect(model.prompts.allSatisfy { $0.contains("Keep every fact, name, number, event and emotion. Do not summarise.") })
        #expect(!result.text.contains("um "))
        #expect(result.aiVersion == "cleanup-v1@fake-model")
    }

    @Test func tidyStripsThinkingAndPreamble() {
        #expect(CleanupEngine.tidy("<think>\nhmm\n</think>\n\nHere is the rewritten text: I went home.") == "I went home.")
        #expect(CleanupEngine.tidy("<<<I went home.>>>") == "I went home.")
    }

    @Test func reportsProgressPerChunk() async throws {
        let model = FakeTextModel()
        let text = String(repeating: "A sentence about the day. ", count: 120)
        let seen = Seen()
        _ = try await CleanupEngine(model: model).clean(text) { chunk, count, _ in seen.add(chunk, count) }
        #expect(seen.chunks.first == 0)
        #expect(seen.counts.allSatisfy { $0 == model.prompts.count })
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var chunks: [Int] = []
        private(set) var counts: [Int] = []
        func add(_ chunk: Int, _ count: Int) { lock.withLock { chunks.append(chunk); counts.append(count) } }
    }
}

struct FactCheckTests {
    @Test func flagsMissingNamesNumbersAndNegations() {
        let original = "Maeve didn't come in at 6. I never want to do that again."
        let cleaned = "She came in. I want to do that again."
        let warnings = FactCheck.warnings(original: original, cleaned: cleaned)
        #expect(warnings.count == 3)
        #expect(warnings.contains { $0.hasPrefix("Numbers") && $0.contains("6") })
        #expect(warnings.contains { $0.hasPrefix("Names") && $0.contains("Maeve") })
        #expect(warnings.contains { $0.contains("negations") })
    }

    @Test func acceptsFaithfulCleanup() {
        let original = "So um we went to Kilkenny, me, Dad and Cian, and I didn't say anything."
        let cleaned = "We went to Kilkenny—me, Dad and Cian—and I didn’t say anything."
        #expect(FactCheck.warnings(original: original, cleaned: cleaned).isEmpty)
    }

    @Test func findsNamesButNotSentenceStartsOrI() {
        let names = FactCheck.names("Today I went out. Then Tom arrived. Maeve didn't.")
        #expect(names.contains("Tom"))
        #expect(names.contains("Maeve"))
        #expect(!names.contains("Today"))
        #expect(!names.contains("Then"))
        #expect(!names.contains("I"))
    }
}

struct WordDiffTests {
    @Test func marksRemovedAndInsertedWords() {
        let segments = WordDiff.segments(original: "So um I went home", cleaned: "I went home.")
        #expect(segments == [
            .init(kind: .removed, text: "So um"),
            .init(kind: .same, text: "I went"),
            .init(kind: .removed, text: "home"),
            .init(kind: .inserted, text: "home."),
        ])
    }

    @Test func keepsParagraphBreaksFromCleanedText() {
        let rendered = String(WordDiff.attributed(original: "One two three four", cleaned: "One two.\n\nThree four").characters)
        #expect(rendered.contains("\n\n"))
    }
}

@MainActor
struct EditorCleanupTests {
    @Test func acceptedCleanupIsStoredAlongsideOriginal() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, transcriber: FakeTranscriber(text: "And, um, more."))
        model.text = "So um I went to the Forty Foot, like, with Aoife."

        model.startCleanup(model: FakeTextModel())
        while model.cleanupReview == nil, model.isCleaning { try await Task.sleep(for: .milliseconds(10)) }
        let review = try #require(model.cleanupReview)
        #expect(review.result.text == "So I went to the Forty Foot, with Aoife.")

        await model.acceptCleanup(review.result.text + " Edited.", aiVersion: review.result.aiVersion)

        var saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.originalText == "So um I went to the Forty Foot, like, with Aoife.")
        #expect(saved.cleanedText == "So I went to the Forty Foot, with Aoife. Edited.")
        #expect(saved.showCleaned)
        #expect(saved.displayText == saved.cleanedText)
        #expect(saved.aiVersion == "cleanup-v1@fake-model")

        // Toggling to the original, and recordings appending to both versions.
        model.showCleaned = false
        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))
        saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(!saved.showCleaned)
        #expect(saved.originalText.hasSuffix("\n\nAnd, um, more."))
        #expect(saved.cleanedText?.hasSuffix("Edited.\n\nAnd, um, more.") == true)
    }

    @Test func discardLeavesEntryUnchanged() async throws {
        let test = try TestDatabase()
        let model = EntryEditorModel(store: test.store, entry: .newTyped(), isPersisted: false)
        model.text = "Um, hello."
        model.startCleanup(model: FakeTextModel())
        while model.cleanupReview == nil, model.isCleaning { try await Task.sleep(for: .milliseconds(10)) }

        model.discardCleanup()
        await model.flush()

        #expect(model.cleanedText == nil)
        #expect(model.visibleText == "Um, hello.")
    }

    @Test func modelFailureIsShown() async throws {
        let test = try TestDatabase()
        let model = EntryEditorModel(store: test.store, entry: .newTyped(), isPersisted: false)
        model.text = "Something to clean."
        let runner = LlamaTextModel(spec: .current, fileURL: test.directory.appending(path: "missing.gguf"))

        model.startCleanup(model: runner)
        while model.isCleaning { try await Task.sleep(for: .milliseconds(10)) }

        if case .failed = model.cleanup {} else { Issue.record("expected a failure, got \(model.cleanup)") }
        #expect(model.cleanupReview == nil)
    }
}

@MainActor
struct ModelStoreTests {
    @Test func verifiesAFileCopiedInAndBecomesReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ModelStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = Data("not really a model".utf8)
        let spec = ModelSpec(
            id: "tiny", displayName: "Tiny", fileName: "tiny.gguf",
            url: URL(string: "https://example.invalid/tiny.gguf")!,
            sha256: "1de4bc1fe6bd8f6b5fa2a1a2c3b55a1e2cad97b2b6bdaa36f99f5b0c0ff0c1ef",
            sizeBytes: Int64(contents.count), licence: "none", assistantPrefix: ""
        )
        try contents.write(to: directory.appending(path: "tiny.gguf"))

        let correct = try ModelStore.sha256(of: directory.appending(path: "tiny.gguf"))
        let store = ModelStore(spec: ModelSpec(
            id: spec.id, displayName: spec.displayName, fileName: spec.fileName, url: spec.url,
            sha256: correct, sizeBytes: spec.sizeBytes, licence: spec.licence, assistantPrefix: ""
        ), directory: directory)
        await store.refresh()
        #expect(store.status == .ready)
        #expect(store.textModel != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "tiny.gguf.verified").path))

        // A wrong checksum deletes the file.
        let wrong = ModelStore(spec: spec, directory: directory)
        try? FileManager.default.removeItem(at: directory.appending(path: "tiny.gguf.verified"))
        await wrong.refresh()
        if case .failed = wrong.status {} else { Issue.record("expected failure, got \(wrong.status)") }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "tiny.gguf").path))
    }

    @Test func missingFileIsNotDownloaded() async {
        let store = ModelStore(directory: FileManager.default.temporaryDirectory.appending(path: "empty-\(UUID().uuidString)"))
        await store.refresh()
        #expect(store.status == .notDownloaded)
    }

    @Test func pinnedModelURLIsAnImmutableRevision() {
        let url = ModelSpec.current.url.absoluteString
        #expect(url.hasPrefix("https://huggingface.co/"))
        #expect(url.firstMatch(of: /\/resolve\/[0-9a-f]{40}\//) != nil, "pinned to a commit, not a branch")
        #expect(ModelSpec.current.sha256.count == 64)
    }
}

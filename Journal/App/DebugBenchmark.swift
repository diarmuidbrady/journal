#if DEBUG
import Foundation
import os

/// Launched with `-ai-benchmark`, loads the model, cleans one invented entry, prints
/// timings and memory to the console, then exits. Never opens the journal. Debug builds only.
enum DebugBenchmark {
    static let isRequested = ProcessInfo.processInfo.arguments.contains("-ai-benchmark")

    private static let sample = """
        So um, today was, today was a lot. The ovens broke again at like six am, and Maeve didn't show up, she didn't even text, which is, you know, not like her. I had to do the whole morning bake by myself, like forty croissants and the sourdough, and I kind of, I kind of panicked a bit honestly. I never want to do that again. Anyway Tom from next door came in around nine and helped me carry the trays and I was so grateful, I mean really grateful.
        """

    @MainActor
    static func run() {
        Task {
            func log(_ message: String) {
                print("BENCH \(message) | available memory \(os_proc_available_memory() / 1_048_576) MB")
            }
            log("start")
            let store = ModelStore()
            let verifyStart = Date.now
            await store.refresh()
            log("model status \(store.status) after \(Date.now.timeIntervalSince(verifyStart).formatted(.number.precision(.fractionLength(1))))s")
            guard let model = store.textModel else {
                log("model not ready: \(store.status)")
                exit(1)
            }
            do {
                var start = Date.now
                try await model.runner.load()
                log("loaded in \(Date.now.timeIntervalSince(start).formatted(.number.precision(.fractionLength(1))))s")
                start = .now
                let result = try await CleanupEngine(model: model).clean(sample) { _, _, _ in }
                let seconds = Date.now.timeIntervalSince(start)
                log("cleaned \(sample.count)→\(result.text.count) chars in \(seconds.formatted(.number.precision(.fractionLength(1))))s, ~\(Int(Double(result.text.count) / 4 / seconds)) tok/s, warnings \(result.warnings)")
                print("BENCH output:\n\(result.text)")
                await model.runner.unload()
                log("unloaded")
                exit(0)
            } catch {
                log("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
#endif

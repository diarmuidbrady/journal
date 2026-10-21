import AVFoundation
import Speech

/// Turns a recording into text, entirely on the phone.
protocol Transcriber: Sendable {
    /// `progress` is called with 0…1 as the audio is processed.
    func transcribe(fileAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String
}

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: "On-device transcription doesn't support this phone's language."
        case .modelNotInstalled: "The speech model isn't downloaded yet. Download it in Settings, then use Transcribe recording."
        }
    }
}

/// A recognised stretch of speech with its position in the audio, in seconds.
struct TranscriptSegment: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

enum Transcript {
    /// A pause this long between segments starts a new paragraph.
    static let paragraphPause: Double = 2.5

    static func join(_ segments: [TranscriptSegment]) -> String {
        var result = ""
        var previousEnd: Double?
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previousEnd {
                result += segment.start - previousEnd >= paragraphPause ? "\n\n" : " "
            }
            result += text
            previousEnd = segment.end
        }
        return result
    }
}

/// Apple's SpeechAnalyzer (iOS 26). Uses SpeechTranscriber where the device supports
/// it, otherwise DictationTranscriber. Audio never leaves the phone.
struct OnDeviceTranscriber: Transcriber {
    private enum Engine: Sendable {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        init(locale: Locale) {
            if SpeechTranscriber.isAvailable {
                self = .speech(SpeechTranscriber(locale: locale, preset: .transcription))
            } else {
                self = .dictation(DictationTranscriber(locale: locale, preset: .longDictation))
            }
        }

        var module: any SpeechModule {
            switch self {
            case .speech(let module): module
            case .dictation(let module): module
            }
        }

        func collect(onSegment: @Sendable (TranscriptSegment) -> Void) async throws -> [TranscriptSegment] {
            var segments: [TranscriptSegment] = []
            switch self {
            case .speech(let module):
                for try await result in module.results {
                    segments.append(TranscriptSegment(text: String(result.text.characters), start: result.range.start.seconds, end: result.range.end.seconds))
                    onSegment(segments[segments.count - 1])
                }
            case .dictation(let module):
                for try await result in module.results {
                    segments.append(TranscriptSegment(text: String(result.text.characters), start: result.range.start.seconds, end: result.range.end.seconds))
                    onSegment(segments[segments.count - 1])
                }
            }
            return segments
        }
    }

    /// The phone's language if supported, else Irish, British or US English.
    static func locale() async throws -> Locale {
        let candidates = [Locale.current, Locale(identifier: "en_IE"), Locale(identifier: "en_GB"), Locale(identifier: "en_US")]
        for candidate in candidates {
            let supported = SpeechTranscriber.isAvailable
                ? await SpeechTranscriber.supportedLocale(equivalentTo: candidate)
                : await DictationTranscriber.supportedLocale(equivalentTo: candidate)
            if let supported { return supported }
        }
        throw TranscriptionError.unsupportedLanguage
    }

    static func modelStatus() async -> AssetInventory.Status {
        guard let locale = try? await locale() else { return .unsupported }
        return await AssetInventory.status(forModules: [Engine(locale: locale).module])
    }

    /// Asks iOS to download the speech model. This is the only network use, and it
    /// goes through the system's asset service: no audio or text is sent.
    static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let engine = Engine(locale: try await locale())
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module]) else { return }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    func transcribe(fileAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let engine = Engine(locale: try await Self.locale())
        guard await AssetInventory.status(forModules: [engine.module]) == .installed else {
            throw TranscriptionError.modelNotInstalled
        }

        let audioFile = try AVAudioFile(forReading: url)
        let duration = max(1, Double(audioFile.length) / audioFile.processingFormat.sampleRate)
        let collector = Task {
            try await engine.collect { progress(min(1, $0.end / duration)) }
        }

        let analyzer = SpeechAnalyzer(modules: [engine.module])
        do {
            if let end = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return Transcript.join(try await collector.value)
    }
}

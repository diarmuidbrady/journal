import AVFoundation
import Foundation
import Testing
@testable import Journal

/// Stands in for on-device transcription. `nil` text makes it fail.
struct FakeTranscriber: Transcriber {
    var text: String?

    struct Failure: LocalizedError {
        var errorDescription: String? { "Fake transcription failure" }
    }

    func transcribe(fileAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        progress(1)
        guard let text else { throw Failure() }
        return text
    }
}

enum ToneFile {
    /// Writes `seconds` of a 440 Hz tone as mono AAC, like the recorder produces.
    static func make(seconds: Double, in directory: URL) throws -> URL {
        let url = directory.appending(path: "tone-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
        }
        try file.write(from: buffer)
        return url
    }
}

struct AudioFilesTests {
    @Test func appendJoinsRecordings() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "entry.m4a")

        try await AudioFiles.append(try ToneFile.make(seconds: 1.5, in: directory), toRecordingAt: destination)
        #expect(abs(try await AudioFiles.duration(of: destination) - 1.5) < 0.2)

        try await AudioFiles.append(try ToneFile.make(seconds: 2, in: directory), toRecordingAt: destination)
        #expect(abs(try await AudioFiles.duration(of: destination) - 3.5) < 0.3)
    }
}

struct TranscriptTests {
    @Test func joinsSegmentsInOrderWithParagraphsAtPauses() {
        let segments = [
            TranscriptSegment(text: "Then I walked home.", start: 9, end: 11),
            TranscriptSegment(text: "Long day at work.", start: 0, end: 2),
            TranscriptSegment(text: " The meeting ran over. ", start: 2.2, end: 4),
            TranscriptSegment(text: "", start: 5, end: 5),
        ]
        #expect(Transcript.join(segments) == "Long day at work. The meeting ran over.\n\nThen I walked home.")
    }
}

@MainActor
struct RecordingTests {
    @Test func recordingIsSavedAndTranscriptAppended() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false,
                                     transcriber: FakeTranscriber(text: "Went for a long walk by the canal."))

        let segment = try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory)
        await model.addRecording(segmentAt: segment)

        let saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.originalText == "Went for a long walk by the canal.")
        #expect(saved.source == .audio)
        #expect(saved.audioPath == test.paths.audioRelativePath(for: entry.id))
        #expect(saved.audioDurationS == 1)
        #expect(FileManager.default.fileExists(atPath: test.paths.url(forRelativePath: saved.audioPath!).path))
        #expect(!FileManager.default.fileExists(atPath: segment.path), "segment is cleaned up")
        #expect(model.transcription == .idle)
    }

    @Test func secondRecordingAppendsAudioAndText() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false,
                                     transcriber: FakeTranscriber(text: "More thoughts."))
        model.text = "Typed first.  \n"

        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))
        await model.addRecording(segmentAt: try ToneFile.make(seconds: 2, in: test.paths.recordingsDirectory))

        let saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.originalText == "Typed first.\n\nMore thoughts.\n\nMore thoughts.")
        #expect(saved.source == .typed, "an entry that started typed stays typed")
        #expect(saved.audioDurationS == 3)
    }

    @Test func failedTranscriptionKeepsTheAudio() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, transcriber: FakeTranscriber(text: nil))

        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))

        let saved = try #require(try await test.store.fetch(id: entry.id), "audio-only entry is saved")
        #expect(saved.originalText.isEmpty)
        #expect(saved.audioPath != nil)
        #expect(model.transcription == .failed("Fake transcription failure"))
    }

    @Test func deletingRecordingKeepsText() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false,
                                     transcriber: FakeTranscriber(text: "Notes from the train."))
        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))
        let audioURL = try #require(model.audioURL)

        await model.deleteRecording()

        let saved = try #require(try await test.store.fetch(id: entry.id))
        #expect(saved.audioPath == nil)
        #expect(saved.audioDurationS == nil)
        #expect(saved.originalText == "Notes from the train.")
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func deletingEntryDeletesItsAudio() async throws {
        let test = try TestDatabase()
        let entry = Entry.newTyped()
        let model = EntryEditorModel(store: test.store, entry: entry, isPersisted: false, transcriber: FakeTranscriber(text: "Hi."))
        await model.addRecording(segmentAt: try ToneFile.make(seconds: 1, in: test.paths.recordingsDirectory))
        let audioURL = try #require(model.audioURL)

        try await test.store.delete(id: entry.id)

        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }
}

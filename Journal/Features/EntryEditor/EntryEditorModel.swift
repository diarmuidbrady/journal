import Foundation
import UIKit

/// Edits one entry and saves it automatically: at most every `saveInterval` while
/// typing, and immediately on `flush()` (leaving the screen or going to background).
/// Also records audio into the entry and appends its transcript.
@MainActor
@Observable
final class EntryEditorModel {
    enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    enum TranscriptionState: Equatable {
        case idle
        case running(Double)
        case failed(String)
    }

    var title: String {
        didSet { if title != oldValue { scheduleSave() } }
    }
    var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }
    var date: Date {
        didSet { if date != oldValue { dateWasEdited = true; scheduleSave() } }
    }

    private(set) var entry: Entry
    private(set) var saveState: SaveState = .saved
    private(set) var isPersisted: Bool
    private(set) var audioPath: String?
    private(set) var audioDuration: Int?
    private(set) var transcription: TranscriptionState = .idle
    private(set) var recordingError: String?

    let recorder = AudioRecorder()
    let player = AudioPlayer()

    private let store: EntryStore
    private let transcriber: any Transcriber
    private let saveInterval: Duration
    private var pendingSave: Task<Void, Never>?
    private var dateWasEdited = false
    private var source: Entry.Source
    private var recordingSegment: URL?

    init(
        store: EntryStore,
        entry: Entry,
        isPersisted: Bool,
        transcriber: any Transcriber = OnDeviceTranscriber(),
        saveInterval: Duration = .seconds(2)
    ) {
        self.store = store
        self.entry = entry
        self.isPersisted = isPersisted
        self.transcriber = transcriber
        self.saveInterval = saveInterval
        self.title = entry.title ?? ""
        self.text = entry.originalText
        self.date = entry.entryDate.date()
        self.audioPath = entry.audioPath
        self.audioDuration = entry.audioDurationS
        self.source = entry.source
    }

    var isNew: Bool { !isPersisted }

    var isRecording: Bool { recorder.state != .idle }

    var isTranscribing: Bool {
        if case .running = transcription { return true }
        return false
    }

    var audioURL: URL? { audioPath.map(store.paths.url(forRelativePath:)) }

    // MARK: Saving

    private func scheduleSave() {
        saveState = .pending
        // Throttle rather than debounce, so continuous typing still saves every few seconds.
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, saveInterval] in
            try? await Task.sleep(for: saveInterval)
            guard !Task.isCancelled, let self else { return }
            // Clear the handle first so flush() doesn't cancel this task mid-write.
            self.pendingSave = nil
            await self.flush()
        }
    }

    /// Saves any unsaved changes now.
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil

        var updated = entry
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        updated.originalText = text
        updated.entryDate = DayDate(date)
        if dateWasEdited { updated.dateSource = .manual }
        updated.source = source
        updated.audioPath = audioPath
        updated.audioDurationS = audioDuration
        updated.contentHash = Entry.contentHash(text: text, date: updated.entryDate)

        guard updated != entry || !isPersisted else {
            saveState = .saved
            return
        }
        // Don't create a row for a new entry that is still blank.
        guard isPersisted || !updated.isEmpty else {
            saveState = .saved
            return
        }

        updated.updatedAt = .now
        do {
            try await store.save(updated)
            entry = updated
            isPersisted = true
            if pendingSave == nil { saveState = .saved }
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: Recording

    func startRecording() async {
        guard !isRecording, !isTranscribing else { return }
        recordingError = nil
        player.unload()
        let segment = store.paths.newRecordingURL()
        do {
            try await recorder.start(writingTo: segment)
            recordingSegment = segment
        } catch {
            recordingError = error.localizedDescription
        }
    }

    /// Stops recording, adds the audio to the entry and transcribes it.
    func stopRecording() async {
        guard isRecording, let segment = recordingSegment else { return }
        recorder.stop()
        recordingSegment = nil
        await addRecording(segmentAt: segment)
    }

    /// Adds a finished recording to the entry, saves, then appends its transcript.
    /// The audio is saved first so a long or interrupted transcription can't lose it.
    func addRecording(segmentAt segment: URL) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save recording")
        defer {
            try? FileManager.default.removeItem(at: segment)
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }

        let relativePath = store.paths.audioRelativePath(for: entry.id)
        let destination = store.paths.url(forRelativePath: relativePath)
        do {
            player.unload()
            try await AudioFiles.append(segment, toRecordingAt: destination)
            audioPath = relativePath
            audioDuration = Int((try await AudioFiles.duration(of: destination)).rounded())
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isPersisted { source = .audio }
            await flush()
        } catch {
            recordingError = "The recording couldn't be saved: \(error.localizedDescription)"
            return
        }

        await transcribe(fileAt: segment)
    }

    /// Transcribes the entry's whole recording again and appends the result.
    func transcribeRecording() async {
        guard let audioURL, !isRecording, !isTranscribing else { return }
        await transcribe(fileAt: audioURL)
    }

    private func transcribe(fileAt url: URL) async {
        transcription = .running(0)
        do {
            let transcript = try await transcriber.transcribe(fileAt: url) { fraction in
                Task { @MainActor [weak self] in
                    if case .running = self?.transcription { self?.transcription = .running(fraction) }
                }
            }
            appendTranscript(transcript)
            transcription = .idle
            await flush()
        } catch {
            transcription = .failed(error.localizedDescription)
        }
    }

    private func appendTranscript(_ transcript: String) {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = transcript
        } else {
            text = text.replacing(/\s+$/, with: "") + "\n\n" + transcript
        }
    }

    func dismissTranscriptionError() {
        if case .failed = transcription { transcription = .idle }
    }

    func deleteRecording() async {
        guard let audioURL, !isRecording, !isTranscribing else { return }
        player.unload()
        try? FileManager.default.removeItem(at: audioURL)
        audioPath = nil
        audioDuration = nil
        await flush()
    }
}

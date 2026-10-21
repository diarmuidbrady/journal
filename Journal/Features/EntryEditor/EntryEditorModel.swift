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
    /// The accepted cleanup. The original `text` is never changed by cleanup.
    var cleanedText: String? {
        didSet { if cleanedText != oldValue { scheduleSave() } }
    }
    var showCleaned: Bool {
        didSet { if showCleaned != oldValue { scheduleSave() } }
    }

    enum CleanupState: Equatable {
        case idle
        case running(chunk: Int, of: Int, partial: String)
        case failed(String)
    }

    struct CleanupReview: Identifiable {
        let id = UUID()
        var original: String
        var result: CleanupResult
    }

    private(set) var cleanup: CleanupState = .idle
    /// Set when a cleanup finishes; drives the review sheet.
    var cleanupReview: CleanupReview?

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
    private var cleanupTask: Task<Void, Never>?

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
        self.cleanedText = entry.cleanedText
        self.showCleaned = entry.showCleaned
    }

    var isNew: Bool { !isPersisted }

    var isShowingCleaned: Bool { showCleaned && cleanedText != nil }

    /// The text the editor shows and edits: the cleaned version or the original.
    var visibleText: String {
        get { isShowingCleaned ? cleanedText ?? "" : text }
        set {
            if isShowingCleaned { cleanedText = newValue } else { text = newValue }
        }
    }

    var isCleaning: Bool {
        if case .running = cleanup { return true }
        return false
    }

    var canCleanUp: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRecording && !isTranscribing && !isCleaning
    }

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
        updated.cleanedText = cleanedText
        updated.showCleaned = isShowingCleaned
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
            try await store.saveFromEditor(updated, isNew: !isPersisted, textChanged: updated.analysisText != entry.analysisText)
            entry = updated
            isPersisted = true
            if pendingSave == nil { saveState = .saved }
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: Recording

    func startRecording() async {
        guard !isRecording, !isTranscribing, !isCleaning else { return }
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

    /// Appends to the original and, if there is one, the cleaned version, so a new
    /// recording shows whichever version is displayed. Clean up again to tidy it.
    private func appendTranscript(_ transcript: String) {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        text = Self.appending(transcript, to: text)
        if let cleanedText { self.cleanedText = Self.appending(transcript, to: cleanedText) }
    }

    private static func appending(_ addition: String, to existing: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? addition
            : existing.replacing(/\s+$/, with: "") + "\n\n" + addition
    }

    func dismissTranscriptionError() {
        if case .failed = transcription { transcription = .idle }
    }

    // MARK: Cleanup

    /// Cleans the original text with `model`; the result waits in `cleanupReview`.
    func startCleanup(model: any TextModel) {
        guard canCleanUp else { return }
        let original = text
        cleanup = .running(chunk: 0, of: 1, partial: "")
        cleanupTask = Task {
            do {
                let result = try await CleanupEngine(model: model).clean(original) { chunk, count, partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCleaning else { return }
                        self.cleanup = .running(chunk: chunk, of: count, partial: partial)
                    }
                }
                cleanup = .idle
                cleanupReview = CleanupReview(original: original, result: result)
            } catch is CancellationError {
                cleanup = .idle
            } catch {
                cleanup = .failed(error.localizedDescription)
            }
            cleanupTask = nil
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    /// Stores the reviewed text as the cleaned version and shows it.
    func acceptCleanup(_ cleaned: String, aiVersion: String) async {
        cleanedText = cleaned
        showCleaned = true
        cleanupReview = nil
        await flush()
        try? await store.recordAIVersion(aiVersion, for: entry.id)
    }

    func discardCleanup() {
        cleanupReview = nil
    }

    func dismissCleanupError() {
        if case .failed = cleanup { cleanup = .idle }
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

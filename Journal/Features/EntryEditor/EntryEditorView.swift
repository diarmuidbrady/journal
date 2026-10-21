import SwiftUI

struct EntryEditorView: View {
    @State private var model: EntryEditorModel
    @Environment(SpeechModel.self) private var speechModel
    @Environment(ModelStore.self) private var modelStore
    @Environment(AnalysisQueue.self) private var analysisQueue
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var bodyFocused: Bool
    @State private var confirmingModelDownload = false
    @State private var confirmingRetranscribe = false
    @State private var confirmingDeleteRecording = false
    @State private var confirmingRecleanup = false
    @State private var showingModelNeeded = false

    private let store: EntryStore

    init(store: EntryStore, entry: Entry, isNew: Bool) {
        self.store = store
        _model = State(initialValue: EntryEditorModel(store: store, entry: entry, isPersisted: !isNew))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title (optional)", text: $model.title, axis: .vertical)
                .font(.title2.bold())
                .lineLimit(1...3)

            DatePicker("Date", selection: $model.date, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()

            if model.isPersisted {
                EntryInsightsView(store: store, entryID: model.entry.id)
            }

            if let audioURL = model.audioURL {
                RecordingRow(
                    player: model.player,
                    url: audioURL,
                    duration: TimeInterval(model.audioDuration ?? 0),
                    isBusy: model.isRecording || model.isTranscribing,
                    onTranscribe: { confirmingRetranscribe = true },
                    onDelete: { confirmingDeleteRecording = true }
                )
            }

            transcriptionStatus
            cleanupStatus

            if model.cleanedText != nil {
                Picker("Version", selection: $model.showCleaned) {
                    Text("Cleaned").tag(true)
                    Text("Original").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(model.isCleaning)
            }

            TextEditor(text: $model.visibleText)
                .focused($bodyFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .disabled(model.isCleaning)
                .overlay(alignment: .topLeading) {
                    if model.visibleText.isEmpty {
                        Text("Write, or tap the microphone to talk…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                saveStatus
            }
        }
        .onAppear {
            if model.isNew { bodyFocused = true }
            // Background analysis waits while an entry is open, so it never competes
            // with typing, recording or cleanup, and runs once the entry is finished.
            analysisQueue.editorOpened()
        }
        .task { await speechModel.refresh() }
        .onDisappear {
            Task {
                if model.isRecording { await model.stopRecording() } else { await model.flush() }
                analysisQueue.editorClosed()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background where model.isRecording:
                // Without background audio the recorder can't continue, so keep what we have.
                Task { await model.stopRecording() }
            case .background where model.isCleaning:
                // iOS doesn't allow GPU work in the background.
                model.cancelCleanup()
            case .inactive, .background:
                model.player.pause()
                Task { await model.flush() }
            default:
                break
            }
        }
        .confirmationDialog("Download the speech model?", isPresented: $confirmingModelDownload, titleVisibility: .visible) {
            Button("Download and record") {
                Task { await speechModel.download() }
                startRecording()
            }
            Button("Record without transcribing") { startRecording() }
        } message: {
            Text("Transcription runs on this iPhone and needs Apple's speech model, a one-time download through iOS. No recordings or journal text are sent. You can transcribe later from the recording's menu.")
        }
        .confirmationDialog("Transcribe the whole recording again?", isPresented: $confirmingRetranscribe, titleVisibility: .visible) {
            Button("Transcribe and add to entry") { Task { await model.transcribeRecording() } }
        } message: {
            Text("The new transcript is added to the end of the entry. Your existing text isn't changed.")
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDeleteRecording, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) { Task { await model.deleteRecording() } }
        } message: {
            Text("The entry's text is kept. The audio can't be recovered.")
        }
        .confirmationDialog("Clean up again?", isPresented: $confirmingRecleanup, titleVisibility: .visible) {
            Button("Clean up the original again") { runCleanup() }
        } message: {
            Text("This cleans the original text again. If you accept, it replaces the current cleaned version, including any edits you made to it.")
        }
        .alert("Download the AI model first", isPresented: $showingModelNeeded) {
            Button("Download now (\(modelSize))") { modelStore.download() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Cleanup runs on this iPhone with \(modelStore.spec.displayName). It's a one-time \(modelSize) download over Wi-Fi from Hugging Face. Keep Journal open while it downloads. Progress is in Settings.")
        }
        .sheet(item: $model.cleanupReview) { review in
            CleanupReviewView(review: review) { cleaned in
                Task { await model.acceptCleanup(cleaned, aiVersion: review.result.aiVersion) }
            } onDiscard: {
                model.discardCleanup()
            }
        }
    }

    private var modelSize: String {
        ByteCountFormatter.string(fromByteCount: modelStore.spec.sizeBytes, countStyle: .file)
    }

    private func cleanupTapped() {
        guard modelStore.status == .ready, modelStore.textModel != nil else {
            showingModelNeeded = true
            return
        }
        if model.cleanedText != nil {
            confirmingRecleanup = true
        } else {
            runCleanup()
        }
    }

    private func runCleanup() {
        guard let textModel = modelStore.textModel else { return }
        bodyFocused = false
        model.startCleanup(model: textModel)
    }

    private func micTapped() {
        if speechModel.status == .notInstalled {
            confirmingModelDownload = true
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        bodyFocused = false
        Task { await model.startRecording() }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if model.isRecording {
            RecorderPanel(recorder: model.recorder) {
                Task { await model.stopRecording() }
            }
        } else if case .running(let chunk, let count, let partial) = model.cleanup {
            CleanupPanel(chunk: chunk, count: count, partial: partial) {
                model.cancelCleanup()
            }
        } else {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timestamps)
                    if let error = model.recordingError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: cleanupTapped) {
                    Label("Clean up", systemImage: "wand.and.stars")
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!model.canCleanUp)
                Button(action: micTapped) {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(model.isTranscribing || model.isCleaning)
                .accessibilityLabel("Record")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch model.transcription {
        case .idle:
            EmptyView()
        case .running(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribing on this iPhone…").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: fraction)
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.dismissTranscriptionError() }
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var cleanupStatus: some View {
        if case .failed(let message) = model.cleanup {
            HStack(alignment: .top) {
                Label("Cleanup failed: \(message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.dismissCleanupError() }
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
        }
    }

    private var timestamps: String {
        guard model.isPersisted else { return "New entry" }
        let created = model.entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        let updated = model.entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return created == updated ? "Created \(created)" : "Created \(created) · Edited \(updated)"
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch model.saveState {
        case .saved:
            if model.isPersisted {
                Label("Saved", systemImage: "checkmark.circle").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
            }
        case .pending:
            Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label("Not saved: \(message)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }
}

/// Live waveform, elapsed time, pause/resume and done, shown while recording.
private struct RecorderPanel: View {
    let recorder: AudioRecorder
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            WaveformView(levels: recorder.levels)
                .frame(height: 48)
                .opacity(recorder.state == .paused ? 0.4 : 1)
            HStack {
                Label(recorder.state == .paused ? "Paused" : "Recording", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(recorder.state == .paused ? Color.secondary : Color.red)
                    .font(.caption)
                Spacer()
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.title3.monospacedDigit())
                Spacer()
                Button {
                    recorder.state == .paused ? recorder.resume() : recorder.pause()
                } label: {
                    Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")
                Button(action: onDone) {
                    Image(systemName: "stop.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
                .accessibilityLabel("Stop and transcribe")
            }
        }
        .padding()
        .background(.bar)
    }
}

/// Progress, live output and cancel while the model cleans up the entry.
private struct CleanupPanel: View {
    let chunk: Int
    let count: Int
    let partial: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(count > 1 ? "Cleaning up on this iPhone · part \(chunk + 1) of \(count)" : "Cleaning up on this iPhone…")
                    .font(.subheadline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            ProgressView(value: Double(chunk), total: Double(max(count, 1)))
            Text(partial.isEmpty ? "Reading…" : partial)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .truncationMode(.head)
        }
        .padding()
        .background(.bar)
    }
}

/// Play/pause, scrubber and a menu for the entry's recording.
private struct RecordingRow: View {
    let player: AudioPlayer
    let url: URL
    let duration: TimeInterval
    let isBusy: Bool
    let onTranscribe: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(isBusy)
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(duration, player.duration, 1)
            )
            .disabled(isBusy)

            Text(Duration.seconds(max(duration, player.duration) - player.currentTime).formatted(.time(pattern: .minuteSecond)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Button("Transcribe recording", systemImage: "text.bubble", action: onTranscribe)
                Button("Delete recording", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isBusy)
            .accessibilityLabel("Recording options")
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}

import AVFoundation
import UIKit

/// Records mono AAC (.m4a) with pause/resume, elapsed time and live levels for the waveform.
@MainActor
@Observable
final class AudioRecorder {
    enum State {
        case idle, recording, paused
    }

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Turn it on in Settings → Apps → Journal."
            case .couldNotStart: "The recording couldn't start."
            }
        }
    }

    static let levelCount = 60

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels from 0 to 1, oldest first.
    private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var interruptionObserver: (any NSObjectProtocol)?

    func start(writingTo url: URL) async throws {
        guard state == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }

        self.recorder = recorder
        state = .recording
        elapsed = 0
        levels = []
        // Keep the screen awake while talking; the app stops recording if it goes to the background.
        UIApplication.shared.isIdleTimerDisabled = true
        startMetering()
        observeInterruptions()
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, recorder?.record() == true else { return }
        state = .recording
    }

    /// Finishes the file and returns its length in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        meterTask?.cancel()
        meterTask = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        return duration
    }

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleLevel()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func sampleLevel() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (−160…0); map the useful −50…0 range to 0…1.
        let level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        levels.append(level)
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
        elapsed = recorder.currentTime
    }

    /// A phone call or Siri pauses the recorder; reflect that so Resume is offered.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            MainActor.assumeIsolated {
                if self?.state == .recording { self?.state = .paused }
            }
        }
    }
}

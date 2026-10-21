import AVFoundation

/// Plays an entry's recording with a scrubbable position.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var progressTask: Task<Void, Never>?

    func toggle(url: URL) {
        if isPlaying {
            pause()
            return
        }
        do {
            if loadedURL != url || player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                loadedURL = url
                duration = player?.duration ?? 0
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player?.play()
            isPlaying = true
            errorMessage = nil
            trackProgress()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        progressTask?.cancel()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    /// Stops and forgets the file, e.g. before it is replaced or deleted.
    func unload() {
        pause()
        player = nil
        loadedURL = nil
        currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func trackProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled, let self, let player = self.player {
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    if player.currentTime == 0 { self.currentTime = 0 }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

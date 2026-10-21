import AVFoundation

/// File operations on recordings.
enum AudioFiles {
    enum AudioFileError: LocalizedError {
        case noAudioTrack
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The recording has no audio."
            case .exportFailed: "The recordings couldn't be joined."
            }
        }
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Writes `first` followed by `second` to `output` as AAC (.m4a).
    static func concatenate(_ first: URL, _ second: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioFileError.exportFailed
        }
        var cursor = CMTime.zero
        for url in [first, second] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioFileError.noAudioTrack }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioFileError.exportFailed
        }
        try await export.export(to: output, as: .m4a)
    }

    /// Adds `segment` to the end of the recording at `destination`, or copies it there
    /// if there is no recording yet. The segment itself is left in place.
    static func append(_ segment: URL, toRecordingAt destination: URL) async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.copyItem(at: segment, to: destination)
        } else {
            let joined = destination.deletingLastPathComponent().appending(path: "joining-\(UUID().uuidString).m4a")
            defer { try? fileManager.removeItem(at: joined) }
            try await concatenate(destination, segment, to: joined)
            _ = try fileManager.replaceItemAt(destination, withItemAt: joined)
        }
        try protectCompletely(destination)
    }

    /// iOS Data Protection "complete": unreadable while the phone is locked (SPEC.md).
    static func protectCompletely(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

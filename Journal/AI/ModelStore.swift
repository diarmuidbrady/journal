import CryptoKit
import Foundation
import os
import UIKit

/// Downloads, verifies and holds the on-device text model (SPEC.md, Installation).
/// The only network request is to the pinned model URL, over Wi-Fi only.
@MainActor
@Observable
final class ModelStore {
    enum Status: Equatable {
        case checking
        case notDownloaded
        case downloading(Double)
        case verifying
        case ready
        case failed(String)
    }

    let spec: ModelSpec
    let directory: URL
    private(set) var status: Status = .checking
    private(set) var textModel: LlamaTextModel?

    private var downloadTask: Task<Void, Never>?

    init(
        spec: ModelSpec = .current,
        directory: URL = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    ) {
        self.spec = spec
        self.directory = directory
    }

    var fileURL: URL { directory.appending(path: spec.fileName) }
    private var markerURL: URL { directory.appending(path: spec.fileName + ".verified") }

    var isBusy: Bool {
        switch status {
        case .downloading, .verifying, .checking: true
        default: false
        }
    }

    /// Checks what's on disk. A file of the right size without a verified marker,
    /// for example one copied in during install, is verified first.
    func refresh() async {
        switch status {
        case .downloading, .verifying: return
        default: break
        }
        try? prepareDirectory()
        let marker = try? String(contentsOf: markerURL, encoding: .utf8)
        if marker == spec.sha256, fileSize == spec.sizeBytes {
            becomeReady()
        } else if fileSize == spec.sizeBytes {
            await verify()
        } else {
            status = .notDownloaded
        }
    }

    func download() {
        guard downloadTask == nil else { return }
        downloadTask = Task {
            await performDownload()
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Frees the model's memory, e.g. when the app goes to the background.
    func unloadFromMemory() async {
        await textModel?.runner.unload()
    }

    func deleteModel() async {
        cancelDownload()
        await unloadFromMemory()
        textModel = nil
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: markerURL)
        status = .notDownloaded
    }

    private var fileSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
    }

    private func becomeReady() {
        status = .ready
        if textModel == nil { textModel = LlamaTextModel(spec: spec, fileURL: fileURL) }
    }

    private func performDownload() async {
        status = .downloading(0)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            try prepareDirectory()
            var request = URLRequest(url: spec.url)
            // SPEC.md: downloaded over Wi-Fi. This also rules out a phone hotspot.
            request.allowsCellularAccess = false
            request.allowsExpensiveNetworkAccess = false

            let capture = TaskCapture()
            let expected = Double(spec.sizeBytes)
            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    let received = capture.task.withLock { $0?.countOfBytesReceived } ?? 0
                    if case .downloading = self?.status { self?.status = .downloading(min(1, Double(received) / expected)) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { watcher.cancel() }

            let (temporaryURL, response) = try await URLSession.shared.download(for: request, delegate: capture)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: markerURL)
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            await verify()
        } catch is CancellationError {
            status = .notDownloaded
        } catch let error as URLError where error.code == .cancelled {
            status = .notDownloaded
        } catch let error as URLError where error.networkUnavailableReason != nil || error.code == .notConnectedToInternet {
            status = .failed("The model downloads over Wi-Fi only. Connect to Wi-Fi and try again.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func verify() async {
        status = .verifying
        let url = fileURL
        let expected = spec.sha256
        let matches = await Task.detached(priority: .userInitiated) {
            (try? Self.sha256(of: url)) == expected
        }.value
        if matches {
            try? spec.sha256.write(to: markerURL, atomically: true, encoding: .utf8)
            becomeReady()
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            status = .failed("The downloaded model didn't match its checksum, so it was deleted. Try again.")
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A 2–3 GB public file has no place in iCloud backups.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var finished = false
        while !finished {
            // Without a pool, each 16 MB read lingers until the loop ends: gigabytes on iOS.
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 16 * 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    finished = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Captures the download task so its byte count can be read for progress.
private final class TaskCapture: NSObject, URLSessionTaskDelegate, Sendable {
    let task = OSAllocatedUnfairLock<URLSessionTask?>(initialState: nil)

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        self.task.withLock { $0 = task }
    }
}

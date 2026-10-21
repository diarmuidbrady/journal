import Foundation

/// Whether Apple's on-device speech model is installed, and downloading it on request.
@MainActor
@Observable
final class SpeechModel {
    enum Status: Equatable {
        case checking
        case installed
        case notInstalled
        case downloading(Double)
        case unsupported
        case failed(String)
    }

    private(set) var status: Status = .checking

    var isInstalled: Bool { status == .installed }

    func refresh() async {
        if case .downloading = status { return }
        status = switch await OnDeviceTranscriber.modelStatus() {
        case .installed: .installed
        case .supported: .notInstalled
        case .downloading: .downloading(0)
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    func download() async {
        if case .downloading = status { return }
        status = .downloading(0)
        do {
            try await OnDeviceTranscriber.downloadModel { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.status { self?.status = .downloading(fraction) }
                }
            }
            status = .installed
            await refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

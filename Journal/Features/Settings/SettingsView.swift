import SwiftUI

struct SettingsView: View {
    let store: EntryStore
    let entryCount: Int

    @Environment(Vault.self) private var vault
    @Environment(SpeechModel.self) private var speechModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Lock after", value: "1 minute in background")
                    Button("Lock now", systemImage: "lock") {
                        dismiss()
                        vault.lock()
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("The journal also locks every time the app is launched.")
                }

                Section {
                    LabeledContent("Entries", value: entryCount.formatted())
                    ShareLink(item: ExportFile(store: store), preview: SharePreview("Journal export")) {
                        Label("Export everything", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Exports a zip with a plain JSON file of every entry and all recordings. It is not encrypted: anyone who has it can read your journal, including any cloud service you save it to.")
                }

                Section {
                    speechModelRow
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Recordings are transcribed on this iPhone. If the speech model isn't installed, iOS downloads it once from Apple. No recordings or journal text are sent.")
                }

                Section("Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        PrivacyPoint("Everything stays on this iPhone, including transcription. The app itself makes no network requests.")
                        PrivacyPoint("The database is encrypted with a key that only Face ID or your passcode can unlock.")
                        PrivacyPoint("Journal data is left out of iCloud device backups. Export regularly to keep your own copy.")
                        PrivacyPoint("No analytics, crash reporting or third-party services.")
                    }
                    .font(.callout)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await speechModel.refresh() }
        }
    }

    @ViewBuilder
    private var speechModelRow: some View {
        switch speechModel.status {
        case .checking:
            LabeledContent("Speech model", value: "Checking…")
        case .installed:
            LabeledContent("Speech model", value: "Installed")
        case .notInstalled:
            Button("Download speech model", systemImage: "arrow.down.circle") {
                Task { await speechModel.download() }
            }
        case .downloading(let fraction):
            LabeledContent("Speech model") {
                ProgressView(value: fraction).frame(width: 120)
            }
        case .unsupported:
            LabeledContent("Speech model", value: "Not available for this language")
        case .failed(let message):
            VStack(alignment: .leading) {
                Button("Retry download", systemImage: "arrow.clockwise") {
                    Task { await speechModel.download() }
                }
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct PrivacyPoint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "checkmark.shield")
    }
}

private extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

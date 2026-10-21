import SwiftUI

struct SettingsView: View {
    let store: EntryStore
    let entryCount: Int

    @Environment(Vault.self) private var vault
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
                    Text("Exports a plain JSON file of every entry. The file is not encrypted: anyone who has it can read your journal, including any cloud service you save it to.")
                }

                Section("Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        PrivacyPoint("Everything stays on this iPhone. The app makes no network requests.")
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

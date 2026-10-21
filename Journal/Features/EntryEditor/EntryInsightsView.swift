import SwiftUI

/// The entry's mood, categories and summary, kept live from the database so it
/// updates when the analysis finishes. Tap to set them by hand.
struct EntryInsightsView: View {
    let store: EntryStore
    let entryID: UUID

    @Environment(ModelStore.self) private var modelStore
    @State private var entry: Entry?
    @State private var editing = false

    var body: some View {
        Group {
            if let entry { content(entry) }
        }
        .task(id: entryID) {
            do {
                for try await entry in store.observeEntry(id: entryID) { self.entry = entry }
            } catch {}
        }
    }

    private func content(_ entry: Entry) -> some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MoodDot(score: entry.moodScore, size: 12)
                    Text(headline(entry))
                        .font(.subheadline)
                        .foregroundStyle(entry.moodScore == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.moodManual || entry.categoriesManual {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Set by hand")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let summary = entry.summary, !entry.needsAnalysis {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Change the mood or categories")
        .sheet(isPresented: $editing) {
            InsightsEditor(store: store, entry: entry)
        }
    }

    private func headline(_ entry: Entry) -> String {
        var parts: [String] = []
        if let label = entry.moodLabel, !label.isEmpty, entry.moodScore != nil {
            parts.append(label.capitalized)
        } else if let score = entry.moodScore {
            parts.append("Mood \(MoodScale.describe(score))")
        }
        parts += entry.categories
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if modelStore.status != .ready { return "Mood and categories need the AI model (Settings)" }
        return "Mood and categories are worked out when you leave the entry"
    }
}

/// Set mood and categories by hand. Manual values always win over the model's.
private struct InsightsEditor: View {
    let store: EntryStore
    let entry: Entry

    @Environment(\.dismiss) private var dismiss
    @State private var categories: [String] = []
    @State private var mood: Double
    @State private var label: String
    @State private var primary: String?
    @State private var secondary: Set<String>
    @State private var errorMessage: String?

    init(store: EntryStore, entry: Entry) {
        self.store = store
        self.entry = entry
        _mood = State(initialValue: entry.moodScore ?? 0)
        _label = State(initialValue: entry.moodLabel ?? "")
        _primary = State(initialValue: entry.primaryCategory)
        _secondary = State(initialValue: Set(entry.secondaryCategories))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        MoodDot(score: mood, size: 22)
                        Slider(value: $mood, in: -1...1, step: 0.1) {
                            Text("Mood")
                        } minimumValueLabel: {
                            Image(systemName: "cloud.rain").accessibilityLabel("Negative")
                        } maximumValueLabel: {
                            Image(systemName: "sun.max").accessibilityLabel("Positive")
                        }
                    }
                    Text(MoodScale.describe(mood).capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("One word, e.g. calm", text: $label)
                        .textInputAutocapitalization(.never)
                    if entry.moodManual {
                        Button("Let the model set the mood") { resetToAutomatic(mood: true) }
                    }
                } header: {
                    Text("Mood")
                } footer: {
                    if !entry.emotions.isEmpty {
                        Text("Emotions: \(entry.emotions.joined(separator: ", "))")
                    }
                }

                Section {
                    Picker("Main category", selection: $primary) {
                        Text("None").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    ForEach(categories.filter { $0 != primary }, id: \.self) { name in
                        Button {
                            if secondary.contains(name) { secondary.remove(name) } else if secondary.count < 2 { secondary.insert(name) }
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if secondary.contains(name) { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(!secondary.contains(name) && secondary.count >= 2)
                    }
                    if entry.categoriesManual {
                        Button("Let the model choose categories") { resetToAutomatic(mood: false) }
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("One main category and up to two more.")
                }

                if !entry.themes.isEmpty || entry.summary != nil {
                    Section("From the model") {
                        if let summary = entry.summary { Text(summary).font(.callout) }
                        if !entry.themes.isEmpty {
                            Text("Themes: \(entry.themes.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Mood and categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .task {
                categories = (try? await store.activeCategoryNames()) ?? []
                // Keep categories the entry already has, even if no longer on the list.
                for name in entry.categories where !categories.contains(name) { categories.append(name) }
            }
        }
    }

    /// Compared with what the sheet opened with, so saving untouched values doesn't
    /// turn the model's mood into a manual one.
    private var moodChanged: Bool {
        abs((entry.moodScore ?? 0) - mood) > 0.001 || (entry.moodLabel ?? "") != label
    }

    private var categoriesChanged: Bool {
        entry.primaryCategory != primary || Set(entry.secondaryCategories) != secondary
    }

    private func save() {
        Task {
            do {
                if moodChanged {
                    try await store.setManualMood(mood, label: label, for: entry.id)
                }
                if categoriesChanged {
                    let ordered = categories.filter { secondary.contains($0) }
                    try await store.setManualCategories(primary: primary, secondary: ordered, for: entry.id)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetToAutomatic(mood: Bool) {
        Task {
            do {
                try await store.resetToAutomatic(mood: mood, categories: !mood, for: entry.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

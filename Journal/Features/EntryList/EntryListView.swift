import SwiftUI

struct EntryListView: View {
    let store: EntryStore

    @State private var entries: [Entry] = []
    @State private var path: [EditorRoute] = []
    @State private var showingSettings = false
    @State private var entryToDelete: Entry?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(days, id: \.day) { group in
                    Section(group.day.date().formatted(.dateTime.weekday(.wide).day().month(.wide).year())) {
                        ForEach(group.entries) { entry in
                            NavigationLink(value: EditorRoute(entry: entry, isNew: false)) {
                                EntryRow(entry: entry)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    entryToDelete = entry
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No entries yet",
                        systemImage: "square.and.pencil",
                        description: Text("Tap + to write your first entry.")
                    )
                }
            }
            .navigationTitle("Journal")
            .navigationDestination(for: EditorRoute.self) { route in
                EntryEditorView(store: store, entry: route.entry, isNew: route.isNew)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New entry", systemImage: "plus") {
                        path.append(EditorRoute(entry: .newTyped(), isNew: true))
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(store: store, entryCount: entries.count)
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } }),
                titleVisibility: .visible,
                presenting: entryToDelete
            ) { entry in
                Button("Delete", role: .destructive) { delete(entry) }
            } message: { _ in
                Text("This can't be undone.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            do {
                for try await entries in store.observeEntries() {
                    self.entries = entries
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Entries grouped by day, keeping the store's newest-first order.
    private var days: [(day: DayDate, entries: [Entry])] {
        var groups: [(day: DayDate, entries: [Entry])] = []
        for entry in entries {
            if groups.last?.day == entry.entryDate {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.entryDate, [entry]))
            }
        }
        return groups
    }

    private func delete(_ entry: Entry) {
        Task {
            do {
                try await store.delete(id: entry.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EditorRoute: Hashable {
    let entry: Entry
    let isNew: Bool
}

private struct EntryRow: View {
    let entry: Entry

    var body: some View {
        let lines = entry.displayText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = entry.trimmedTitle ?? lines.first ?? (entry.audioPath == nil ? "Untitled" : "Voice entry")
        let preview = (entry.trimmedTitle == nil ? lines.dropFirst() : lines[...]).joined(separator: " ")

        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.headline)
                .lineLimit(1)
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                if let seconds = entry.audioDurationS {
                    Label(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)), systemImage: "mic.fill")
                        .accessibilityLabel("Recording")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

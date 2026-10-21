import SwiftUI

struct EntryListView: View {
    let store: EntryStore

    @Environment(AnalysisQueue.self) private var analysisQueue
    @State private var entries: [Entry] = []
    @State private var categories: [String] = []
    @State private var categoryFilter: String?
    @State private var path: [EditorRoute] = []
    @State private var showingSettings = false
    @State private var entryToDelete: Entry?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let categoryFilter {
                    Section {
                        Button {
                            self.categoryFilter = nil
                        } label: {
                            Label("Showing \(categoryFilter) · \(filteredEntries.count) entries. Show all", systemImage: "xmark.circle.fill")
                                .font(.subheadline)
                        }
                    }
                }
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
                } else if filteredEntries.isEmpty, let categoryFilter {
                    ContentUnavailableView("No \(categoryFilter) entries", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if analysisQueue.isWorking {
                    AnalysisStatus(pending: analysisQueue.pending)
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
                    Menu {
                        Picker("Category", selection: $categoryFilter) {
                            Text("All entries").tag(String?.none)
                            ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        Label("Filter by category", systemImage: categoryFilter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
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
        .task {
            do {
                for try await categories in store.observeCategories() {
                    self.categories = categories.filter { $0.status == .active }.map(\.name)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var filteredEntries: [Entry] {
        guard let categoryFilter else { return entries }
        return entries.filter { $0.categories.contains(categoryFilter) }
    }

    /// Entries grouped by day, keeping the store's newest-first order.
    private var days: [(day: DayDate, entries: [Entry])] {
        var groups: [(day: DayDate, entries: [Entry])] = []
        for entry in filteredEntries {
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

struct EditorRoute: Hashable {
    let entry: Entry
    let isNew: Bool
}

private struct AnalysisStatus: View {
    let pending: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(pending > 1 ? "Reading entries for mood and categories · \(pending) to go" : "Reading an entry for mood and categories")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar, in: .capsule)
        .padding(.bottom, 4)
    }
}

struct EntryRow: View {
    let entry: Entry

    var body: some View {
        let lines = entry.displayText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = entry.trimmedTitle ?? lines.first ?? (entry.audioPath == nil ? "Untitled" : "Voice entry")
        let preview = (entry.trimmedTitle == nil ? lines.dropFirst() : lines[...]).joined(separator: " ")

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MoodDot(score: entry.moodScore)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
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
                    if let category = entry.primaryCategory {
                        Text(category)
                    }
                    if let label = entry.moodLabel {
                        Text(label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.moodScore.map { "Mood \(MoodScale.describe($0))" } ?? "")
    }
}

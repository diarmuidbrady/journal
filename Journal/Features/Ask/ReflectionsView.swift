import SwiftUI

/// Saved answers, newest first.
struct ReflectionsView: View {
    let store: EntryStore

    @State private var reflections: [Reflection] = []

    var body: some View {
        List {
            ForEach(reflections) { reflection in
                NavigationLink {
                    ReflectionDetailView(store: store, reflection: reflection)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reflection.question).font(.headline).lineLimit(2)
                        Text("\(reflection.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(reflection.scopeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { reflections[$0].id }
                Task { for id in ids { try? await store.deleteReflection(id: id) } }
            }
        }
        .overlay {
            if reflections.isEmpty {
                ContentUnavailableView(
                    "No saved reflections",
                    systemImage: "bookmark",
                    description: Text("Save an answer from Ask to keep it here.")
                )
            }
        }
        .navigationTitle("Reflections")
        .task {
            do {
                for try await reflections in store.observeReflections() { self.reflections = reflections }
            } catch {}
        }
    }
}

extension Reflection {
    var scopeDescription: String {
        var label: String
        switch scope {
        case "entry":
            label = "One entry"
        case "range":
            if let start = rangeStart, let end = rangeEnd {
                label = "\(start.date().formatted(.dateTime.day().month())) – \(end.date().formatted(.dateTime.day().month().year()))"
            } else {
                label = "Date range"
            }
        default:
            label = "All entries"
        }
        if let category { label += " · \(category)" }
        return label
    }
}

private struct ReflectionDetailView: View {
    let store: EntryStore
    let reflection: Reflection

    @Environment(\.dismiss) private var dismiss
    @State private var cited: [Entry] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reflection.question).font(.headline)
                    Text("\(reflection.createdAt.formatted(date: .long, time: .shortened)) · \(reflection.scopeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Citations.linked(reflection.answer, validDates: Set(cited.map(\.entryDate))))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            if !cited.isEmpty {
                Section("Entries it drew on") {
                    ForEach(cited) { entry in
                        NavigationLink(value: EditorRoute(entry: entry, isNew: false)) {
                            EntryRow(entry: entry)
                        }
                    }
                }
            }
            Section {
                Button("Delete reflection", systemImage: "trash", role: .destructive) {
                    Task {
                        try? await store.deleteReflection(id: reflection.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Reflection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            cited = (try? await store.entries(ids: reflection.citedEntryIds)) ?? []
        }
    }
}

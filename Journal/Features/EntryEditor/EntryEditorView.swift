import SwiftUI

struct EntryEditorView: View {
    @State private var model: EntryEditorModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var bodyFocused: Bool

    init(store: EntryStore, entry: Entry, isNew: Bool) {
        _model = State(initialValue: EntryEditorModel(store: store, entry: entry, isPersisted: !isNew))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title (optional)", text: $model.title, axis: .vertical)
                .font(.title2.bold())
                .lineLimit(1...3)

            DatePicker("Date", selection: $model.date, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()

            TextEditor(text: $model.text)
                .focused($bodyFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Write…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Text(timestamps)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .status) {
                saveStatus
            }
        }
        .onAppear {
            if model.isNew { bodyFocused = true }
        }
        .onDisappear {
            Task { await model.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flush() } }
        }
    }

    private var timestamps: String {
        guard model.isPersisted else { return "New entry" }
        let created = model.entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        let updated = model.entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return created == updated ? "Created \(created)" : "Created \(created) · Edited \(updated)"
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch model.saveState {
        case .saved:
            if model.isPersisted {
                Label("Saved", systemImage: "checkmark.circle").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
            }
        case .pending:
            Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label("Not saved: \(message)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }
}

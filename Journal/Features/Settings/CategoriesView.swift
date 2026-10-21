import SwiftUI

/// Edit the category list and approve the model's suggestions (SPEC.md, Categories).
struct CategoriesView: View {
    let store: EntryStore

    @State private var categories: [Category] = []
    @State private var newName = ""
    @State private var renaming: Category?
    @State private var renameText = ""
    @State private var errorMessage: String?
    @State private var offeringRecategorise = false

    private var active: [Category] { categories.filter { $0.status == .active } }
    private var pending: [Category] { categories.filter { $0.status == .pending } }

    var body: some View {
        List {
            Section {
                ForEach(active, id: \.name) { category in
                    Button(category.name) {
                        renameText = category.name
                        renaming = category
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let names = offsets.map { active[$0].name }
                    perform { for name in names { try await store.deleteCategory(name) } }
                }
                .onMove { source, destination in
                    var names = active.map(\.name)
                    names.move(fromOffsets: source, toOffset: destination)
                    run { try await store.moveCategories(to: names) }
                }
            } header: {
                Text("Your categories")
            } footer: {
                Text("The model picks one main category and up to two more from this list. Tap a name to rename it; swipe to delete. Deleting removes it from entries too.")
            }

            Section("Add a category") {
                HStack {
                    TextField("Name", text: $newName)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending, id: \.name) { category in
                        HStack {
                            Text(category.name)
                            Spacer()
                            Button("Dismiss") { run { try await store.dismissSuggestion(category.name) } }
                                .buttonStyle(.bordered)
                            Button("Add") { perform { try await store.approveSuggestion(category.name) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text("Suggested by the model")
                } footer: {
                    Text("Suggestions are only used once you add them. Dismissed ones aren't suggested again.")
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Categories")
        .toolbar { EditButton() }
        .alert("Rename category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let old = renaming?.name {
                    let new = renameText
                    perform { try await store.renameCategory(old, to: new) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Entries in this category are renamed too.")
        }
        .alert("Re-categorise past entries?", isPresented: $offeringRecategorise) {
            Button("Re-categorise") { run { try await store.recategoriseAll() } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("The model reads your entries again in the background to choose from the updated list. Categories you set by hand are kept.")
        }
        .task {
            do {
                for try await categories in store.observeCategories() { self.categories = categories }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add() {
        let name = newName
        perform {
            try await store.addCategory(name)
            newName = ""
        }
    }

    /// Runs a change to the list, then offers to re-categorise.
    private func perform(_ change: @escaping () async throws -> Void) {
        run {
            try await change()
            offeringRecategorise = true
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

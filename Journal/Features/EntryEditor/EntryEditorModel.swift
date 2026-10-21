import Foundation

/// Edits one entry and saves it automatically: at most every `saveInterval` while
/// typing, and immediately on `flush()` (leaving the screen or going to background).
@MainActor
@Observable
final class EntryEditorModel {
    enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    var title: String {
        didSet { if title != oldValue { scheduleSave() } }
    }
    var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }
    var date: Date {
        didSet { if date != oldValue { dateWasEdited = true; scheduleSave() } }
    }

    private(set) var entry: Entry
    private(set) var saveState: SaveState = .saved
    private(set) var isPersisted: Bool

    private let store: EntryStore
    private let saveInterval: Duration
    private var pendingSave: Task<Void, Never>?
    private var dateWasEdited = false

    init(store: EntryStore, entry: Entry, isPersisted: Bool, saveInterval: Duration = .seconds(2)) {
        self.store = store
        self.entry = entry
        self.isPersisted = isPersisted
        self.saveInterval = saveInterval
        self.title = entry.title ?? ""
        self.text = entry.originalText
        self.date = entry.entryDate.date()
    }

    var isNew: Bool { !isPersisted }

    private func scheduleSave() {
        saveState = .pending
        // Throttle rather than debounce, so continuous typing still saves every few seconds.
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, saveInterval] in
            try? await Task.sleep(for: saveInterval)
            guard !Task.isCancelled, let self else { return }
            // Clear the handle first so flush() doesn't cancel this task mid-write.
            self.pendingSave = nil
            await self.flush()
        }
    }

    /// Saves any unsaved changes now.
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil

        var updated = entry
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        updated.originalText = text
        updated.entryDate = DayDate(date)
        if dateWasEdited { updated.dateSource = .manual }
        updated.contentHash = Entry.contentHash(text: text, date: updated.entryDate)

        guard updated != entry || !isPersisted else {
            saveState = .saved
            return
        }
        // Don't create a row for a new entry that is still blank.
        guard isPersisted || !updated.isEmpty else {
            saveState = .saved
            return
        }

        updated.updatedAt = .now
        do {
            try await store.save(updated)
            entry = updated
            isPersisted = true
            if pendingSave == nil { saveState = .saved }
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}

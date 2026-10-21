import SwiftUI

/// "Ask the journal": questions about one entry, a date range or all entries, answered
/// on the phone with dated, tappable citations (SPEC.md, Ask the journal). Each
/// question is answered on its own; earlier answers in the session aren't fed back in.
struct AskView: View {
    let store: EntryStore
    /// Set when asking about one entry from the editor; hides the scope controls.
    var entryID: UUID? = nil

    @Environment(ModelStore.self) private var modelStore
    @Environment(\.embeddingStore) private var embeddingStore
    @Environment(AnalysisQueue.self) private var analysisQueue
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var range: RangeChoice = .all
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @State private var customEnd = Date.now
    @State private var category: String?
    @State private var categories: [String] = []
    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var running: Task<Void, Never>?
    @FocusState private var questionFocused: Bool

    enum RangeChoice: String, CaseIterable, Identifiable {
        case all = "All entries"
        case week = "Last 7 days"
        case month = "This month"
        case custom = "Custom range"
        var id: Self { self }
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let scopeLabel: String
        let scope: AskScope
        let category: String?
        var stage: AskStage? = .finding
        var answer: AskAnswer?
        var error: String?
        var saved = false
    }

    private static let examples = [
        "What are the key insights from this week?",
        "What are my current blind spots?",
        "What keeps coming up about work?",
        "How has my mood changed this month?",
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty { introduction }
                        ForEach(turns) { turn in
                            TurnView(turn: turn, linksEnabled: entryID == nil) { save(turn) }
                                .id(turn.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) {
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle(entryID == nil ? "Ask" : "Ask about this entry")
            .navigationBarTitleDisplayMode(entryID == nil ? .large : .inline)
            .toolbar {
                if entryID == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ReflectionsView(store: store)
                        } label: {
                            Label("Saved reflections", systemImage: "bookmark")
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: DayDate.self) { day in
                DayEntriesView(store: store, day: day)
            }
            .navigationDestination(for: EditorRoute.self) { route in
                EntryEditorView(store: store, entry: route.entry, isNew: route.isNew)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "journal", url.host() == "day", let day = DayDate(string: url.lastPathComponent) {
                path.append(day)
                return .handled
            }
            return .systemAction
        })
        .task {
            do {
                for try await all in store.observeCategories() {
                    categories = all.filter { $0.status == .active }.map(\.name)
                }
            } catch {}
        }
        .onDisappear { running?.cancel() }
    }

    // MARK: Pieces

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entryID == nil
                 ? "Ask about your journal. Answers are written on this iPhone from your entries, with dates you can tap."
                 : "Ask about this entry. The answer is written on this iPhone.")
                .foregroundStyle(.secondary)
            if entryID == nil {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        question = example
                        if example.contains("this week") { range = .week }
                        if example.contains("this month") { range = .month }
                        questionFocused = true
                    } label: {
                        Text(example)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.fill.tertiary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entryID == nil {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Entries", selection: $range) {
                            ForEach(RangeChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(range.rawValue, systemImage: "calendar")
                    }
                    Menu {
                        Picker("Category", selection: $category) {
                            Text("All categories").tag(String?.none)
                            ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        Label(category ?? "All categories", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                .font(.subheadline)
                if range == .custom {
                    HStack {
                        DatePicker("From", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, in: ...Date.now, displayedComponents: .date)
                    }
                    .labelsHidden()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask your journal…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($questionFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                    .onSubmit(ask)
                if running != nil {
                    Button("Stop", systemImage: "stop.circle.fill") { running?.cancel() }
                        .labelStyle(.iconOnly)
                        .font(.title)
                } else {
                    Button("Ask", systemImage: "arrow.up.circle.fill", action: ask)
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocker != nil)
                }
            }
            if let blocker {
                Text(blocker).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.bar)
    }

    /// Why a question can't be asked right now, if it can't.
    private var blocker: String? {
        if modelStore.status != .ready { return "Download the AI model in Settings → AI models to ask questions." }
        if currentScope == .all, embeddingStore?.status != .ready {
            return "Searching all entries needs the search model. Download it in Settings → AI models, or pick a date range."
        }
        return nil
    }

    private var currentScope: AskScope {
        if let entryID { return .entry(entryID) }
        let today = DayDate.today
        let calendar = Calendar.current
        switch range {
        case .all:
            return .all
        case .week:
            return .range(DayDate(calendar.date(byAdding: .day, value: -6, to: .now)!), today)
        case .month:
            return .range(DayDate(year: today.year, month: today.month, day: 1), today)
        case .custom:
            let (start, end) = (DayDate(customStart), DayDate(customEnd))
            return .range(min(start, end), max(start, end))
        }
    }

    private var scopeLabel: String {
        guard entryID == nil else { return "This entry" }
        var label = range.rawValue
        if case .range(let start, let end) = currentScope, range == .custom {
            label = "\(start.date().formatted(.dateTime.day().month())) – \(end.date().formatted(.dateTime.day().month().year()))"
        }
        if let category { label += " · \(category)" }
        return label
    }

    // MARK: Actions

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, blocker == nil, running == nil, let model = modelStore.textModel else { return }
        question = ""
        questionFocused = false
        let turn = Turn(question: text, scopeLabel: scopeLabel, scope: currentScope, category: category)
        turns.append(turn)

        let engine = AskEngine(model: model, embedder: embeddingStore?.embeddingModel, store: store)
        // Hold the background pass so the model is free for the answer.
        analysisQueue.pause()
        running = Task {
            defer {
                analysisQueue.resume()
                running = nil
            }
            do {
                let answer = try await engine.answer(text, scope: turn.scope, category: turn.category) { stage in
                    Task { @MainActor in
                        update(turn.id) { if $0.answer == nil, $0.error == nil { $0.stage = stage } }
                    }
                }
                update(turn.id) {
                    $0.answer = answer
                    $0.stage = nil
                }
            } catch {
                update(turn.id) {
                    $0.stage = nil
                    $0.error = error is CancellationError ? "Stopped." : error.localizedDescription
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    private func save(_ turn: Turn) {
        guard let answer = turn.answer else { return }
        var start: DayDate?
        var end: DayDate?
        if case .range(let first, let last) = turn.scope { (start, end) = (first, last) }
        let reflection = Reflection(
            id: UUID(), createdAt: .now, question: answer.question, answer: answer.text,
            scope: turn.scope.kind, rangeStart: start, rangeEnd: end, category: turn.category,
            citedEntryIds: answer.citedEntryIDs, aiVersion: answer.aiVersion
        )
        Task {
            do {
                try await store.saveReflection(reflection)
                update(turn.id) { $0.saved = true }
            } catch {
                update(turn.id) { $0.error = error.localizedDescription }
            }
        }
    }
}

/// One question and its answer, or its progress while it's being answered.
private struct TurnView: View {
    let turn: AskView.Turn
    let linksEnabled: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.headline)
            Text(turn.scopeLabel).font(.caption).foregroundStyle(.secondary)

            if let answer = turn.answer {
                Text(Citations.linked(answer.text, validDates: linksEnabled ? Set(answer.sources.map(\.date)) : []))
                    .textSelection(.enabled)
                HStack {
                    Text("From \(answer.sources.count) \(answer.sources.count == 1 ? "entry" : "entries")")
                    Spacer()
                    Button(turn.saved ? "Saved" : "Save as reflection", systemImage: turn.saved ? "bookmark.fill" : "bookmark", action: onSave)
                        .disabled(turn.saved)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let stage = turn.stage {
                stageView(stage)
            }

            if let error = turn.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func stageView(_ stage: AskStage) -> some View {
        switch stage {
        case .finding:
            Label { Text("Finding entries…") } icon: { ProgressView() }
                .foregroundStyle(.secondary)
        case .summarising(let batch, let count):
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("Reading entries · part \(batch + 1) of \(count)") } icon: { ProgressView() }
                ProgressView(value: Double(batch), total: Double(count))
            }
            .foregroundStyle(.secondary)
        case .answering(let partial):
            if partial.isEmpty {
                Label { Text("Thinking it through on this iPhone…") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            } else {
                Text(partial)
            }
        }
    }
}

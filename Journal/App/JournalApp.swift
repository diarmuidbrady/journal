import SwiftUI

@main
struct JournalApp: App {
    @State private var vault = Vault()
    @State private var speechModel = SpeechModel()
    @State private var modelStore = ModelStore()
    @State private var analysisQueue = AnalysisQueue()
    @State private var embeddingStore = ModelStore(spec: .currentEmbedding)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if DebugBenchmark.isRequested { DebugBenchmark.run() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vault)
                .environment(speechModel)
                .environment(modelStore)
                .environment(analysisQueue)
                .environment(\.embeddingStore, embeddingStore)
                .task {
                    await modelStore.refresh()
                    await embeddingStore.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            vault.scenePhaseChanged(phase)
            // A loaded model holds gigabytes; free it so iOS doesn't end the app in the background.
            if phase == .background {
                Task {
                    await modelStore.unloadFromMemory()
                    await embeddingStore.unloadFromMemory()
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(Vault.self) private var vault
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch vault.state {
            case .locked where isBenchmarking:
                ProgressView("Benchmarking the AI model…")
            case .locked:
                LockView()
            case .unlocked(let store):
                MainTabs(store: store)
            }

            // Hides journal content in the app switcher and while Face ID is showing.
            if scenePhase != .active {
                PrivacyCover()
            }
        }
    }

    private var isBenchmarking: Bool {
        #if DEBUG
        DebugBenchmark.isRequested
        #else
        false
        #endif
    }
}

/// Journal, Mood and Ask tabs, plus the background analysis pass while unlocked.
struct MainTabs: View {
    let store: EntryStore

    @Environment(ModelStore.self) private var modelStore
    @Environment(AnalysisQueue.self) private var analysisQueue
    @Environment(\.embeddingStore) private var embeddingStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = MainTabs.initialTab

    /// The pass runs only when all of these hold; any change restarts or stops it.
    private struct AnalysisConditions: Hashable {
        var active: Bool
        var modelReady: Bool
        var searchModelReady: Bool
        var unpaused: Bool
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Journal", systemImage: "book", value: "journal") {
                EntryListView(store: store)
            }
            Tab("Mood", systemImage: "calendar", value: "mood") {
                MoodCalendarView(store: store)
            }
            Tab("Ask", systemImage: "sparkles", value: "ask") {
                AskView(store: store)
            }
        }
        .task(id: AnalysisConditions(
            active: scenePhase == .active,
            modelReady: modelStore.status == .ready,
            searchModelReady: embeddingStore?.status == .ready,
            unpaused: !analysisQueue.isPaused
        )) {
            guard scenePhase == .active, !analysisQueue.isPaused, let model = modelStore.textModel else { return }
            await analysisQueue.run(store: store, model: model, embedder: embeddingStore?.embeddingModel)
        }
    }

    private static var initialTab: String {
        #if DEBUG
        DebugSampleData.initialTab ?? "journal"
        #else
        "journal"
        #endif
    }
}

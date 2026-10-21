import SwiftUI

@main
struct JournalApp: App {
    @State private var vault = Vault()
    @State private var speechModel = SpeechModel()
    @State private var modelStore = ModelStore()
    @State private var analysisQueue = AnalysisQueue()
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
                .task { await modelStore.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            vault.scenePhaseChanged(phase)
            // A loaded model holds gigabytes; free it so iOS doesn't end the app in the background.
            if phase == .background { Task { await modelStore.unloadFromMemory() } }
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

/// Journal and Mood tabs, plus the background analysis pass while unlocked.
struct MainTabs: View {
    let store: EntryStore

    @Environment(ModelStore.self) private var modelStore
    @Environment(AnalysisQueue.self) private var analysisQueue
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = MainTabs.initialTab

    /// The pass runs only when all of these hold; any change restarts or stops it.
    private struct AnalysisConditions: Hashable {
        var active: Bool
        var modelReady: Bool
        var editorClosed: Bool
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Journal", systemImage: "book", value: "journal") {
                EntryListView(store: store)
            }
            Tab("Mood", systemImage: "calendar", value: "mood") {
                MoodCalendarView(store: store)
            }
        }
        .task(id: AnalysisConditions(
            active: scenePhase == .active,
            modelReady: modelStore.status == .ready,
            editorClosed: analysisQueue.openEditors == 0
        )) {
            guard scenePhase == .active, analysisQueue.openEditors == 0, let model = modelStore.textModel else { return }
            await analysisQueue.run(store: store, model: model)
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

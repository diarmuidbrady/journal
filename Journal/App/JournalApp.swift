import SwiftUI

@main
struct JournalApp: App {
    @State private var vault = Vault()
    @State private var speechModel = SpeechModel()
    @State private var modelStore = ModelStore()
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
                EntryListView(store: store)
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

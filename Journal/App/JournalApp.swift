import SwiftUI

@main
struct JournalApp: App {
    @State private var vault = Vault()
    @State private var speechModel = SpeechModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vault)
                .environment(speechModel)
        }
        .onChange(of: scenePhase) { _, phase in
            vault.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @Environment(Vault.self) private var vault
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch vault.state {
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
}

import SwiftUI

/// Opaque cover shown whenever the app isn't active, so the app switcher snapshot
/// shows nothing from the journal.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

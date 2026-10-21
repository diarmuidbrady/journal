import SwiftUI

struct LockView: View {
    @Environment(Vault.self) private var vault
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "book.closed.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Journal")
                .font(.largeTitle.bold())
            Text("Locked")
                .foregroundStyle(.secondary)
            Spacer()
            if let message = vault.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button {
                Task { await vault.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vault.isUnlocking)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Prompt once per launch or automatic lock, not again after a cancel.
            guard phase == .active, vault.consumeLockScreenPrompt() else { return }
            Task { await vault.unlock() }
        }
    }
}

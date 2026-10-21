import Foundation
import SwiftUI

/// Owns the locked/unlocked state. The database is only open while unlocked, and the
/// key to open it can only be read from the Keychain after Face ID or the passcode.
@MainActor
@Observable
final class Vault {
    enum State {
        case locked
        case unlocked(EntryStore)
    }

    /// Lock after this long in the background (SPEC.md: 1 minute).
    static let lockTimeout: TimeInterval = 60

    private(set) var state: State = .locked
    private(set) var isUnlocking = false
    private(set) var errorMessage: String?
    /// True after launch or an automatic lock, so the lock screen asks for Face ID
    /// straight away. "Lock now" leaves it false.
    private(set) var shouldPromptOnLockScreen = true

    private let keyStore: KeyStore
    private let paths: VaultPaths
    private var backgroundedAt: Date?

    init(keyStore: KeyStore = KeyStore(), paths: VaultPaths = .standard) {
        self.keyStore = keyStore
        self.paths = paths
    }

    var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }

        do {
            try paths.prepare()
            var key = try await keyStore.unlockDatabaseKey(
                reason: "Unlock your journal",
                createIfMissing: !paths.databaseExists
            )
            defer { key.resetBytes(in: 0..<key.count) }
            paths.clearExports()
            let store = EntryStore(database: try AppDatabase.open(at: paths.databaseURL, key: key), paths: paths)
            #if DEBUG
            try await DebugSampleData.seedIfRequested(into: store)
            #endif
            state = .unlocked(store)
            errorMessage = nil
        } catch KeyStoreError.cancelled {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops the store, which closes the database once the last view releases it.
    func lock(promptOnLockScreen: Bool = false) {
        shouldPromptOnLockScreen = promptOnLockScreen
        state = .locked
    }

    /// Returns whether the lock screen should prompt now, and clears the flag.
    func consumeLockScreenPrompt() -> Bool {
        defer { shouldPromptOnLockScreen = false }
        return shouldPromptOnLockScreen
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = .now }
        case .active:
            if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) >= Self.lockTimeout {
                lock(promptOnLockScreen: true)
            }
            backgroundedAt = nil
        default:
            break
        }
    }
}

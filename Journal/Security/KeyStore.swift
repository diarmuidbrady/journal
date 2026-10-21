import Foundation
import LocalAuthentication
import Security

enum KeyStoreError: LocalizedError {
    case cancelled
    case passcodeNotSet
    case keyMissing
    case authenticationFailed(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Unlock was cancelled."
        case .passcodeNotSet:
            "Set a passcode on this iPhone (Settings → Face ID & Passcode) to use the journal."
        case .keyMissing:
            "The journal's key is missing from the Keychain, so the existing journal can't be opened."
        case .authenticationFailed(let message):
            message
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")."
        }
    }
}

/// Holds the 256-bit database key in the Keychain.
///
/// The item is `WhenUnlockedThisDeviceOnly`, so it never leaves this phone (not in
/// iCloud Keychain or device backups), and it requires user presence (Face ID or the
/// device passcode) to read. `.userPresence` survives Face ID re-enrolment, unlike
/// `.biometryCurrentSet`, which would lock the owner out of their own journal.
struct KeyStore: Sendable {
    var service = "com.diarmuidbrady.journal.database-key"
    var account = "database"

    func unlockDatabaseKey(reason: String, createIfMissing: Bool) async throws -> Data {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw KeyStoreError.cancelled
            case .passcodeNotSet:
                throw KeyStoreError.passcodeNotSet
            default:
                throw KeyStoreError.authenticationFailed(error.localizedDescription)
            }
        }
        // The evaluated context is passed to the Keychain so it doesn't prompt again.
        return try readOrCreateKey(context: context, createIfMissing: createIfMissing)
    }

    private func readOrCreateKey(context: LAContext, createIfMissing: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let key = result as? Data, key.count == 32 else { throw KeyStoreError.keyMissing }
            return key
        case errSecItemNotFound:
            guard createIfMissing else { throw KeyStoreError.keyMissing }
            return try createKey(context: context)
        case errSecUserCanceled:
            throw KeyStoreError.cancelled
        default:
            throw KeyStoreError.keychain(status)
        }
    }

    private func createKey(context: LAContext) throws -> Data {
        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw KeyStoreError.keychain(randomStatus) }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
        ) else {
            throw KeyStoreError.authenticationFailed(error?.takeRetainedValue().localizedDescription ?? "Access control failed.")
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: access,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return key
    }
}

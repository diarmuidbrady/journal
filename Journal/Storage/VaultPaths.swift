import Foundation

/// Where the journal lives on disk. Everything is under one directory that is
/// excluded from iCloud device backups (SPEC.md, Device backups).
struct VaultPaths: Sendable {
    let directory: URL

    static let standard = VaultPaths(
        directory: URL.applicationSupportDirectory.appending(path: "Vault", directoryHint: .isDirectory)
    )

    var databaseURL: URL { directory.appending(path: "journal.sqlite") }

    var databaseExists: Bool { FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) }

    /// Finished recordings, one per entry, protected "complete".
    var audioDirectory: URL { directory.appending(path: "Audio", directoryHint: .isDirectory) }

    /// Recordings in progress, before they are added to an entry.
    var recordingsDirectory: URL { directory.appending(path: "Recordings", directoryHint: .isDirectory) }

    /// Temporary export files, emptied on every unlock.
    var exportDirectory: URL { directory.appending(path: "Export", directoryHint: .isDirectory) }

    /// The path stored in `entries.audio_path`, relative to `directory`.
    func audioRelativePath(for entryID: UUID) -> String {
        "Audio/\(entryID.uuidString.lowercased()).m4a"
    }

    func url(forRelativePath path: String) -> URL {
        directory.appending(path: path)
    }

    func newRecordingURL() -> URL {
        recordingsDirectory.appending(path: "\(UUID().uuidString.lowercased()).m4a")
    }

    /// Creates the directories if needed and marks the vault excluded from backup.
    func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // "Complete unless open" lets a recording keep writing if the phone locks
        // mid-file; finished recordings are then switched to "complete".
        for audioDirectory in [audioDirectory, recordingsDirectory] {
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: audioDirectory.path(percentEncoded: false)
            )
        }
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Deletes leftover export files so plaintext copies don't linger.
    func clearExports() {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? fileManager.removeItem(at: item) }
    }

    var isExcludedFromBackup: Bool {
        (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }
}

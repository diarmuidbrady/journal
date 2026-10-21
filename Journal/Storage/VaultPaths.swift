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

    /// Creates the directory if needed and marks it excluded from backup.
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    var isExcludedFromBackup: Bool {
        (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }
}

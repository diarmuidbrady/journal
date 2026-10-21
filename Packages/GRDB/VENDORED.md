# Vendored GRDB

- Upstream: https://github.com/groue/GRDB.swift, tag `v7.11.1` (commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`).
- Copied unchanged: `GRDB/`, `Sources/GRDBSQLCipher/`, `LICENSE`.
- Changed: `Package.swift`, following the upstream "GRDB+SQLCipher" instructions (GRDB's README, section Encryption). The `GRDBSQLite` target and the test target are removed, and SQLCipher.swift is pinned to an exact version.

GRDB only supports SQLCipher through Swift Package Manager by modifying its package, so it lives here instead of being a remote package. To upgrade, copy the same folders from a newer tag and re-apply the GRDB+SQLCipher comments in its `Package.swift`.

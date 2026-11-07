# Decision 002: GRDB records for cache storage

## Status

Accepted on 2026-11-03.

## Decision

The cache index uses [GRDB.swift](https://github.com/groue/GRDB.swift) instead of the SQLite C API.

- `Sources/PhotoCache/Storage/CacheSchema.swift` declares every table: one Codable record type per table, and the table definitions built from the same column keys. It is the single place to read or change the storage schema.
- Storage code reads and writes through records and GRDB's query interface (`filter`, `order`, `fetchOne`, `insert`, `upsert`, `updateAll`, `deleteAll`). Hand-written SQL is limited to pragmas, the `metadata_format` marker and table introspection used to discard a superseded format.
- Nested values (photo items, catalogs, cursors, album lists) are stored as JSON text by GRDB's Codable support.
- `DiskCache` owns one `DatabaseQueue` and keeps its storage methods synchronous, so a transaction never suspends inside the actor.
- Formats are still discarded, not migrated: `DiskCache.schemaVersion` covers media rows and files, `metadataFormatVersion` covers metadata rows. GRDB's migrator is not used.

## Rationale

The previous code bound statement parameters by index, finalized statements by hand and decoded JSON blobs manually. That made storage code long and made mistakes in binding or cleanup easy. Typed records keep column names in one declaration and turn queries into checked Swift calls.

GRDB was chosen over SQLite.swift (less maintained), SwiftData (too little control over transactions, bulk scans and the cache's own eviction) and Point-Free's StructuredQueries (stronger compile-time checks but another dependency built on GRDB, with macros and hand-written DDL). Unlike Prisma, GRDB does not generate the record types from a schema file; records and table definitions are kept next to each other in `CacheSchema.swift`, and tests catch a mismatch.

## Consequences

- GRDB is the project's first external package dependency.
- `DatabasePool` could later allow concurrent reads, but reads currently stay on the actor because admission fencing reads actor state.

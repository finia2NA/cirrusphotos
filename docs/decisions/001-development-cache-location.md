# Decision 001: repository-local development cache

## Status

Accepted for the current development prototype on 2026-10-02.

## Decision

Store the cache under the repository's Git-ignored `.cache/` directory:

```text
<repository>/.cache/<server-and-account hash>/
  index.sqlite
  index.sqlite-wal
  index.sqlite-shm
  images/
```

The cache locator finds the nearest ancestor containing `Package.swift`. It checks the process working directory first, then walks upward from the application bundle. This keeps `swift run` and `scripts/run.sh` on the same path even though LaunchServices does not guarantee the working directory of a launched `.app`.

The earlier `~/Library/Caches/CirrusTimeline` location is no longer migrated. Each checkout starts with its own cache. Incompatible SQLite index versions are discarded and recreated from NAS data.

`.cache/` is ignored by Git.

## Rationale

The user controls a potentially large cache budget and expects viewed thumbnails to remain present until the configured eviction policy or an explicit clear operation removes them. The macOS Caches directory is intentionally purgeable and does not provide that persistence expectation. There is no planned App Store release, so conforming this development prototype to an App Store container layout is not a current requirement.

The data remains a cache: it is derived from Cirrus and is not a backup or source of truth. Removing `.cache/` must only cause a cold start and redownload.

## Consequences

- Each checkout has its own cache. Moving or deleting the repository leaves or removes that cache with it.
- A large cache consumes space inside the checkout's volume.
- The repository must remain writable. This layout is unsuitable for an app installed read-only in `/Applications` or distributed independently of its source checkout.
- Settings remain in `UserDefaults`; only cached payloads and their index live under `.cache/`.

## Returning to `~/Library/Caches`

If cache persistence is later made best-effort again, change the location behind `CacheLocation` rather than spreading paths through the data layer. Before doing so, implement and test all of the following:

1. Treat a missing or corrupt SQLite database as a cache miss. Delete/rebuild that namespace without preventing the app from opening.
2. Reconcile both directions after launch: delete index rows whose image files are missing, and delete image files that have no index row.
3. Make Clear Cache remove and recreate the entire account namespace, including orphan files, SQLite WAL/SHM files, and temporary writes.
4. Do not assume macOS purges an app's cache atomically. Every mixture of missing database, WAL, and image files must recover safely.
5. Keep cached-first UI functional when available, but describe it as opportunistic rather than guaranteed offline storage.
6. Include SQLite/WAL allocation and temporary-file headroom in budget enforcement, and cap admissions when free disk space is low.

If users later request guaranteed offline content, keep that explicit, pinned content outside `~/Library/Caches`—most likely under Application Support—and give it a separate quota and removal control.

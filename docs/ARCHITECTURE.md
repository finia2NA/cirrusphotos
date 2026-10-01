# Timeline and one-section cache prototype

## Current implementation

`TimelineCore` contains the platform-independent navigator model. `SynologyAPI` owns credentials, TOTP login, the authenticated URL session, timeline/page requests, and thumbnail transport. `PhotoCache` owns semantic resource keys, cached-first request coordination, SQLite metadata storage, compressed image files, and eviction. `TimelinePrototype` is the SwiftUI macOS executable.

At startup the app reads `USER`, `PW`, and the TOTP secret `OTP` from the ignored `.env`. It opens one shared repository for the app process. A cached full timeline appears before login completes; the full index is then requested once and replaces the cached snapshot. On a cold cache, `get_init_timeline` provides an interim navigator, followed by full `get`. The completed timeline is not refreshed again during the run.

The snapshot preserves every section's date list, offset, and limit, while the navigator deduplicates calendar dates, retains the earliest section index for split days, and sorts newest first. It precomputes year/month boundaries once. Selection is restored by calendar date when a refreshed map arrives. Live changes during a run remain out of scope.

The second tab resolves section index 207 from the current full timeline. Its exact item page is cached and validated once per run. Thumbnail cells first show cached renditions, then validate/download after current page metadata arrives. Six transfers can run concurrently. ImageIO downsamples off the main actor; an `NSCache` limits retained decoded images. There is no endless timeline grid yet.

SQLite holds timeline/page JSON and cache bookkeeping. Compressed image bytes live in hashed files under an account-scoped directory inside the repository's ignored `.cache/` directory. `CacheLocation` finds the repository containing `Package.swift`, because Finder and LaunchServices do not provide a dependable process working directory. On first use it makes a best-effort move of this account's earlier `~/Library/Caches/CirrusTimeline` directory. The index records validation run, access time, ETag, and Last-Modified. Disk trimming removes thumbnails before pages and protects the current full timeline. The configured budget and size preference are in Settings. Budget usage currently counts indexed payload bytes; SQLite/WAL overhead and temporary writes are not included in the displayed figure.

The current certificate mismatch is accepted only for the configured Cirrus host. The prototype app's transport-security exception and the URL session trust override are both scoped to that hostname. The URL session uses ephemeral cookie storage, and credentials, OTP values, session IDs, and tokens are never logged. `.env` is a development credential source; a distributable app should move credentials to Keychain.

## Geometry and input

Each populated day owns the same fraction of the usable track. Empty days occupy no space. Item counts do not influence spacing.

For `N` dates, track origin `top`, track height `H`, and pointer `y`:

```text
fraction = clamp((y - top) / H, 0, 1)
dayIndex = min(N - 1, floor(fraction * N))
markerY = top + H * (dayIndex + 0.5) / N
```

This gives constant-time pointer lookup. A single `Canvas` paints the track, month marks, year labels, and selection indicator. One transparent rectangular view handles continuous hover and click/drag input. There are no per-day views or hit targets. Year labels are culled when less than 25 points apart, without changing the underlying date geometry.

More populated days than screen pixels necessarily means some days cannot be individually targeted with the pointer. Arrow keys and the accessibility adjustable action allow exact single-day stepping. Hover feedback includes both year/month and the exact selected calendar day.

## Selection contract

`TimelineNavigator` exposes a selected day index through a binding. The prototype reads the corresponding `LibraryDay` and displays the date/count/first section. A future parent can use that callback/binding to fetch the full section descriptor and scroll to the selected day. A section can contain several days, so merely fetching the section is not sufficient to align the eventual grid to the day.

The selected-date readout stands in for the future integrated photo grid. Location labels remain deferred.

## Cache direction

Typed finite `AsyncStream` results emit cached values first and current values after validation, then finish. Thumbnail GETs use `If-None-Match` or `If-Modified-Since` when cached validators exist, and accept 304 only with local bytes. The NAS remains authoritative; cached metadata is provisional until validated. See [cache plan](CACHING_PLAN.md) for evidence, current limitations, and future work.

The cache-location rationale and requirements for any future return to macOS's purgeable Caches directory are recorded in [decision 001](decisions/001-development-cache-location.md).

## Verification

`TimelineCoreTests` checks navigator geometry. `PhotoCacheTests` checks section round trips, key isolation, logarithmic budget mapping, and eviction. An opt-in live test loads section 207 and one thumbnail, then reopens the timeline cache. Manual UI checks should cover Settings, cached/offline startup, hover, drag/click selection, keyboard navigation, and resizing.

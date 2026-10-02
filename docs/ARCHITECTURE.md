# Personal Space browser

## Current implementation

`TimelineCore` contains the platform-independent navigator model. `SynologyAPI` owns credentials, TOTP login, the authenticated URL session, timeline/page requests, and thumbnail transport. `PhotoCache` owns semantic resource keys, cached-first request coordination, SQLite metadata storage, compressed image files, and eviction. `TimelinePrototype` is the SwiftUI macOS executable.

At startup the app reads `USER`, `PW`, and the TOTP secret `OTP` from the ignored `.env`. It opens one shared repository for the app process. A cached full timeline appears before login completes; the full index is then requested once. Identical descriptors update verification state without replacing the viewport. On a cold cache, `get_init_timeline` provides an interim navigator, followed by full `get`. The completed timeline is not refreshed again during the run.

The snapshot preserves every section's date list, offset, and limit, while the navigator deduplicates calendar dates, retains the earliest section index for split days, and sorts newest first. It precomputes year/month boundaries once. Selection is restored by calendar date when a refreshed map arrives. Live changes during a run remain out of scope.

`LibraryIndex` hashes the complete, ordered descriptor snapshot and maps each UTC day to exact slices of every contributing section response. Slices carry both page-local and day-local ranges, including section offset and limit. `LibraryViewportGeometry` keeps estimated or measured heights and binary-searchable offsets for those slices. Distant slices retain heights, not item arrays or row views. `LibraryPageWindow` accepts visible and adjacent prefetch sections, retains at most eight pages, emits cached pages promptly, and rejects obsolete responses. The viewport reconciles retained pages after events because buffered hints may be dropped.

Personal Library hosts an `NSScrollView` in SwiftUI beside the equal-day Canvas navigator. Its flipped document creates `NSHostingView` rows and date headings only in the visible region and a small overscan. It restores scroll position by visible item ID plus pixel offset when possible, otherwise by date and slice position; explicit navigator requests jump to the date's first slice. Scrolling updates the selected date without issuing another jump. Same-day rows flow across retained neighboring API slices; an incomplete-row carry bounded to the current page window keeps the loaded suffix stable when a look-behind page is evicted. A distant window edge remains provisional until its neighbor arrives. AppKit bounds notifications handle scrolling and resize, while thumbnail tasks end as row hosts leave the viewport. Image decoding is limited to two concurrent jobs separately from six thumbnail transfers. The trailing toolbar status observes replaying repository authentication status; failed sign-in remains memoized until explicit retry. Cached data remains usable while signing in or after failure.

Exact section item pages are cached and validated once per run. Items retain server order and are grouped by UTC day, matching section request bounds. A pure `TimelineCore` layout builds justified rows from metadata aspect ratios, applying optional EXIF orientation before image bytes arrive. Rows recalculate for available width and the toolbar display-size preference; the final row remains left aligned at or below the target height. The native viewport creates thumbnail cells for nearby rows. Each cell fits the rendition within its proportioned frame, shows cached bytes first, and validates/downloads after current page metadata arrives. A displayed rendition remains visible while it is validated. Six thumbnail transfers and two metadata requests can run concurrently. Pending queues are bounded, with visible demand before prefetch. Shared repository jobs cancel when their last subscriber leaves; cached reads do not wait for login or a network slot. ImageIO downsamples off the main actor; an `NSCache` limits retained decoded images.

SQLite holds timeline/page JSON and cache bookkeeping. Compressed image bytes live in hashed files under an account-scoped directory inside the repository's ignored `.cache/` directory. `CacheLocation` finds the repository containing `Package.swift`, because Finder and LaunchServices do not provide a dependable process working directory. On first use it makes a best-effort move of this account's earlier `~/Library/Caches/CirrusTimeline` directory. The index records validation run, access time, ETag, and Last-Modified. Disk trimming removes thumbnails before pages and protects the current full timeline. The configured budget and size preference are in Settings. Budget usage currently counts indexed payload bytes; SQLite/WAL overhead and temporary writes are not included in the displayed figure.

The current certificate mismatch is accepted only for the configured Cirrus host. The prototype app's transport-security exception and the URL session trust override are both scoped to that hostname. The URL session uses ephemeral cookie storage, and credentials, OTP values, session IDs, and tokens are never logged. `.env` is a development credential source; a distributable app should move credentials to Keychain.

The application shell uses a native navigation split view with one Personal Library destination and a retractable sidebar. The unified toolbar contains display-size controls and connection status. System appearance drives semantic colors in SwiftUI and the hosted AppKit viewport. The app requires macOS 27 and uses native Liquid Glass. Display size changes row geometry independently of the thumbnail rendition selected in Settings. A compact trailing navigator appears near the pointer, while dragging, or with keyboard focus; its reserved width stays fixed to avoid hover-driven grid reflow.

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

`TimelineNavigator` exposes a selected day index through a binding. In Personal Library, user input creates a jump request with a fresh identity, including a repeated selection of the same date. Browser scroll feedback updates the bound selection without creating a jump. Date selection survives a changed index by using the nearest remaining older day. A section can contain several days, so the browser resolves the exact day slice before scrolling.

Location labels remain deferred.

## Cache direction

`ThumbnailRangeDownloader` handles explicit range downloads from the Library menu. The nonmodal picker maps its two handles to oldest-to-newest populated dates and sums the selected distinct-day item counts. It uses a validated snapshot, resolves every contributing section (including split days), and filters each page to the selected day slices. One metadata page and two low-priority thumbnail workers are processed at a time; no whole-library photo array or decoded images are retained. It shares the repository's jobs and cache with browsing. Progress distinguishes fetched, reused, unavailable renditions and errors; successful processing does not pin entries or override the cache budget. Closing the download window cancels its work.

Typed finite `AsyncStream` results emit cached values first and current values after validation, then finish. Thumbnail GETs use `If-None-Match` or `If-Modified-Since` when cached validators exist, and accept 304 only with local bytes. The NAS remains authoritative; cached metadata is provisional until validated. See [cache plan](CACHING_PLAN.md) for evidence, current limitations, and future work.

The cache-location rationale and requirements for any future return to macOS's purgeable Caches directory are recorded in [decision 001](decisions/001-development-cache-location.md).

## Verification

`TimelineCoreTests` checks navigator and justified-row geometry. `SynologyAPITests` checks optional orientation decoding, display ratios, and UTC day boundaries. `PhotoCacheTests` checks section round trips, key isolation, eviction, split-day indexing, cached-first delivery during blocked login, coalescing and cancellation, equal-count page replacement, bounded window retention, and viewport geometry/anchoring over large synthetic libraries. An opt-in live test loads section 207 and one thumbnail, then reopens the timeline cache. Manual UI checks should cover Settings, cached/offline startup, scrolling across days, rapid distant jumps, and resizing.

# Cache design and implementation status

Status: persistent cached-first browser, bounded viewport, and full-size photo resources implemented on 2026-10-02; album/map resources remain planned. Research date: 2026-10-02.

## Implemented slice

- The Library menu can warm the selected thumbnail rendition for an inclusive range of populated dates. The picker reports an upper bound from distinct-day item counts; actual readiness is checked per page. Batch work uses one metadata page and two prefetch-priority thumbnail workers at a time and can be cancelled without interrupting another consumer's shared request. It uses the existing total budget and may evict earlier downloads; it does not guarantee pinned offline availability.

- `PhotoCache` stores the full Personal Space timeline and exact item pages as JSON in SQLite, with compressed thumbnail and original-photo files alongside the index. The development cache lives in the repository's Git-ignored `.cache/` directory, separated by a server/account hash. Keys include server/account namespace, request shape, unit ID, opaque thumbnail key, and size where applicable. Viewer-fetched `xl` previews share the ordinary `xl` key and file but have a lower-retention category until ordinary thumbnail demand promotes them in place. The app displays cached values before validation and retains current-run markers on disk.
- Personal Library combines the equal-day navigator with a virtualized Personal Space browser using an eight-page window, compact slice heights, visible-row hosting, and adjacent prefetch. Cached thumbnails can paint from provisional item metadata; requests wait until current page metadata arrives. Thumbnail GETs use ETag or Last-Modified validators, accept 304 with retained local bytes, reject JSON error bodies, and use bounded six-request transfers. ImageIO downsamples off the main actor with two concurrent decodes; `NSCache` holds decoded images.
- Repository authentication status is independent of resource loading and replayed to the UI. Cached data remains usable during login and after failure. Failed sign-in is memoized until explicit retry, while metadata errors retain a valid session.
- A standard macOS Settings scene exposes `sm`/`m`/`xl`, an opt-in “Load large previews in viewer” toggle, a logarithmic 200 MB–100 GB budget, indexed payload usage, and clear-cache. When enabled with `sm` or `m`, the viewer still loads the configured current and adjacent thumbnails as its immediate stage, while cached or on-demand `xl` upgrades and the current original load concurrently. The option is inactive for `xl`. Eviction prioritizes viewer previews, originals, ordinary thumbnails, and item pages in that order and protects the active complete timeline.
- `swift test` passes without NAS access. An opt-in test (`RUN_LIVE_SYNOLOGY_TEST=1 swift test --filter PhotoCacheTests/testLiveSectionAndWarmCacheWhenEnabled`) passed against Cirrus: full timeline, current section 207, one thumbnail, cached-first reopen, and later validation. DSM rejected immediate reuse of a TOTP between the two test sessions; login now retries once after the next code window only for login errors 403/404.

Current limitations: albums, maps, video playback, and coordinated session renewal after expiry are pending. Eviction uses SQLite indexed LRU over stored payload bytes; its displayed/budgeted size excludes SQLite/WAL overhead, filesystem allocation, and temporary writes. Shared page/thumbnail/original transfers cancel when their last subscriber leaves. The browser shows errors and cached fallback but has no dedicated retry action for each thumbnail. The repository-local cache is reproducible data rather than a backup. This file's later sections describe broader design and acceptance criteria, not all shipped behavior.

## Recommendation

Build an application-owned, cached-first repository between SwiftUI and `SynologyClient`. Consumers request typed resources; they receive a cached value promptly, then a validated/replacement value when the network completes. Validation is demand-driven, once per resource per app run. There is no periodic refresh or live library synchronization.

Use SQLite for the cache index and small metadata payloads, files for compressed images, and a separate bounded decoded-image memory cache. Keep observable state limited to the timeline and the current viewport. Do not construct a persistent observable object or subscription for every photo.

This is sufficient to proceed without an Android capture. Some protocol optimizations remain unverified; the baseline must work without them.

## Evidence and limitations

### Web capture

The ignored HAR was examined with `jq`, selecting endpoint names, metadata fields, and cache-related headers rather than dumping image bodies or authenticated URLs. See [API research](SYNOLOGY_PHOTOS_API.md) for pagination details.

| Observation | Consequence |
| --- | --- |
| Personal full timeline: 130,151 bytes, 494 sections, 2,192 distinct populated days, 58,712 items | Keep the complete date/section map in memory; fetch item pages and images on demand. |
| All 1,055 sampled item records contain `additional.thumbnail.cache_key` and `unit_id` | Thumbnail identity is supplied by the NAS, not only by frontend middleware. |
| 338 thumbnail GETs: 337 JPEG successes and one 503 | Cache only validated successful image responses, never an error body. |
| All 337 successful thumbnails have `ETag` and `Last-Modified`; none has `Cache-Control` or `Expires` | There are candidate HTTP validators, but the HAR alone does not demonstrate 304 behavior. |
| Timeline and item responses say `max-age=0, no-cache, no-store, must-revalidate`, with no observed ETag or Last-Modified | Automatic HTTP caching is not a metadata persistence solution. Store decoded application data under an explicit offline-data policy. |
| Every captured request has `Cache-Control: no-cache`; none uses thumbnail conditional headers | DevTools likely disabled caching. This recording cannot establish ordinary browser cache-hit or refresh behavior. |

The thumbnail key resembles `unitID_revision`. Treat the entire value as opaque: do not interpret the numeric suffix as a reliable modification timestamp or a TTL. A changed key must select a new cache entry. An unchanged key is a useful hint, not yet proof that every edit, rotation, regeneration, or replacement leaves the rendition unchanged. It is not a checksum for a day, page, or whole library.

Also use `thumbnail.unit_id`, not `item.id`: they differ in many records. Personal and Shared Space must not share an unqualified ID namespace.

### Live conditional-request probe

A read-only test against Cirrus on 2026-10-02 used the existing login helper to load credentials internally, queried one Personal Space item, fetched its `sm` thumbnail, and logged out. No library content was modified or saved, and credentials/tokens were not printed.

| Request | Result |
| --- | --- |
| Authenticated thumbnail GET | HTTP 200, `image/jpeg`, 44,804 bytes, ETag and Last-Modified present |
| Same thumbnail with `If-None-Match` | HTTP 304, zero body bytes |
| Same thumbnail with `If-Modified-Since` | HTTP 304, zero body bytes |

This confirms conditional reuse for one unchanged rendition on the current server, not validator behavior after edits. The successful probe supplied the DSM session via both the `id` cookie and `_sid`, alongside SynoToken; it did not isolate which session mechanism is sufficient. An earlier token-only request returned HTTP 200 with a JSON body, not an image. The image transport must preserve valid authentication and check response type/decode success, not only HTTP status. The current Swift login uses SID format; do not assume that this necessarily populates the cookie needed by image endpoints.

### What Synology says about mobile

Synology documents offline browsing of previously viewed files and a user-selectable cache size in both its [Android](https://kb.synology.com/index.php/en-global/DSM/help/SynologyPhotos/Android) and [iOS](https://kb.synology.com/en-uk/DSM/help/SynologyPhotos/iPhone) help.

Its [mobile architecture overview](https://blog.synology.com/how-the-synology-photos-app-empowers-users-to-safeguard-and-manage-their-photos/) describes reuse of previously viewed photos, preloading other photos, eviction of the “least viewed” cached photos at the size limit, and matching NAS photos to local phone copies. That wording does not specify an exact LFU/LRU algorithm. The article does not disclose the cache schema, validation interval, use of `cache_key`, or a library revision protocol. Local-phone matching does not help this macOS remote-library prototype.

Our proposed behavior is therefore informed by public evidence, not a claim to reproduce Synology's private mobile implementation.

## Freshness: once per run, when needed

Create one process-wide `runID`, shared by windows. For each resource, record whether a successful network validation belongs to that run. Restarting the process makes older entries eligible for validation; it does not delete them. Reauthentication alone does not create a new library run.

| Resource | Cached-first behavior | First use in a new run |
| --- | --- | --- |
| Full timeline for a space/filter | Display the cached complete timeline immediately | Authenticate and fetch the full timeline once; atomically replace it if changed. |
| Item page | Display an exactly matching cached page, marked provisional | Fetch that page once using the current timeline's descriptor, even if timeline counts did not change. |
| Thumbnail | Display the cached rendition provisionally | After current item metadata is available, resolve its rendition key and conditionally validate/download the needed image. |
| Viewer `xl` preview | Display cached preview after the clicked/configured rendition | If enabled with `sm`/`m`, conditionally validate/download current and adjacent previews concurrently with the current original; promote in place if later demanded as an ordinary `xl` thumbnail. |
| Full-size photo | Display cached original bytes after immediate thumbnail preview | After current metadata is verified, conditionally validate/download the original; prefetch only adjacent images after current success. |
| Future album/map resources | Same two-stage interface | Define identity and validation rules per endpoint when implemented. Do not assume the timeline validates them. |

After successful validation, reopening that resource in the same run uses cache without another freshness request. If its bytes were evicted, a download is still necessary; a validation marker is not a substitute for data. Store run markers with cache entries rather than retaining every payload in memory.

### Startup order

1. Establish the configured server/account namespace locally. Read cached full timeline and begin login independently, so login latency does not block cached display.
2. With a cached full timeline, skip `get_init_timeline` and request the full timeline directly. Do not shrink a complete cached navigator to the newest 500 items while refreshing.
3. On a cold cache, retain the initial-then-full bootstrap. Store initial and full responses separately; the initial response's truncated final section is not interchangeable with a full section.
4. Replace the date/section map as one snapshot. Preserve selection by calendar date, and eventually scroll position by stable item ID plus local offset—not by section or array index. If the anchor disappeared, choose the nearest remaining date deterministically. Empty results are valid results, not loading errors.
5. Display cached content for the old visible region while this is pending, but do not launch new network page requests from obsolete descriptors. Once the current full map arrives, resolve the visible date against it, validate its pages, then validate/load images for those pages.
6. Leave unvisited pages and images on disk without validating them. A distant timeline jump validates only the destination and a small prefetch window.

The full map can be identical while a photo is replaced, edited, or deleted and another added on the same day. Equal counts do not validate item metadata. Likewise, a changed map need not cause deletion or redownload of all old thumbnails.

### Thumbnail baseline

Use this conservative policy until rendition-version semantics are verified:

- Refresh the parent item page first. An old cached image can be shown in the meantime with the page's provisional status.
- If the refreshed descriptor has a different `cache_key`, select the new rendition entry and fetch it if absent. Do not label the old rendition as current.
- If the current rendition is cached but not validated this run, send `If-None-Match` with its ETag, otherwise `If-Modified-Since` with its Last-Modified. With neither, perform a normal GET.
- A 304 retains the bytes and marks the entry validated. A valid 200 replaces the bytes and validators atomically. A 304 without locally available bytes requires an unconditional retry.
- Only visible/nearby images enter this queue. Do not issue a HEAD followed by a GET or validate the entire disk cache on startup.
- Never reuse validators across different rendition keys or sizes. A response replacing bytes under the same key must also invalidate its decoded image; include the payload digest in decoded-image identity.

This adds one small validation request per demanded cached thumbnail per run, not necessarily another image download. If targeted edit/regeneration tests establish that the key reliably versions all relevant changes, we can skip these requests after a current item page confirms the same key. Keep that optimization behind a policy boundary; correctness must not depend on an undocumented assumption.

### Failure and deletion behavior

Network failure with cached data leaves usable data visible with an offline/stale indication. A failed request is not marked validated. Avoid reconnect loops from repeated cell appearances: coordinate a small bounded retry policy and offer explicit retry. Cache misses show an error/placeholder, not a fake empty library.

An authoritative successful empty page or changed membership replaces the old page; removed items disappear. Authentication/permission failures are not ordinary offline success: surface the problem and stop further requests. An explicit logout/account switch clears visible data and separates cache namespaces; offer cache removal. Cached-first offline access inherently cannot discover revoked server permissions until reconnection, so it is not an offline authorization guarantee.

Use a timeline-generation token for in-flight page work. A late result from an obsolete generation must never overwrite the current visible page or mark its replacement validated. It may be discarded. The server is assumed static during this loading session; no incremental change-feed work is required.

## Interface and ownership

The user's middleware idea fits, with one important adjustment: cache semantic resources, not arbitrary raw HTTP requests. A single `async throws -> Value` cannot express both a cached answer and a later replacement. Use a finite stream of load states:

```swift
// Illustrative interface, not implemented code.
repository.load(.timeline(space: .personal))
    -> AsyncStream<ResourceState<TimelineSnapshot>>

// Typical sequence:
// cached(value, freshness: .stale)
// resolved(value, freshness: .validatedThisRun)
// finish
```

A terminal state can instead contain a refresh error while retaining the cached value. Cache misses emit loading followed by resolved/error. Each event should be self-contained; use a bounded latest-state buffer. Unchanged content updates freshness without rebuilding/redecoding the payload. Consumers that only need a final value can use a convenience async function on the same repository.

Swift's [AsyncStream design](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md) supports explicit completion and termination cleanup. Finish streams after resolution. Remove their continuations and completed tasks from the coordinator; cancellation detaches the subscriber. Separate callers need separate streams fed by a shared job, not competing iterators over one stream.

Suggested boundaries:

- `SynologyClient`: authentication, transport, protocol decoding, response validators. No SwiftUI dependencies.
- `CachedPhotosRepository` actor: typed resource keys, freshness policy, cached-first delivery, in-flight coalescing, generation checks.
- `DiskCache`: SQLite records, image files, integrity, size accounting, eviction. Use asynchronous database access and a dedicated utility I/O executor; an actor alone does not make blocking file operations cheap.
- `ImagePipeline`: bounded downloads/decode, downsampling, decoded memory cache, current rendition identity.
- `@MainActor` view models: current timeline, viewport pages, visible image states, selection, connection status. No whole-cache observation.

`TimelineSnapshot` retains complete Codable section descriptors (`offset`, `limit`, day groups) alongside the derived navigator model. These reconstruct exact page requests and day slices.

### No “de-stating” operation is needed

Photo records should already be ordinary immutable `Sendable` value types. Only the small presentation container holding the current result needs observation. Once loading completes, its task/stream ends; a value sitting unchanged in `@State` is not constantly being polled or redrawn.

The important limits are retained data, decoded pixels, number of active tasks, and breadth/frequency of view invalidations. Keep the complete compact timeline, a bounded window of item pages, and visible/nearby image states. Release distant page arrays and view tasks; their persistent cache records remain usable. Do not publish a 58,712-entry image dictionary every time one thumbnail arrives. Keep cache accounting/last-access updates outside observed UI state.

## Persistent identities

All keys begin with a stable local server/account namespace and space. Do not use session tokens as identity. Store opaque account identifiers or hashes rather than credentials in filenames. A manually configured NAS identity can later support multiple URLs for the same server; initially different base URLs are separate namespaces.

| Kind | Remaining key components |
| --- | --- |
| Timeline | API/schema version, initial versus full, grouping, filters, sort if applicable |
| Item page | API/schema version, normalized date bounds, offset, limit, filters/sort, requested additional fields |
| Compressed thumbnail | Thumbnail API version, unit ID, opaque cache key, type, requested `sm`/`m`/`xl` size |
| Full-size photo | Download API version, unit ID, opaque cache revision |
| Decoded image | Compressed rendition identity and payload digest, pixel-size bucket, processing/orientation policy |

Persist a page's owning timeline fingerprint/generation as a dependency, not just its numeric section index. Unchanged request descriptors can reuse cached pages provisionally across timeline changes, but must still validate. Do not invent overlapping-page merging for the MVP: if a new descriptor has no exact cached match, fetch it. Old page records remain eviction candidates.

Canonicalize semantic parameters before hashing. `SynoToken`, `_sid`, cookies, passwords, OTPs, and other transient authentication fields must not enter cache keys or persisted request URLs. Do not blindly strip arbitrary parameters from arbitrary URLs: endpoint-specific code defines the allowlist. Cache only approved read resources and successful decoded payloads, never login/logout, mutations, error envelopes, or HTML responses.

## Swift storage choices

[URLCache](https://developer.apple.com/documentation/foundation/urlcache) provides memory/disk HTTP response caching, and [URLSession cache policy](https://developer.apple.com/documentation/foundation/accessing-cached-data) controls its use. It is useful transport machinery, but cannot by itself supply our semantic POST keys, two-stage publication, category priorities, and per-run dependency validation. The captured metadata `no-store` directives further rule out treating this as transparent HTTP caching. Our explicitly requested local data store persists selected application records, not a general HTTP response archive.

For the baseline, keep URLSession's independent disk cache disabled for these resources, handle image validators explicitly, and have one owner of persistent cached bytes. Otherwise URLCache and the application cache can store the same image twice and exceed the user-visible budget.

Recommended implementation tools:

- SQLite through [GRDB](https://github.com/groue/GRDB.swift): indexed eviction, transactions, migrations, asynchronous access. Store compact timeline/page JSON payloads in SQLite initially; no need to normalize all photo fields or create SwiftData models for every item. GRDB's observation features are not required for the whole cache.
- Hashed, directory-sharded files for compressed image payloads. Do not store large originals or decoded bitmaps in the database.
- [NSCache](https://developer.apple.com/documentation/foundation/nscache) for disposable decoded images, charged by actual decoded bytes (`bytesPerRow * height`), not JPEG size. Its [cost limit is advisory](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit), so bound visible references and decode concurrency separately; it is not a hard process-memory ceiling.
- ImageIO downsampling with a [maximum pixel dimension](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize), off the main actor.

[Nuke](https://github.com/kean/Nuke) already provides image request coalescing, priorities, processing, caching, and SwiftUI integration. Evaluate it for the image stage rather than rebuilding all those facilities. The integration must accept our authenticated transport, semantic rendition identity, explicit revalidation, and shared disk budget; do not simply hand authenticated URLs to a second default cache. Pin a compatible released package version after checking the local Swift toolchain. The first timeline-cache milestone does not need an image library.

### On-disk bookkeeping and eviction

For the current development build, use the repository's `.cache/` directory. It is ignored by Git and is not in macOS's system-managed Caches directory. Resolve the repository rather than trusting the process working directory, which is unstable when launching a `.app`. A best-effort one-time migration preserves the earlier account-scoped cache. See [decision 001](decisions/001-development-cache-location.md).

This location makes cache persistence follow the project checkout. It is a prototype choice, not a distribution layout. If the app later returns to `~/Library/Caches`, it must treat partial or complete purging as normal: rebuild a missing/corrupt SQLite index, remove rows for missing images, remove orphan files not represented by the index, and make clear-cache remove the entire namespace. A separate user-requested offline library would belong in a non-purgeable location with an explicit lifecycle.

A cache entry needs: key/namespace/kind, schema version, payload or relative file path, byte cost, content digest, fetched time, last access, validated run ID, optional ETag/Last-Modified, and dependency fingerprint. Index eviction fields. Query small candidate batches rather than loading the entire index or scanning every file on a miss. Batch access-time writes; never block scrolling on an LRU timestamp update.

Keep priorities separate from request scheduling. Evict in this order, LRU within a class:

1. Viewer-fetched `xl` preview thumbnails.
2. Full-size photos (original image bytes).
3. Ordinary compressed thumbnails.
4. Item pages and future album/map metadata.
5. Current complete timeline snapshots, protected during ordinary eviction.

Remove superseded/unreferenced generations before useful current entries. Only a small bounded set of current timelines is protected; do not pin every historical timeline or all metadata forever. A protected timeline still counts toward the budget and can be cleared explicitly.

Use one total disk budget, with reserve for SQLite, WAL/journals, allocation overhead, and bounded temporary writes. Account for actual allocated usage where practical. Stop admissions/evict before committing large payloads, trim below the cap to avoid repeated tiny evictions, and checkpoint/compact the database in maintenance work when needed. A file larger than the available budget should be displayed from temporary storage if feasible, not evict the entire useful cache. Low free disk space takes precedence over the configured maximum. Cache-write failure must not discard a valid network response.

Write image bytes to a temporary file, validate them, atomically rename, then commit the index record. These filesystem/database operations are not a single atomic transaction: tolerate orphan files, missing files, and interrupted cleanup. Missing/corrupt payloads become misses; run bounded reconciliation in background, not a full directory walk before first paint. Coordinate readers/eviction so a 304 never claims usable bytes that were removed mid-request.

Cached images and metadata are private user data even without credentials. Use an app-private location, avoid content in diagnostics, and provide clear-cache/account-removal behavior. Hashing filenames is not encryption. Keychain migration for credentials remains separate work.

## Settings and scheduling

Add a native SwiftUI `Settings` scene, reachable through the app menu and Command-comma:

- Thumbnail rendition: Small (`sm`), Medium (`m`), Large (`xl`). These are separate cache variants; only request sizes reported ready. Choose Medium as an initial default to evaluate on Retina displays, not a proven optimum. A setting change affects new visible demands and does not eagerly redownload the library.
- Load large previews in viewer: persisted opt-in, default off. With Small or Medium selected, fetch/cache `xl` for the current photo and immediate neighbors without delaying the original. With Large selected, ordinary `xl` thumbnails already provide this stage, so the option is inactive. Disabling it leaves existing preview entries for normal eviction.
- Total disk budget: 200 MB–100 GB, logarithmic. Use decimal units consistently: `bytes = 200_000_000 * pow(500, sliderFraction)`. Store the byte count, not the slider position. Lowering it schedules eviction; increasing it does not trigger a library-wide download.
- Show used bytes and a clear-cache action. Disk budget is distinct from decoded-memory limits.

The HAR's successful `sm` images average roughly 35 KB: extrapolating to 58,712 items gives roughly 2 GB compressed, before other sizes/metadata. This is only an estimate from the viewed sample. A 240×320 RGBA bitmap is about 300 KB before overhead, so retaining the whole library decoded would be on the order of 18 GB. A large disk setting must never enlarge RAM retention proportionally.

Begin with a small metadata queue (for example two requests), at most six visible image transfers plus two prefetch transfers, and a separately limited decode queue. These are tuning values, not Synology limits. Cache hits should not wait behind network work. Coalesce duplicate requests, promote prefetch when it becomes visible, remove obsolete queued work on jumps, and cancel a shared transfer only when no consumer still needs it. Bound queue length as well as concurrency. Coordinate session renewal centrally.

## Implementation sequence and acceptance criteria

1. **Timeline vertical slice.** Retain full descriptors; introduce typed keys, a testable transport/storage boundary, run freshness, cached-first finite results, and the SQLite cache. Connect the existing navigator. Test warm launch, offline launch, changed/empty timeline, partial initial response, and stable date anchoring. No grid yet.
2. **Budget and settings.** Implement accounting/eviction with synthetic blobs and metadata, the log slider, rendition preference, clear-cache behavior, and crash recovery. Test the 200 MB limit and reduction from a larger limit without downloading a large real library.
3. **One real photo section.** Add item-page caching and the image pipeline. Reproduce the conditional-request probe through the Swift transport; verify size variants, authentication, cached-first updates, failed refresh, and decoded-memory limits. Benchmark before generalizing the image-library integration.
4. **Scrolling and jumps.** Expand to a virtualized bounded viewport, directional prefetch, cancellation, and measured request scheduling. Test large split days and rapid distant jumps. Full photo view uses these storage primitives with a separate resource policy; albums and maps remain future work.

Required automated cases include: identical counts with changed item IDs; reordered/shifted sections; a deleted selected date; key changed/unchanged with changed bytes; 304 with/without payload; HTTP 200 API error envelope; timeout/503; auth failure; corrupt cache; account/space isolation; token rotation not changing identity; cancellation of one of two subscribers; late obsolete results; and reopening an evicted memory page without redundant validation when its disk entry is current.

Measure time to cached first paint, time to validated data, network bytes/304 counts, hit rates by cache layer, queued/cancelled work, peak decoded memory, and settled disk usage. Use sanitized aggregate diagnostics, never authenticated URLs or photo names.

## Remaining targeted investigations

Conditional headers alone cannot establish that validators change correctly after edits. Before removing per-run thumbnail validation, use an agreed test photo to compare key, ETag, and bytes across rotation, replacement, and thumbnail regeneration. Do not modify the user's library as part of passive research.

An Android capture would be useful later for discovering a mobile-only bulk validation/change-token API, confirming prefetch patterns, or explaining a measured performance gap. A useful experiment would compare cold launch, warm same-run revisit, relaunch, and an agreed between-run edit with normal cache settings. It is not necessary to design or implement the conservative cache above, and traffic alone may not reveal internal disk eviction. Treat any capture as sensitive.

## Full-size photo resources

Full-size photos use the authenticated `SYNO.Foto.Download` v2 route, independently of grid rendition settings. Compressed originals are stored as files, with cache kind 0 so they are evicted before thumbnails, pages, and the protected current timeline. They share the configured total budget; an oversized original can be displayed from the response without remaining cached. Keys contain server/account namespace, endpoint version, unit ID, and opaque cache revision, never authentication parameters.

The repository emits cached bytes immediately and conditionally validates once per run. A separate transfer gate has two slots, with at most one speculative transfer, so a newly selected photo has reserved admission capacity. Visible subscriptions coalesce with and promote matching speculative work, including promotion before admission. Leaving a resource cancels it when its final subscriber leaves. Full-image decoding uses one worker and one replaceable pending request, applies orientation at full pixel resolution, and explicitly rejects images exceeding a 384 MB estimated/decoded bitmap limit; it never silently calls a downsampled result full resolution.

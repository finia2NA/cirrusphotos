# Synology Photos timeline and thumbnail API

This is the implementation reference for the first Synology Photos client milestone: browsing a large chronological library without loading the whole catalog or all thumbnails into memory.

The conclusions combine:

- Synology's official DSM Login Web API documentation;
- the APIs advertised by `cirrus` through `SYNO.API.Info`;
- community reverse-engineering of the undocumented Photos APIs; and
- a Chrome HAR captured from Synology Photos 1.9.1-10928 while opening Shared Space, switching to Personal Space, scrolling, and jumping through the timeline.

Photos-specific behavior is not an official public contract. Decode defensively, discover supported API versions at runtime, and keep request construction isolated behind a client interface.

## Executive summary

Synology's web client does **not** paginate the entire library with one global numeric offset. It uses two levels:

1. `Browse.Timeline` returns a compact map of the library. The map contains chronological day groups arranged into sections of roughly 100–200 items. It contains counts and date boundaries, not photo records.
2. `Browse.Item.list` loads one section by using that section's date range, offset, and limit. This provides random access: a timeline jump can request section 355 directly without fetching sections 1–354.

Thumbnails form a third, independently lazy layer. The item response includes thumbnail identity and version metadata. Only visible or nearby cells request JPEG thumbnails; item metadata for an entire section does not imply that every thumbnail in the section is fetched.

The corresponding client pipeline should be:

```text
authenticated session
        |
        v
500-item initial timeline map ----> first visible item section
        |                                  |
        v                                  v
full compact timeline map          visible thumbnail requests
        |                                  |
        v                                  v
random section lookup               bounded memory/disk caches
```

## Capture scope and safety

The HAR contains 409 requests over about 145 seconds. Of these, 34 responses are JSON and 338 are thumbnail requests. It includes Personal Space filenames, media metadata, a session token, and other account information. It is intentionally ignored by Git via `*.har` and should not be committed or shared without sanitization.

All 409 captured requests have `Cache-Control: no-cache`, which strongly suggests Chrome DevTools had caching disabled for the recording. Consequently, the HAR is useful for request shape and scheduling, but it cannot show normal browser cache-hit behavior.

Examples in this document omit real filenames, media identifiers, credentials, and tokens.

## API discovery and authentication

The official DSM flow is:

1. Query `SYNO.API.Info` at `/webapi/entry.cgi`.
2. POST `SYNO.API.Auth.login` and retain the session cookie/session ID and `SynoToken` when enabled.
3. Make authenticated API calls using the mechanism supported by the target DSM build.
4. Call `SYNO.API.Auth.logout` when the session is no longer needed.

For TOTP accounts, the current six-digit value is passed as `otp_code`. The login probe in `scripts/test_synology_login.py` implements this flow without persisting a trusted-device token.

On 2026-10-02, `cirrus` advertised:

| API | Versions |
| --- | ---: |
| `SYNO.API.Auth` | 1–7 |
| `SYNO.Foto.Browse.Item` | 1–7 |
| `SYNO.Foto.Browse.Timeline` | 1–6 |
| `SYNO.Foto.Thumbnail` | 1–2 |
| `SYNO.FotoTeam.Browse.Item` | 1–7 |

The web capture used an `X-SYNO-TOKEN` header on Photos API POSTs and placed `SynoToken` in thumbnail query strings. Cookies are absent from the exported HAR, so the capture does not prove that the token alone is sufficient. The native client should use one `URLSession` with an `HTTPCookieStorage`, preserve the login session, and supply `X-SYNO-TOKEN` where available. It should avoid putting a session ID in logs or persistent URLs.

## Personal Space and Shared Space

The parallel API families are:

| Space | Timeline and item prefix | Thumbnail path segment |
| --- | --- | --- |
| Personal Space | `SYNO.Foto.*` | `p` |
| Shared Space | `SYNO.FotoTeam.*` | `t` |

The timeline and item schemas observed in the two spaces are equivalent. Keep the space as an explicit domain value rather than spreading string conditionals throughout the client.

```swift
enum PhotoSpace: Hashable, Sendable {
    case personal
    case shared
}
```

## Timeline bootstrap

### Initial timeline

The web app first sends:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Timeline
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
X-SYNO-TOKEN: <redacted>

api=SYNO.Foto.Browse.Timeline
method=get_init_timeline
version=6
timeline_group_unit="day"
```

Shared Space substitutes `SYNO.FotoTeam.Browse.Timeline`.

In both spaces, `get_init_timeline` described exactly the newest 500 items:

| Space | Sections | Unique day groups | Items represented | Response size | Observed duration |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shared | 4 | 39 | 500 | 2,055 bytes | 901 ms |
| Personal | 4 | 14 | 500 | 908 bytes | 1,560 ms |

This response is sufficient to identify and request the first visible section without waiting for the complete library index.

### Full timeline

After the initial timeline succeeds, the web app sends the same request with `method=get`. It starts the first item-section request while this full timeline request is still in flight.

The captured full indexes were:

| Space | Sections | Unique day groups | Total items | Response size | Observed duration |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shared | 157 | 717 | 19,381 | 41,370 bytes | 2,028 ms |
| Personal | 494 | 2,192 | 58,712 | 130,151 bytes | 2,035 ms |

This is the main scalability mechanism. A 58,712-item library becomes a 130 KB index, so the client can build a timeline scrubber and jump directly to old dates without loading tens of thousands of item objects.

### Timeline response model

The response has this shape:

```json
{
  "success": true,
  "data": {
    "section": [
      {
        "offset": 0,
        "limit": 163,
        "list": [
          { "year": 2026, "month": 10, "day": 1, "item_count": 40 },
          { "year": 2026, "month": 9, "day": 30, "item_count": 15 }
        ]
      }
    ]
  }
}
```

Fields:

- `section` is ordered newest to oldest.
- `list` contains one or more day groups, also newest to oldest.
- `item_count` is the count for the entire day, not necessarily the count returned by this section.
- `limit` is the exact item-list page size for the section.
- `offset` is normally zero. When a single day is too large for one section, that day is repeated in multiple sections and `offset` advances within the day.

For example, one captured day contained 675 items and was represented by six sections:

| Section part | Offset | Limit |
| ---: | ---: | ---: |
| 1 | 0 | 113 |
| 2 | 113 | 113 |
| 3 | 226 | 113 |
| 4 | 339 | 112 |
| 5 | 451 | 112 |
| 6 | 563 | 112 |

This was also verified directly against `cirrus`: requesting a split-day section with `offset=114` and `limit=114` returned exactly 114 items, all within that section's day bounds.

Do not sum every `item_count` occurrence across sections because split days repeat the same day-level count. The library total can be calculated either by summing section `limit` values or by deduplicating `(year, month, day)` and then summing `item_count`.

The section size is server-selected, not fixed. In this capture:

| Space | Minimum | Median | 75th percentile | 95th percentile | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shared | 4 | 118 | 134 | 185 | 237 |
| Personal | 5 | 112 | 128 | 181 | 228 |

The client must honor the returned values rather than assuming a page size of 100.

## Loading an item section

For each required timeline section, the web client sends a form-encoded POST:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Item
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
X-SYNO-TOKEN: <redacted>

api=SYNO.Foto.Browse.Item
method=list
version=7
offset=<section.offset>
limit=<section.limit>
start_time=<oldest day at 00:00:00>
end_time=<newest day at 23:59:59>
additional=["thumbnail","resolution","orientation","video_convert","video_meta","address","favorite"]
```

The quoted strings and `additional` array are JSON values inside the form fields and therefore appear percent-encoded on the wire. Shared Space again uses the `SYNO.FotoTeam` prefix.

Every one of the eight captured item requests matched exactly one section from the full timeline response. The sequence demonstrates random access:

| Action/phase | Space | Timeline section(s) requested | Limits |
| --- | --- | --- | --- |
| Initial opening | Shared | 0 | 110 |
| Switch to Personal | Personal | 0 | 163 |
| First jump/scroll | Personal | 205 and 206 concurrently | 120, 110 |
| Continue nearby | Personal | 207 and 208 concurrently | 111, 119 |
| Later jump | Personal | 355 and 356 concurrently | 172, 150 |

No intermediate sections were requested when jumping from section 0 to 205 or from 208 to 355. This is why the full timeline map is valuable.

The observed API returned exactly `limit` records each time and did not include a `total`. Results were in descending `time` order. No explicit sort fields were sent, so descending timeline order is the server default for this request shape.

### Item response shape

Observed item fields include:

```text
id
filename
filesize
time
indexed_time
owner_user_id
folder_id
type
live_type                 optional
additional
  resolution             width, height
  orientation
  orientation_original
  thumbnail
  address                 optional
  video_convert           optional
  video_meta              optional
```

Requested `additional` fields may be absent when they do not apply or have no value. Models should therefore make nested additions optional and should tolerate future keys.

Observed `additional.video_meta.duration` values are milliseconds (for example, `49000` represents 49 seconds). Keep this unit when serializing cached item responses and convert to seconds for display.

Synology represents an iPhone Live Photo's still member with `type: "live"` and
`live_type: "photo"`. Treat that item as a photo when requesting and displaying
the original image; only items with `type: "video"` should enter the unsupported
video-playback path.

The section identity should include space plus the values supplied by the server, rather than only the array index:

```swift
struct TimelineSectionID: Hashable, Sendable {
    let space: PhotoSpace
    let startTime: Int64
    let endTime: Int64
    let offset: Int
    let limit: Int
}
```

This remains meaningful if a refreshed timeline inserts newer sections and shifts array indexes.

## Thumbnail protocol

### Request

The current web client does not use `/webapi/entry.cgi` for grid thumbnails. It uses a newer path:

```http
GET /synofoto/api/v2/p/Thumbnail/get
    ?id=<thumbnail.unit_id>
    &cache_key="<thumbnail.cache_key>"
    &type="unit"
    &size="sm"
    &SynoToken=<redacted>
```

Shared Space changes `/p/` to `/t/`.

The string parameters are JSON-string encoded, including their quotation marks. A robust URL builder should use `URLComponents`/`URLQueryItem` rather than manual escaping.

### Use `unit_id`, not item `id`

This distinction is critical. The item response contains data such as:

```json
{
  "id": 123,
  "additional": {
    "thumbnail": {
      "unit_id": 456,
      "cache_key": "456_...",
      "sm": "ready",
      "m": "ready",
      "xl": "ready",
      "preview": "broken"
    }
  }
}
```

Across 1,055 captured item records, `thumbnail.unit_id` differed from item `id` 739 times. All thumbnail requests matched `thumbnail.unit_id`; trying to build the URL from item `id` would fail for most of this sample.

Treat `unit_id` as an opaque thumbnail identity. The reason for a differing ID is not established by the HAR and should not be inferred in the data model.

### Returned image characteristics

All 337 successful captured thumbnail bodies were JPEG, including thumbnails for non-JPEG originals. `size="sm"` preserved aspect ratio and normally fixed the shorter edge at 240 pixels.

Common decoded dimensions were:

| Dimensions | Count |
| --- | ---: |
| 240 × 320 | 202 |
| 240 × 427 | 37 |
| 320 × 240 | 32 |
| 240 × 520 | 24 |
| 360 × 240 | 16 |
| 359 × 240 | 15 |

Less common panoramic and near-square dimensions were also present, up to 640 × 240 in this sample. The median response body was about 35 KB.

`additional.resolution` already describes display orientation. A cache-to-JPEG comparison covered 342 records carrying rotated orientation metadata (319 with orientation 6 and 23 with orientation 8); the raw resolution ratio was closer to the served JPEG ratio in all 342, while swapping width and height was closer in none. The optional orientation value should therefore be retained as metadata, not reapplied when computing grid geometry.

For the thumbnail metadata inspected, `sm`, `m`, and `xl` were all `ready`, while `preview` was `broken`. The client should check readiness instead of assuming every generated size is available and should show a placeholder/retry state when a requested rendition is not ready.

### Demand-driven loading

The browser did not fetch every thumbnail for each loaded item section:

| Item records returned | Thumbnails requested from that section |
| ---: | ---: |
| 110 | 32 |
| 163 | 29 |
| 120 | 57 |
| 110 | 102 |
| 111 | 5 |
| 119 | 5 |
| 172 | 79 |
| 150 | 29 |

The two sections for which only five thumbnails were requested were quickly followed by another distant jump. This is consistent with viewport-driven loading and abandoning work that is no longer useful. The HAR alone cannot prove whether individual in-flight HTTP requests were explicitly cancelled, but it clearly shows that the client did not enqueue every thumbnail from the newly loaded sections.

The initial Personal Space viewport marked 24 thumbnail requests as high priority and five as low priority. The initial Shared Space viewport used 12 high and 20 low. Later requests were low priority. These browser priorities support a visible-first policy, although native code should implement explicit task priority instead of relying on HTTP heuristics.

### Scheduling and overload

Thumbnail responses used HTTP/2. The web application sometimes exposed a very large set of image URLs at once; one burst contained 82 requests with nearly identical start timestamps, after which Chrome queued much of the work. One of 338 thumbnail requests returned HTTP 503 after spending about 15 seconds in the browser queue. Successful thumbnails had a median total duration of about 1.6 seconds in this remote capture, and the slow tail was much larger during bursts.

The native app should not reproduce an unbounded browser burst. Start conservatively with:

- 6 concurrent visible thumbnail downloads;
- 2 concurrent prefetch downloads;
- visible work always ahead of prefetch work;
- cancellation of queued prefetch when the viewport moves;
- exponential backoff with jitter for 503 and transient network failures;
- no automatic retry loop for authentication errors or permanent 4xx responses.

These concurrency numbers are implementation starting points, not values discovered in the Synology protocol. They should be measured on the target NAS and adjusted if necessary.

## Thumbnail caching

Every thumbnail response included an `ETag`; the 337 successful responses included `Last-Modified`. No thumbnail response included `Cache-Control` or `Expires`. Every request carried `no-cache`, likely because caching was disabled in DevTools; the capture cannot establish how the normal web app reuses its browser cache.

Timeline and item-list responses, unlike thumbnails, explicitly carry `Cache-Control: max-age=0, no-cache, no-store, must-revalidate` and no observed HTTP validators. Offline metadata storage therefore needs an explicit application-data policy, not just automatic HTTP response caching.

The strongest application cache key available is:

```text
(server/account namespace, space, thumbnail.unit_id, thumbnail.cache_key, requested_size)
```

`cache_key` is a server-provided rendition-version hint. If it changes, the URL and local cache key change naturally. The capture does not prove that it changes for every possible content edit. Do not key only by item ID or filename, or parse the key as a freshness timestamp.

Recommended native cache layers:

1. An `NSCache` of decoded display images with a total-cost limit based on decoded bytes (`width × height × 4`), not compressed JPEG size.
2. A disk cache of compressed JPEG data keyed by a hash of the tuple above.
3. In-flight request coalescing so multiple cells asking for the same key share one task.
4. Demand-driven validation once per app run, using `ETag`/`Last-Modified` for cached thumbnails until reliable rendition-version semantics have been established.

The disk cache should have an explicit size limit and LRU eviction. Avoid storing session tokens in cache filenames or metadata.

The [cache design proposal](CACHING_PLAN.md) refines these recommendations with cached-first startup, category priorities, semantic request keys, and bounded UI state. Its freshness policy supersedes a generic time-based expiration policy.

A subsequent read-only Cirrus probe confirmed both ETag and Last-Modified conditional requests return HTTP 304 with no body for an unchanged `sm` thumbnail. See the proposal for the probe's authentication details and limits; edit-driven invalidation remains unverified.

## Recommended client architecture

### API layer

Use one actor-isolated API client around one configured `URLSession`:

```text
SynologySession actor
  - login/logout and token lifecycle
  - URLSession + cookie storage
  - API discovery/version selection
  - form encoding and response/error decoding

PhotosAPI
  - initialTimeline(space)
  - fullTimeline(space)
  - items(space, section)
  - thumbnail(space, descriptor, size)
```

Do not allow views to assemble URLs or know about `SYNO.Foto` versus `SYNO.FotoTeam`.

### Library state

Keep timeline descriptors separate from loaded item records:

```text
TimelineStore actor / observable facade
  timeline: [TimelineSection]
  sectionState: [TimelineSectionID: unloaded | loading | loaded | failed]
  loadedItems: bounded section cache
```

The full timeline descriptor list is small enough to retain. Loaded item pages should be bounded—initially, retain the visible section plus a few neighbors and discard distant section item arrays under memory pressure. The timeline descriptors remain, so discarded sections can be fetched again directly.

### Viewport algorithm

1. On a cold cache, authenticate and request `get_init_timeline`. With a cached full timeline, show it immediately and fetch the full map directly; see the cache proposal for that path.
2. Publish its sections immediately and start the first visible `Item.list` request.
3. In parallel, request the full timeline with `get`.
4. Replace/merge the initial section map with the full map using section identities.
5. As the viewport changes, ensure the current section is loaded.
6. Prefetch at most one adjacent section in the scroll direction.
7. When the user jumps, cancel queued work for the old region, load the destination section, and optionally load its next neighbor concurrently.
8. Request thumbnails only when cells enter a small preheat window around the viewport.
9. Cancel queued thumbnail prefetch as cells leave that window; allow already-near-complete visible requests to finish and populate the cache.

This preserves the web client's successful random-access design while putting a stricter bound on NAS load.

### SwiftUI implications

A 58,000-item library should not be represented as 58,000 fully populated cell view models at startup. The scroll model should operate in timeline sections and estimated section heights. Only loaded sections materialize media cells; unloaded sections can use a height estimate derived from `limit`, column count, and cell geometry.

Important details:

- Store stable item identity separately from array position.
- Keep image loading tasks out of view initializers.
- Start/cancel loading from a dedicated viewport/prefetch coordinator rather than every cell independently making network policy decisions.
- Downsample decoded images to the actual rendered pixel size. The server's `sm` image is already small, but a bounded decoded cache is still required.
- Avoid retaining full-resolution originals anywhere in the grid path.
- Use placeholders with the item's known aspect ratio from `additional.resolution` to prevent layout jumps before thumbnails arrive.

## Error and refresh behavior

- A failed section request should leave the section descriptor intact and expose a retry state.
- A thumbnail 503 should back off and retry only while the item remains visible/relevant.
- A 119-style invalid-session response should trigger one coordinated reauthentication path, not one login attempt per cell.
- Refreshing the full timeline may insert or remove sections. Reconcile by section identity and preserve the user's anchor item/date where possible.
- API response parsing should ignore unknown keys and tolerate missing optional `additional` data.

## Confirmed facts versus inferences

Confirmed by the capture:

- `get_init_timeline` represented 500 newest items in both spaces.
- `get` returned the compact complete timeline index.
- Section `offset`, `limit`, and date boundaries exactly generated observed item-list requests.
- A direct nonzero-offset request returned the expected slice of a split day.
- Distant jumps loaded distant sections directly.
- Item metadata and thumbnails were loaded independently.
- `thumbnail.unit_id` was used in every thumbnail URL.
- `sm` thumbnails were JPEGs with a usually 240-pixel shorter edge.
- Only a subset of loaded items had thumbnails requested.

Strong but not fully provable from one HAR:

- The UI uses viewport virtualization/lazy image mounting. Request timing and partial thumbnail coverage strongly support this.
- The second concurrently loaded section is directional prefetch. It may instead be needed to fill the measured viewport after a jump.
- `cache_key` is a version identifier. Its placement and conventional usage strongly imply this, but Synology does not publish the contract.

## Open questions for focused probes

Before hardening the production data layer, record or directly test:

1. Timeline behavior when the user setting groups by month instead of day.
2. Normal browser caching with DevTools cache disabling turned off.
3. Thumbnail responses while Synology is still generating a rendition.
4. Library changes during a session and whether `SYNO.Foto.Browse.Diff` can update the timeline incrementally (deferred beyond the current static-session scope).
5. Sort stability for multiple items with identical `time` values.
6. Session expiry and reauthentication error codes on the Photos endpoints.
7. Whether `m` is preferable to `sm` on high-density displays at the intended grid cell size.

## References

- Synology, DSM Login Web API Guide: <https://kb.synology.com/en-us/DG/DSM_Login_Web_API_Guide/2>
- Unofficial Synology Photos API documentation: <https://github.com/zeichensatz/SynologyPhotosAPI>
- Additional reverse-engineered examples: <https://github.com/N4S4/synology-photos-api>

## Full-size photo transport

A bounded read-only probe on 2026-10-02 confirmed that Cirrus advertises `SYNO.Foto.Download` versions 1–2 at `entry.cgi`. The viewer uses an authenticated GET with `api=SYNO.Foto.Download`, `version=2`, `method=download`, `unit_id=[<thumbnail.unit_id>]`, and the opaque `cache_key`, plus the existing session authentication. The sampled PNG decoded to 1170 × 2532 pixels, matching the item's full-resolution metadata; this is independent of the `sm`/`m`/`xl` thumbnail renditions. A request targets one photo, not an archive of several items.

Keep authentication out of persistent identity and logs. Use unit ID plus cache revision and endpoint version for the full-image cache key. Treat non-image/error responses as failures; never label an enlarged thumbnail as full resolution. The initial viewer preview continues to use the already displayed thumbnail while the full-image resource is fetched and decoded.

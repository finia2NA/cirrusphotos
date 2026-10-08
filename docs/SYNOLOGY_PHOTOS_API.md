# Synology Photos timeline and thumbnail API

## Personal Space favorites

The viewer and Favorites album captures in `docs/captures/favorites.har` and `favoritesAlbum.har` show that Personal Space item lists include `additional.favorite: true` for favorited items and omit the field for other items. The existing item-list request already asks for `favorite` in its `additional` array. The Favorites album filters normal `Browse.Timeline.get` and `Browse.Item.list` requests with `favorite_only=true`. The capture does not establish that `get_init_timeline` accepts this filter, so the client uses full `get` for Favorites.

The web client changes favorite status with a form-encoded `POST /webapi/entry.cgi/SYNO.Foto.Browse.Item`: `api=SYNO.Foto.Browse.Item`, `version=7`, `method=set_favorite`, `id=[<item IDs>]`, and `favorite=true` or `false`. `favorites.har` captured the one-item form. `favoriteunfavorite2photos.har` confirmed that the endpoint accepts several IDs in one request: the web client sent the same two-item array once with `favorite=true` and once with `favorite=false`, and both returned `{"success":true}`. This endpoint is implemented for Personal Space favorites; the accompanying `SYNO.Foto.Udc.send_event` request is telemetry.

## Personal Space albums

`almbumsoverviewandopening.har` captured the album overview and one album open (Synology Photos 1.9.1-10928, 2026-10-06). The overview is a single list request:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Album
api=SYNO.Foto.Browse.Album
version=4
method=list
offset=0
limit=100
category="normal"
sort_by="album_name"
sort_direction="asc"
additional=["sharing_info","thumbnail"]
```

Album records carry `id`, `name`, `item_count`, `type`, `sort_by`, `sort_direction`, `create_time`, `start_time`, `end_time`, and `additional.{thumbnail,sharing_info}`. The album thumbnail uses the same `unit_id` / `cache_key` / `sm` / `m` / `xl` shape as item thumbnails. `additional.flex_section` returned by `method=get` is a list of per-section item counts that sums to `item_count`; its grouping meaning is not established and it is not needed for day grouping.

Opening an album does **not** use the timeline endpoint. The web client requests items directly with a scalar `album_id`:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Item
api=SYNO.Foto.Browse.Item
method=list
version=7
album_id=54
offset=0
limit=28
sort_by="takentime"
sort_direction="desc"
additional=["thumbnail","resolution","orientation","video_convert","video_meta","provider_user_id"]
```

Read-only probes against `cirrus` on 2026-10-06 established:

- `SYNO.Foto.Browse.Timeline version=6 method=get` accepts `album_id` **without error but silently ignores it**: the response is equivalent to the unfiltered personal timeline (497 sections, 424,170 items, identical day counts). Never use the timeline endpoint to discover album days.
- `Browse.Item.list` honors `start_time`/`end_time` together with `album_id`: a bounded request for a 112-item album day returned exactly 112 items, all inside the requested day. Album day sections can therefore reuse the same date-bound request shape as timeline sections.
- Bulk metadata scans work: `album_id` + `offset` + `limit=1000` + `additional=[]` returned a 987-item album in one request (~196 KB); `limit=5000` returned the same 987 items. An `offset` past the end returns an empty `list`, which is the reliable termination signal because no `total` is returned.
- `favorite_only=true` is accepted alongside `album_id`. The album captures and probes did not include a known-favorited album item, so whether `additional.favorite` is populated for album items exactly like timeline items is unverified; the client treats an absent field as not favorite, matching the documented timeline behavior.

Write endpoints are only partially captured. `albumcreationadditionremovaldeletion.har` contains just `SYNO.Foto.Browse.Album version=1 method=delete id=[<album id>]` (which deletes the album itself). It contains no create, add-item, or remove-item request. The same capture also contains `SYNO.Foto.BackgroundTask.File method=delete`, which permanently deletes a photo from the library; it is not an album-removal request and must not be used as one.

Community reverse engineering (`zeichensatz/SynologyPhotosAPI`'s dumped `SYNO.Foto.lib` and issue #16, plus `fortysix2ahead/synophotos`) records the likely shapes for a future album-management slice; none are confirmed against `cirrus`. Album writes live under `SYNO.Foto.Browse.NormalAlbum` (`create`, `add_item`, `delete_item`, `copy`, `set_unfreeze`, methods v1), while `SYNO.Foto.Browse.Album` advertises `set_name`, `set_cover`, `set_order`, `count`, `download`. The observed parameter pattern is `name=<album name>` plus `item='[<item ids>]'` (a JSON-encoded string list) for create, and `id=<album id>` plus `item='[<item ids>]'` for add/remove. Confirm with a HAR capture before implementing any write.


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
  folder                  optional full Personal Space folder path when requested
```

Requested `additional` fields may be absent when they do not apply or have no value. Models should therefore make nested additions optional and should tolerate future keys.

A read-only probe on 2026-10-09 confirmed that item `method=list` and `method=get`
v7 accept `additional=["folder"]` and return the item's complete slash-prefixed
Personal Space folder path as `additional.folder`. The ordinary page request
includes this field so single-item Info can display the path without a separate folder lookup.
`SYNO.Foto.Browse.Folder method=get` with the scalar `folder_id` returns the same
path in `data.folder.name`; an array-shaped ID is rejected.

Observed `additional.video_meta.duration` values are milliseconds (for example, `49000` represents 49 seconds). Keep this unit when serializing cached item responses and convert to seconds for display.

### Item EXIF in page lists

A read-only probe on 2026-10-06 confirmed that `SYNO.Foto.Browse.Item` `method=list` honors `exif` in its `additional` array. This client therefore requests EXIF with every item page instead of issuing per-item `method=get` requests the way the web client does. Each item then carries an `additional.exif` object:

```json
"exif": {
  "aperture": "F2.8",
  "camera": "iPhone 13 Pro",
  "exposure_time": "1/25 s",
  "focal_length": "9.0 mm",
  "iso": "1250",
  "lens": "iPhone 13 Pro back triple camera 9mm f/2.8"
}
```

Values are display-ready strings. Items without EXIF (PNG screenshots, videos) return empty strings for every field, so the client treats an empty value as absent. `aperture` uses uppercase `F` notation (`F2.8`); the UI converts it to `f/2.8`. The client preserves every key the server returns in the cached page even though it currently displays only the six fields above.

### Capture time is a wall-clock value

The observed `time` field must be treated as capture-local wall-clock components encoded in a Unix-shaped integer, not as an absolute instant to convert into the Mac's current timezone. In `firstone.har`, `IMG_3872.PNG` has `time: 1790803838`. Its pixels show `21:30`; decoding the integer with a GMT calendar yields `2026-09-30 21:30:38`, while converting it to the current Tokyo timezone produces the incorrect `2026-10-01 06:30:38` seen in the prototype.

The captured list record contains no timezone or offset. It also has no GPS or address from which one could infer a zone. A richer observed `Browse.Item.get` response requested `exif`, `gps`, `address`, and `geocoding_id`, but its EXIF object contained camera/exposure fields rather than a capture timezone. Do not infer display time from the current Mac timezone, NAS timezone, filename, or geocoded address.

For display and day grouping, extract Gregorian components using GMT so the encoded wall time remains unchanged: a photo recorded at 21:00 in Germany and one recorded at 21:00 in Japan should both display 21:00. This matches the timeline API's GMT-derived day boundaries. The API is undocumented, so retain a focused regression fixture and decode future optional timezone fields defensively if Synology adds them.

Synology represents Live Photos with `type: "live"`. Both `live_type: "photo"`
and `live_type: "live"` have been observed. A bounded read-only probe of the
latter shape used its thumbnail `unit_id` and `cache_key` with the ordinary
`SYNO.Foto.Download` v2 request and returned a 4.35 MB HEIC that decoded at full
resolution. Treat every `type: "live"` item as having a displayable still image;
only `type: "video"` enters the unsupported video-playback path.

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

The [cache design proposal](plans/WIP_CACHING_PLAN.md) refines these recommendations with cached-first startup, category priorities, semantic request keys, and bounded UI state. Its freshness policy supersedes a generic time-based expiration policy.

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

## Library change feed

`SYNO.API.Info` on `cirrus` advertises `SYNO.Foto.Browse.Diff` and `SYNO.FotoTeam.Browse.Diff` with `minVersion` 1 and `maxVersion` 7.

Read-only probes on 2026-10-06 and 2026-10-08 established the mechanics:

- `method=get_version` (v1) returns a cursor pair, for example `{ "diff_version": 1780603, "version_time": 1791277292636 }`; `version_time` is epoch milliseconds.
- `method=get` requires **both** cursor fields, exactly as previously issued. A missing field returns error 120 with `errors.name`, and a mismatched pair (for example the current version with an older time) returns error 700.
- `get` with the current pair returns the (unchanged) cursor plus empty change lists:

```json
{"success": true, "data": {
  "diff_version": 1780603,
  "version_time": 1791277292636,
  "item":  { "modify": [], "delete": [] },
  "album": { "modify": [], "delete": [] }
}}
```

The 2026-10-08 probe reused the exact cursor pair issued two days earlier. The server accepted it and returned a current cursor plus 67 unique `item.modify` records, no item deletions, and no album changes. Repeating the old-cursor request returned the same ordered records and cursor; requesting from the returned cursor produced an empty interval. Each modify record had this sanitized shape:

```json
{
  "id": 0,
  "filename": "<redacted>",
  "filesize": 0,
  "folder_id": 0,
  "indexed_time": 0,
  "owner_user_id": 0,
  "time": 0,
  "type": "photo"
}
```

The feed records contain no `additional`, GPS, or thumbnail fields, so Map repair requires an authoritative item lookup. A v7 `SYNO.Foto.Browse.Item method=get` lookup of all 67 IDs returned every item in exact request order; all base fields shown above matched the Diff records. The response included thumbnail metadata for every item and GPS for 61. All 67 thumbnail unit IDs differed from item IDs, reinforcing that the identities cannot be interchanged. A cursor obtained immediately before the lookup produced an empty item/album interval afterward, demonstrating the proposed quiet-window fence when no concurrent change occurs.

A mixed lookup `[known, missing, known, duplicate-known]` returned `[known, known, duplicate-known]`: the server silently omitted the missing ID, preserved the relative request order of found IDs, and repeated a duplicate. `data` contained only `list`, with no absence or tombstone field. Consequently, omitted lookup IDs are ambiguous and must not be treated as deletions.

A controlled 2026-10-08 sequence established addition and deletion semantics. With a cursor saved before each user action:

- Uploading one identified image produced that new item exactly once under `item.modify`, never under `item.delete`. The interval contained two other unique modifications from unrelated concurrent indexing, so consumers must normalize by ID rather than assume a controlled action is the interval's only entry. Lookup returned the uploaded item, and the fence from the returned cursor was empty.
- Deleting one previously snapshotted image produced its item ID exactly once under `item.delete` as a bare JSON integer, not a record. It did not also appear under `item.modify`. Lookup of that known-deleted ID returned a successful response with an empty `data.list`; the same omission remains ambiguous without the matching Diff tombstone. The interval contained one unrelated modification, and its fence was empty.

Synology Photos 1.9.1-10928 does not expose GPS editing. Its NAS-served `react_bundle.js` dispatches `Browse.Item.set` only for `rotate_action`, `description`, and `time`; GPS appears only in read/detail paths. A single authorized `method=set` probe with `id=[<one snapshotted item>]` and a JSON `gps` value returned error 101, left GPS absent, and produced no target Diff record. Do not infer or implement a GPS write endpoint from `Browse.Item.set`. Testing GPS-only feed coverage requires an external metadata edit and Synology reindex of a disposable file, not a Photos web-app interaction.

The same disposable PNG was then downloaded, given EXIF GPS externally, and overwritten at its existing NAS path through File Station. Synology reindexed it with the same item ID and emitted that ID exactly once under `item.modify`, with no matching deletion. Authoritative lookup returned the written coordinates. The overwrite also changed the capture time and thumbnail cache key while retaining the thumbnail unit ID, so this proves combined GPS/time/thumbnail-revision coverage but does not isolate a GPS-only edit. One unrelated modification shared the interval, and the fence from the returned cursor was empty.

The cursor is opaque and must be stored verbatim; the response echoes the next cursor. `(0, 0)` returned error 700, but this does not distinguish a malformed pair from expiry/reset of a previously valid pair. Still unproven: isolated GPS-only changes/removals, repeated/conflicting changes, truncation or continuation for large intervals, retention beyond the observed two days, and whether `SYNO.FotoTeam` behaves identically for Shared Space. See `docs/plans/WIP_DIFF_CACHE_PLAN.md` for the intended use and remaining evidence gate.

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
4. `SYNO.Foto.Browse.Diff` cursor retention (how old a version/time pair remains valid) and the entry shape inside `modify`/`delete`; the version-pair mechanics are confirmed in the change-feed section above.
5. Sort stability for multiple items with identical `time` values.
6. Session expiry and reauthentication error codes on the Photos endpoints.
7. Whether `m` is preferable to `sm` on high-density displays at the intended grid cell size.

## References

- Synology, DSM Login Web API Guide: <https://kb.synology.com/en-us/DG/DSM_Login_Web_API_Guide/2>
- Unofficial Synology Photos API documentation: <https://github.com/zeichensatz/SynologyPhotosAPI>, vendored as a submodule at `docs/SynologyPhotosAPI/` (run `git submodule update --init docs/SynologyPhotosAPI` if the directory is empty)
- Additional reverse-engineered examples: <https://github.com/N4S4/synology-photos-api>

## Full-size photo transport

A bounded read-only probe on 2026-10-02 confirmed that Cirrus advertises `SYNO.Foto.Download` versions 1–2 at `entry.cgi`. The viewer uses an authenticated GET with `api=SYNO.Foto.Download`, `version=2`, `method=download`, `unit_id=[<thumbnail.unit_id>]`, and the opaque `cache_key`, plus the existing session authentication. The sampled PNG decoded to 1170 × 2532 pixels, matching the item's full-resolution metadata; this is independent of the `sm`/`m`/`xl` thumbnail renditions. A request targets one photo, not an archive of several items.

Keep authentication out of persistent identity and logs. Use unit ID plus cache revision and endpoint version for the full-image cache key. Treat non-image/error responses as failures; never label an enlarged thumbnail as full resolution. The initial viewer preview continues to use the already displayed thumbnail while the full-image resource is fetched and decoded.

## Photo locations and map data

Read-only probes against `cirrus` on 2026-10-06 established the location data path used by the map implementation (`docs/plans/DONE_MAP_PLAN.md`). The Synology mobile map has no desktop web equivalent, so these shapes were discovered directly rather than from a HAR.

### Item GPS

`SYNO.Foto.Browse.Item` `method=list` honors `additional` including `"gps"`. Located items carry:

```json
"additional": {
  "gps": { "latitude": 35.6585805555556, "longitude": 139.745438888889 },
  "address": { "city": "Nakano", "city_id": "中野区", "country": "Japan", "country_id": "日本",
               "county": "", "district": "", "landmark": "", "route": "Ome Kaido",
               "state": "", "town": "", "village": "", "...": "(ids mirror each name)" },
  "thumbnail": { "unit_id": 238257, "cache_key": "238257_1791227407",
                 "sm": "ready", "m": "ready", "xl": "ready", "preview": "broken" }
}
```

Items without a location omit the `gps` key entirely. GPS coverage is partial (~35% in the newest 5,000 personal-library items); there is no way to request only located items.

### Whole-library scans

`method=list` also works without date bounds: `offset`/`limit=1000` walks the personal library newest-first, and an empty or short `list` ends the scan. No `total` is returned. Measured on the ~58,760-item library:

| `additional` | bytes/item | notes |
| --- | ---: | --- |
| `[]` | 191 | base records only |
| `["gps"]` | 214 | 332/1000 newest items located |
| `["gps","thumbnail"]` | 345 | enough for map pins |
| `["gps","thumbnail","resolution","address"]` | 565 | ~10 s per 1000-item page |

Per-page latency was 4.1–4.3 s for 1000 items (`["gps"]`); three concurrent pages completed six pages in 14.8 s. The server generates these pages more slowly than normal bounded section pages, so a full scan takes minutes and should be cached.

### ID batches

`SYNO.Foto.Browse.Item` `method=get` accepts an **`id` array** and returns `data.list` in request order:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Item
api=SYNO.Foto.Browse.Item
version=7
method=get
id=[238257,238258,...]
additional=["thumbnail","resolution","orientation","video_convert","video_meta","address","favorite","exif","gps"]
```

Verified with 100, 500, and 1000 IDs (2.2 s, 7.8 s, 6.7 s). `additional` supports the same fields as `list` (the v5 `get` endpoint rejects some; use v7). One ID must still be wrapped in an array (`id=[12]`). This is the page primitive for client-side filters: one request per page of up to 1000 arbitrary IDs, in order.

The 2026-10-08 Diff probe additionally confirmed missing-ID behavior: a nonexistent ID in a mixed request is omitted without an error or explicit absence marker, while found IDs retain relative request order and duplicate requested IDs produce duplicate rows. Callers therefore cannot distinguish deleted, inaccessible, and otherwise missing items from this response alone.

The client currently does not use this endpoint for map filters. A filtered page instead fetches the complete Personal Library timeline pages covering its day and filters them locally, which keeps the persistent timeline cache behind the filter and avoids a second transport path. This ID-batch primitive remains documented as an available option.

### No server-side spatial filter

- `Browse.Item` on `cirrus` advertises max version 7. `method=list_with_filter` (v1.11) and `list_basic_timeline_info` (v1.9+) return error 104; the community dump's newer methods are not deployed.
- `id`, `geocoding_id`, and `album_id` are silently ignored by `method=list` (requests return the default newest items).
- `SYNO.Foto.Browse.Geocoding` `method=list` returns 735 place entries (`id`, `name`, `first_level`, `second_level`, `country`, `country_id`, `item_count`) but **no coordinates**; `method=get` requires `id=[..]` and returns the same fields. `method=count` returns 735.
- `SYNO.Foto.Browse.Timeline` `method=get_geocoding` (v1/v2) returns only level-name aggregates (`first_level: ""`, `second_level: ["Japan", "Germany", "Romania"]`), not places or coordinates.
- `SYNO.Foto.Search.Search` `method=list_item` accepts a `keyword` and returns items with optional `gps`, but has no documented geographic filter.

Conclusion: a zoomable photo map with per-photo pins must be built client-side from a scan of item locations; the server offers no bounding-box, radius, or coordinate-filtered query. The map plan caches that scan, validates it with the Personal Library timeline fingerprint, and clusters the records locally.

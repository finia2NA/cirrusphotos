# Synology Photos timeline and thumbnail API

## Item deletion

The local-only captures `deleting.har` and `deleting2.har` (single and paired deletion in both spaces) were extended by `phototest` (Personal Space) and real-account (Shared Space) probes on 2026-11-02 using disposable items.

- Request: `POST /webapi/entry.cgi/SYNO.Foto.BackgroundTask.File` (Personal) or `SYNO.FotoTeam.BackgroundTask.File` (Shared), `version=1`, `method=delete`, `item_id=[<IDs>]`, `folder_id=[]`. The response is `data.task_info` with `id`, `status: "waiting"`, `error: 0` and `total`.
- Status: `SYNO.Foto.BackgroundTask.Info` v1 `get_status` with `id=[<task id>]` returns the task with `status: "done"` roughly one second after submission in every probe (1, 2, 3 and 5 items, both spaces). There is no `SYNO.FotoTeam.BackgroundTask.Info`; the Personal API reports both spaces' tasks. `list_user_task` was empty throughout, including while a task was `waiting`, and `Info get` returned error 103.
- `done` is not proof of deletion. `completion` equals the number of requested IDs and `error` stays 0 for already-deleted IDs, nonexistent IDs, mixes of real and nonexistent IDs, and for a Shared Space item sent to the Personal `delete` API. In the last case the item remained present. Only a direct `Browse.Item get` or Diff tombstone shows what was removed; an omitted ID in `get` is ambiguous on its own, so pair it with the task having finished.
- Personal Space `Diff` v1 reported each deleted item exactly once under `item.delete`. A Live Photo (type `live`) produced one tombstone, for the still's ID, and both the HEIC and MOV files left the library. Photo, video and Live Photo batches work in one request. Deleting an album member removed it from the album and decreased the album's `item_count` and cover; `NormalAlbum delete_item` only removes membership and leaves the item in the library.
- On `phototest` the deleted files moved to the share-level `#recycle` (`/Volumes/homes/phototest/#recycle/Photos/…`), preserving folder structure. This is the DSM recycle bin of the shared folder, not a Photos trash. Shared Space recycle behavior was not verified.
- Not captured: restricted-permission deletion, mixed-album deletion across spaces, and deletion of very large batches.

## Personal Space favorites

The viewer and Favorites album captures `favorites.har` and `favoritesAlbum.har` (local only) show that Personal Space item lists include `additional.favorite: true` for favorited items and omit the field for other items. The existing item-list request already asks for `favorite` in its `additional` array. The Favorites album filters normal `Browse.Timeline.get` and `Browse.Item.list` requests with `favorite_only=true`. The capture does not establish that `get_init_timeline` accepts this filter, so the client uses full `get` for Favorites.

The web client changes favorite status with a form-encoded `POST /webapi/entry.cgi/SYNO.Foto.Browse.Item`: `api=SYNO.Foto.Browse.Item`, `version=7`, `method=set_favorite`, `id=[<item IDs>]`, and `favorite=true` or `false`. `favorites.har` captured the one-item form. `favoriteunfavorite2photos.har` confirmed that the endpoint accepts several IDs in one request: the web client sent the same two-item array once with `favorite=true` and once with `favorite=false`, and both returned `{"success":true}`. This endpoint is implemented for Personal Space favorites; the accompanying `SYNO.Foto.Udc.send_event` request is telemetry.

## Tags and ratings

Captured in the local-only `tagsandratings.har` (web client, Personal and Shared Space) and verified with writes on `phototest`; see [capturefindings/tags-and-ratings.md](capturefindings/tags-and-ratings.md). Every call exists as `SYNO.Foto.…` and `SYNO.FotoTeam.…`; tags and their IDs belong to one space.

| Operation | Request | Success response |
| --- | --- | --- |
| Create or fetch a tag | `Browse.GeneralTag create` v2, `name` (JSON string, e.g. `"testtag"`) | `{"tag":{"id":41,"name":"testtag"}}` |
| Add tags | `Browse.Item add_tag` v7, `id=[…]`, `tag=[…]` | `{"error_list":[]}` |
| Remove tags | `Browse.Item remove_tag` v7, same parameters | `{"error_list":[]}` |
| Set rating | `Browse.Item set` v7, `id=[…]`, `rating=0…5` | `{"error_list":[]}` |
| Item tags | `Browse.Item get_tag` v7, `id=[…]` | `{"intersection":[{id,name}],"union":[{id,name}]}` |
| Tag list, count, one tag | `Browse.GeneralTag list` / `count` / `get` v2 | rows `{id,name,item_count}` |
| Typing suggestions | `Browse.GeneralTag suggest` v2, `keyword`, `limit` | `{"list":[{id,name}]}` |

- `additional` accepts `tag` (`[{id,name}]`, empty for none) and `rating` (integer, 0 for unrated) on `Browse.Item list` and `get` in both spaces, and the Diff v7 `list` feed returns them (web client `get` requests ask for `description`, `tag`, … `rating`, … `person`). The web client's list requests omit both fields, so the app asks for them in every page request.
- Duplicate `create` names return the existing tag with success; an empty name is error 120. A tag with no items disappears from `list` and `get`; there is no delete method (`delete` is error 103).
- `rating` outside 0–5 is error 120. Rating several items is one request.
- `add_tag` with an unknown tag ID succeeds with every item ID in `error_list` (bare integers). Unknown item IDs are ignored silently. Repeated adds and removes succeed.
- `Browse.Item list` accepts `general_tag_id` to list one tag's items; the app filters the cached metadata instead.
- Not observed: renaming a tag, per-item tag limits, and rating or tags on the other space's items (rejected or ignored was not tested).

## Thumbnail replacement

Authorized write probes against `cirrus` on 2026-10-09 established that
`SYNO.Foto.Upload.ConvertedFile` version 3, method `upload`, accepts a multipart request for
thumbnail renditions that are already marked `ready`, but does **not** replace those ready
renditions. The request used the photo's `additional.thumbnail.unit_id` (not its Browse item ID)
and file fields `thumb_sm`, `thumb_m`, and `thumb_xl` and returned `{"success":true}` with both
unchanged and modified JPEGs. Uploading unchanged JPEGs was therefore indistinguishable from a
successful replacement. A decisive follow-up uploaded three 90-degree-rotated JPEGs with swapped
pixel dimensions, repeatedly bypassed HTTP caches, and re-read item metadata. For more than 15
seconds, the thumbnail cache key stayed unchanged and all three endpoints continued serving the
original hashes and dimensions. The original download also remained byte-identical. Restoring the
saved thumbnail bytes returned success and the original renditions remained present.

Consequently, this endpoint cannot implement thumbnail-only rotation for already-generated
Photos thumbnails by itself. It must be preceded by the regeneration transition below; a success
response from `ConvertedFile.upload` without that transition is not proof that ready renditions
changed.

```http
POST /webapi/entry.cgi
Content-Type: multipart/form-data

api=SYNO.Foto.Upload.ConvertedFile
version=3
method=upload
unit_id=<additional.thumbnail.unit_id>
thumb_sm=<JPEG>
thumb_m=<JPEG>
thumb_xl=<JPEG>
```

### Confirmed replacement workflow

A second authorized probe against Personal Space item `239345` confirmed the complete workflow
used by the Synology Photos web client:

1. Preserve or produce all three replacement JPEGs (`sm`, `m`, and `xl`).
2. Mark the Browse item for regeneration:

   ```http
   POST /webapi/entry.cgi
   Content-Type: application/x-www-form-urlencoded

   api=SYNO.Foto.RegeneratePreview
   version=1
   method=set_regenerating
   item_id=[<Browse item ID>]
   ```

   The response contains `data.list` entries with `filename`, `type`, and the thumbnail
   `unit_id`. This work is handed directly to Synology's desktop/browser converter and does not
   appear in `SYNO.Foto.Upload.ConvertedFile.list_convert_needed`.
3. Upload the three JPEGs to `SYNO.Foto.Upload.ConvertedFile` as shown above, using the returned
   unit ID.
4. Re-read the item and use its new thumbnail cache key. The upload completed in about one second,
   left the Browse item's orientation and resolution metadata unchanged, and advanced the cache
   key while retaining the same unit ID.

The probe first uploaded unchanged saved renditions, then repeated the sequence with 90-degree
rotated renditions. The NAS served the rotated uploads byte-for-byte at the new cache key, including
the swapped pixel dimensions (`240x320` to `320x240`, `320x427` to `427x320`, and `1280x1707` to
`1707x1280`). Repeating the sequence with the saved baseline JPEGs restored all three exact SHA-256
hashes. The original download remained byte-identical and the item remained at orientation `6` and
resolution `3024x4032`. This establishes that thumbnail-only rotation is viable without changing
the photo or its display-orientation metadata.

If conversion or upload fails after `set_regenerating`, roll the unit out of that state with:

```http
POST /webapi/entry.cgi
Content-Type: application/x-www-form-urlencoded

api=SYNO.Foto.RegeneratePreview
version=1
method=restore_from_regenerating
unit_id=[<thumbnail unit ID>]
```

That recovery request was also probed: it returned success, preserved the current cache key and
renditions, and left the item metadata unchanged. Deleting only this app's cached thumbnails or
metadata cannot replace a NAS rendition; it merely causes another download of whatever bytes the
NAS currently serves. After a successful replacement, the app must adopt the server's new cache key
and invalidate any in-memory image for the old descriptor.

Synology's DSM Login Web API guide defines common error `101` as a request with no `api`, `method`,
or `version` parameter. Photos does not publish endpoint-specific error documentation for
`RegeneratePreview` or `Upload.ConvertedFile`, and observed Photos behavior is broader: the GPS
write probe below returned `101` even though all three routing fields were present, when the
unsupported method parameter was the distinguishing input. Treat `101` from these unofficial
Photos writes as a request-validation failure until the failing endpoint and stage are known, not
as proof that a routing field was literally absent. Rotation diagnostics use the unified Console
subsystem and the `repository.rotations` / `transport.rotations` categories to identify that stage
without logging credentials, session material, cache keys, filenames, URLs, or response bodies.

## Shared Space thumbnail regeneration

The NAS advertises `SYNO.FotoTeam.RegeneratePreview` v1 and
`SYNO.FotoTeam.Upload.ConvertedFile` v3. The application infers the Personal Space
request shapes and recovery workflow for these Shared Space counterparts. API
availability does not establish write behavior; this workflow has not yet been
verified against a disposable Shared Space photo. The application keeps all
reads, writes, recovery and cache updates in the resolved space.

## Personal Space rotation

An authorized clockwise/inverse probe against `cirrus` on 2026-10-09 confirmed the Photos web
client request shape for a normal photo rotation:

```http
POST /webapi/entry.cgi/SYNO.Foto.Browse.Item
Content-Type: application/x-www-form-urlencoded

api=SYNO.Foto.Browse.Item
version=7
method=set
id=[<Browse item ID>]
rotate_action=clockwise
```

`rotate_action=counter_clockwise` performs the inverse. Each call completed in under two seconds
and returned `{"data":{"error_list":[]},"success":true}`. A `Browse.Item.get` lookup reflected
the change in under one second: the EXIF orientation changed, resolution width and height swapped,
the thumbnail unit ID stayed stable, and `additional.thumbnail.cache_key` advanced. All `sm`, `m`,
and `xl` thumbnail bytes changed under the new key. The `SYNO.Foto.Download` original remained
byte-identical, so this operation changes Synology's display orientation and generated renditions,
not the stored original bytes. Applying the inverse restored the original orientation and
resolution and advanced the cache key again. Regenerated thumbnail bytes did not return to their
prior hashes, which is expected because the server regenerated them; the original bytes did.

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

A read-only authentication comparison on 2026-10-25 with the disposable non-admin test account found that `SYNO.API.Auth.login` v6 rejected `session=SynologyPhotos` with error 402 but accepted `session=webui` with otherwise identical parameters. With the latter session, Personal initial/full timelines and the Favorites timeline all succeeded. The captured web client also uses `session=webui` for Auth resume. The native client and login probe therefore use `webui`; the probe logs out the same named session. Error 402 alone must not be described as proof that Photos application permission is missing.

For TOTP accounts, the current six-digit value is passed as `otp_code`. Login probes on 2026-11-06 (non-OTP test account and a TOTP account, `SYNO.API.Auth` v6, `session=webui`) established:

- **Second factor.** A TOTP account without `otp_code` fails with 403 and `error.errors = {token, types: [{type: "otp"}]}`. A correct code succeeds.
- **Trusted device.** Every successful v6 login returns `data.did` (86 characters), even with `enable_device_token=no` and for accounts without two-factor. After a login with `otp_code` and `enable_device_token=yes`, a later login with `device_id=<did>` and no code succeeds. `device_name` need not match and `enable_device_token` may be omitted. An unknown `device_id` falls back to 403. v7 returns the token as `device_id` (with `account` and `ik_message`) instead of `did`.
- **Sessions.** A session is bound to `sid` plus `SynoToken`, not to the connection. A fresh client succeeds with `_sid` or cookie `id=<sid>` together with `X-SYNO-TOKEN`; either without the token fails with 119. Two `webui` sessions of one account coexist. After logout, and for a missing or unknown `sid`, Photos calls fail with 119.

Wrong codes (404) and wrong passwords (400) were not probed, because failed attempts count toward DSM's IP auto-block.

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

A web capture of Live Photo playback (`livephoto.har`, local only) and a bounded read-only probe show `SYNO.Foto.Browse.Unit` v1 `get` with `id_item` as an ID array and `additional` containing `orientation`, `resolution`, `thumbnail`, `video_meta`, and `video_convert`. Its `list` associates the requested `id_item` with a `unit` array containing separate `live_type: "photo"` and `live_type: "video"` members. The video member's thumbnail unit ID and cache key plus an advertised quality address the ordinary `SYNO.Foto.Streaming` v2 `type="unit"` stream. The observed High rendition returned a valid partial MP4 response. The web client suppresses motion when the still's current and original orientation differ.

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

`cache_key` is the server's rendition version. Do not key only by item ID or filename, or parse the key as a freshness timestamp.

A write probe on the disposable account (2026-11-05, Personal Space, `sm`/`m`/`xl`) found:

- Rotation in both directions, `set_regenerating` plus upload, a mount overwrite with new pixels (also with the old mtime kept by `touch -r`) and an EXIF orientation edit all change bytes, ETag and `cache_key` together, with a Diff v7 `item.modify`.
- `ConvertedFile.upload` without `set_regenerating`, and `restore_from_regenerating` alone, change nothing.
- Rating and description edits rewrite the thumbnail files with identical bytes: only the ETag changes.
- The server ignores `cache_key` in the request URL and serves the current file. The ETag is nginx-style `"hex(mtime)-hex(size)"`; `Last-Modified` is the file mtime.
- On rotation, key and bytes switch together within 0.1 s. On a mount overwrite, new bytes are served under the old key for up to about 49 s before the key changes.
- Shared Space edits and a NAS-wide thumbnail rebuild are untested.

Bytes therefore never changed without a new `cache_key`, so the client trusts the key and does not revalidate thumbnails.

Recommended native cache layers:

1. An `NSCache` of decoded display images with a total-cost limit based on decoded bytes (`width × height × 4`), not compressed JPEG size.
2. A disk cache of compressed JPEG data keyed by a hash of the tuple above.
3. In-flight request coalescing so multiple cells asking for the same key share one task.
4. No revalidation of cached thumbnails; a changed `cache_key` is a cache miss.

The disk cache should have an explicit size limit and LRU eviction. Avoid storing session tokens in cache filenames or metadata.

The [cache design proposal](https://github.com/finia2NA/syno/issues/28#issuecomment-6478636441) refines these recommendations with cached-first startup, category priorities, semantic request keys, and bounded UI state. Its freshness policy supersedes a generic time-based expiration policy.

A subsequent read-only Cirrus probe confirmed both ETag and Last-Modified conditional requests return HTTP 304 with no body for an unchanged `sm` thumbnail. See the proposal for the probe's authentication details and limits. Edit-driven behavior is covered by the write probe above.

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

The cursor is opaque and must be stored verbatim; the response echoes the next cursor. `(0, 0)` returned error 700, but this does not distinguish a malformed pair from expiry/reset of a previously valid pair. Still unproven: isolated GPS-only changes/removals, repeated/conflicting changes, truncation or continuation for large intervals, retention beyond the observed two days, and whether `SYNO.FotoTeam` behaves identically for Shared Space. See the [transferred metadata engine plan](https://github.com/finia2NA/syno/issues/20#issuecomment-6478636002) for its design and acceptance context.

### Filesystem runner observations (2026-10-25)

The first unattended `phototest` run stopped during GPS removal, before any bulk,
pagination, deletion, or cursor-aging experiments. A generated JPEG appeared in
`Item.list` after about 61 seconds; GPS gain and change were visible after about
32 seconds each, preserving item ID and capture time while advancing thumbnail
revision. Repeated Diff v1 reads from the exact pre-action pairs returned empty
item/album arrays throughout those stages despite advancing returned cursors.
This is negative evidence for the currently tested request/account/filesystem
path; it does not establish a universal Diff contract or explain the difference
from the earlier overwrite probes.

For GPS removal, local EXIF inspection confirmed no GPS IFD remained, but the
Photos API retained the previous nonzero coordinates. The runner timed out
around 94 seconds; an authoritative ID lookup about five minutes after the
stage began still returned those previous coordinates with the same item ID.
Do not treat an EXIF-only removal as a confirmed server location removal.

Read-only follow-up replay of every saved stage cursor remained empty, including
the initial-add cursor about 12 minutes after its baseline. Version exploration
using that same initial pair returned empty arrays in v2–v5 too. Versions 6 and
7 also returned empty arrays, but add `item.merge` and `item.move` categories;
the existing strict v1 decoder intentionally rejects those shapes. This probe
does not establish v6/v7 cursor-pair compatibility or semantics. Fresh controlled
baselines are needed before relying on those versions.

Private evidence stays local (not synced); sanitized summaries are in `docs/capturefindings/`. The overnight run's report, event log, investigation
and Diff version shapes are kept only in that local evidence. No NAS data was changed during the investigation.

### Overnight filesystem run (2026-10-26)

The completed replacement run established all 5,000 generated additions in a
final authoritative inventory, while original/replayed Diff v1 intervals contained
zero modifications (142-byte response). A 5,000-item deletion eventually returned
all unique tombstones (35,141-byte response). An accepted 3,603-second-old cursor
still omitted its known-present sentinel. This is negative coverage evidence for
the tested `phototest` account/request/filesystem path; the cause and its difference
from earlier account probes are unresolved. Fixtures used 2020 capture dates.

Do not equate every runner failure with an API guarantee failure: page walks
during mutation omitted files not yet unlinked, and duplicate-ID observations
ended some stages before quiet baselines were available. Quiet equal-time order
and 4 MiB completeness were not established. See the
[sanitized results analysis](capturefindings/map-diff-v1-runs.md) for exact
findings, artifact limitations, cleanup outcome and next experiments.

### Focused historical/current-date run (2026-10-26)

The second run used 12 isolated JPEGs, historical/current cohorts and direct-ID
plus folder/list corroboration. In each cohort, Diff v1 omitted all six additions
and all four completed metadata/pixel modifications. All six deletion checks per
cohort passed. Both GPS-removal cases retained prior coordinates through a
10-minute timeout. There were no scan retries or API/transport errors. Current
dates therefore did not restore modification coverage under the tested contract;
the earlier bulk observation artifacts do not explain this result. See the
[focused results](capturefindings/map-diff-v1-runs.md#focused-run-second-runner)
for exact scope and evidence limitations. Account and request/path differences
from the earlier successful probes remain unresolved.

### Official Android request contract (2026-10-26)

A decrypted capture from the official Synology Photos Android 2.4.0 (644) app on a disposable Android 14 Pixel emulator confirms a different protocol from the v1 probes above:

- `SYNO.Foto.Browse.Diff.get_version`, **version 7**, returns the opaque `diff_version` / `version_time` pair.
- `SYNO.Foto.Browse.Item.list_all`, **version 7**, initializes the mobile item cache with `id_before=-1`, `limit=1000`, `geocoding_accept_language=enu`, and `additional=["address","geocoding_id","thumbnail","video_meta","mobile_cache_mtime","gps","orientation","favorite"]`. The captured library initially contained one item; multi-page continuation is not established by this capture.
- `SYNO.Foto.Browse.Diff.list`, **version 7**, sends both cursor values, `geocoding_accept_language=enu`, and `additional=["description","exif","resolution","orientation","address","gps","geocoding_id","thumbnail","tag","video_meta","mobile_cache_mtime","folder","rating","motion_photo","thumb_version","duplicate_hash","favorite"]`.
- The observed quiet response has `item.modify`, `item.delete`, `item.merge`, `item.move`, top-level `similar`, and `has_next=false`, plus the cursor pair. It does **not** use the v1 response's `album` group. Do not apply the v1 decoder to this response or infer continuation behavior from an empty interval.
- A later refresh also issued `Diff.get` **version 7** with `additional=["thumbnail","sharing_info","access_permission","provider_count"]`. From the same saved cursor, that response had no modified items, while `Diff.list` returned the newly indexed fixture with GPS. `get` is not interchangeable with `list` for the observed item-cache update.
- The app also calls `Diff.list_user_event` **version 7** with the cursor pair; its observed quiet response has `list=[]`, `has_next=false`, and a cursor. The role and coverage of this separate feed are not yet established.

A controlled one-photo addition used an owned geotagged JPEG in the disposable filesystem test area. After authoritative indexing and 90 seconds of unchanged metadata, v7 `list` returned the fixture once, replay returned it again, and the returned-cursor fence was empty. v1 `get` from that same pair remained empty. A separate comparison held `additional=["gps","thumbnail"]`, language, account, and cursor constant:

| API version | Method | Result for the indexed addition |
| --- | --- | --- |
| 1 | `get` | Success, zero modifications |
| 1 | `list` | Rejected, error 103 |
| 7 | `get` | Success, zero modifications |
| 7 | `list` | Success, one modification with GPS/thumbnail; `has_next=false` |

The Android Places map visibly displayed that fixture. A subsequent warm startup after emulator restart used Diff v7 `list` without repeating Item `list_all` in its captured startup sequence; only the tiny disposable library was tested. This establishes an actionable method/version distinction and positive coverage for one addition, not bulk, edit, access-change, reset, or continuation completeness. The prior v1 negative results do not establish v7 `list` coverage. Production Diff validation remains disabled pending controlled coverage and completeness tests. The ignored private capture directory is `docs/captures/android-photos-session-2026-10-26/`; request/response JSON is sanitized before writing, with no raw credential-bearing HAR recorded. The initial record is a Mac proxy connectivity probe; subsequent Android requests establish actual app interception.

The separate [third runner](capturefindings/map-diff-v7-mobile.md) (retired) tested the captured v7 item feed with the focused edit matrix and a 5,000-photo batch. It recorded and rejected `has_next=true` instead of guessing continuation, checked candidate `list_all` pagination against owned/folder inventories, and left production validation unchanged. Its completed 2026-10-26 run passed 12 focused additions, eight same-ID edits and 12 deletions, with no observed direct visibility gaps. GPS removal remained inconclusive because the NAS retained coordinates. Bulk responses contained 2,000 modifications with `has_next=true`; continuation and complete bulk coverage remain unproven. All 5,012 known test IDs were absent after cleanup. See [third-runner analysis](capturefindings/map-diff-v7-mobile.md#third-runner).

A subsequent bounded Android refresh returned all 5,012 test tombstones in one terminal v7 `list` response (`has_next=false`). A read-only replay matched both the capture and exact known-ID set, then fenced empty; the final inventory had one original item. Deletion response length must not be assumed to share the observed 2,000-modification page behavior. Modification continuation remains unobserved. The initial product plan now deliberately handles only bounded terminal intervals and rebuilds for partial/large intervals, so another bulk capture is not a prerequisite. See [follow-up evidence](capturefindings/map-diff-v7-mobile.md#bounded-follow-up).

### Annotation and album coverage (2026-11-03)

A probe on the disposable `phototest` account took a fresh `get_version` v7 cursor before each reversible write on one existing photo and then read all three v7 feeds from that cursor. The three feeds share the cursor pair.

| Write | `list` v7 `item.modify` | `get` v7 `album.modify` | `list_user_event` v7 |
| --- | --- | --- | --- |
| `Browse.Item set_favorite` on/off | absent | none | `{"event_type": "favorite_add"/"favorite_delete", "target_id": [id]}` |
| `Browse.Item set rotate_action` | present; `orientation` and `thumb_version` changed | none | none |
| `Browse.Item set description` | present with the new `description` | none | none |
| `NormalAlbum create` with the item, `delete_item` | absent | the album's full summary row (`item_count` changed) | none |

- Each write advanced the cursor, and each feed was terminal (`has_next=false`).
- `list` rows carry `additional.favorite: null` even though `favorite` was requested, so the item feed never establishes favorite state.
- `list_user_event` is the favorite feed. `get` reports which albums changed but not which items; a changed album needs its membership read again.
- A second probe on `phototest` used the mount and item writes:

  | Change | Result |
  | --- | --- |
  | JPEG added to a folder | `list` modification with its `folder_id` |
  | File moved to another folder | same ID, `list` modification with the new `folder_id`; `item.move` stays empty |
  | `Browse.Item set rating` (v7, `{id: [...], rating: n}`) | `list` modification with the new `additional.rating` |
  | `GeneralTag create` (v2, `name`) then `Browse.Item add_tag` / `remove_tag` (v7, `{id: [...], tag: [tag_id]}`) | `list` modification with the new `additional.tag` |
  | Parent folder renamed on the filesystem | no item change and no cursor advance within 2 minutes |
  | Folder removed | `list` tombstone and a `get` `item.delete` |

  The probe left an unused `diffprobe` general tag on `phototest`.
- **Not tested:**
  - People and Subjects changes; `phototest` has no people and one generated subject.
  - Mixing these feeds with more than one change per interval.
- **Folder layout (2026-11-05, `phototest`, Personal Space).** Each change was read from a fresh cursor, waiting up to 150 seconds for the cursor to advance, then through `Diff.get` and `Diff.list` v7:

  | Change | Parent listing | Diff cursor | Diff groups |
  | --- | --- | --- | --- |
  | Empty folder created on the mount | gained the folder | not advanced by the folder | none |
  | Folder with a photo renamed on the mount | renamed | not advanced | none |
  | Empty folder removed on the mount | lost the folder | not advanced | none |
  | `Browse.Folder create` v1 (`target_id`, `name`) | gained the folder | not advanced | none |
  | `Browse.Folder rename` v1 (`id`, `name`) | renamed | not advanced | none |
  | `Browse.Folder delete` v1 (`id: [..]`) of an empty folder | lost the folder | not advanced | none |

  `Browse.Folder move` v1 with `id: [..]` and `target_id` returned error 120. `Diff.get` v7 returns only `item` and `album` groups. Folder `get` and `list` v2 rows carry `id`, `name`, `parent`, `owner_user_id`, `passphrase`, `shared`, `sort_by`, `sort_direction` and `additional`, with no version or modification time. Folder layout therefore cannot be proven from the feeds; only item changes inside folders are reported.
- **Album feed (2026-11-05, `phototest`, Personal Space).** Each write was read from a fresh cursor through `Diff.get` v7, with an untouched control album that never appeared:

  | Change | `album` group | Album summary fields that changed |
  | --- | --- | --- |
  | Create (empty or with items) | `modify` | new album |
  | `NormalAlbum add_item` / `delete_item` | `modify` | `item_count`, `version` (plus `start_time`/`end_time` when the range moves) |
  | `Album set_name` | `modify` | `name`, `version` |
  | `Sharing.Passphrase set_shared` on or off | `modify` | `shared`, `passphrase`, `sharing_info`, `version` |
  | Member rotated | `modify` | `thumbnail`, `version` |
  | Member capture time changed via the mount | `modify` | `start_time`, `end_time`, `thumbnail`, `version` |
  | Member deleted from the library | `modify` | `item_count`, time range, `thumbnail`, `version` |
  | Member description or rating | none | none |
  | Member moved to another folder | none | none |
  | `Album delete` | `delete` (bare ID) | album gone |

  Every change that can alter an album's membership or order also changed its summary `version`, and nothing else did. `Diff.get` `item` groups reported deletions but no modifications; item modifications come from `list`. Not tested: items added by a share recipient (Provider), incoming albums, and Shared Space albums.
- **Live Photo merges (2026-11-04, `phototest`):** three iPhone Live Photos and three JPEGs uploaded by the user produced one terminal `list` interval with the six surviving items in `item.modify` and `item.merge: [id, id, id]`, bare integers, one per Live Photo. The merge IDs fill the gaps between the Live HEIC IDs and appear in neither `modify` nor `delete`; `Browse.Item get` no longer returns them, so each is the video's temporary item that the NAS folded into its still. Surviving stills have type `live` and `additional.live_type: "live"`. `Diff.get` v7 reported the same `modify`, `delete` and `merge`. Synthetic same-basename JPEG/HEIC + MOV pairs without Apple MakerNote content identifiers produced no merge and stayed two items (MOV type `live`). `Browse.Item get` v7 omits unknown or deleted IDs from `list` without an error.
- `SYNO.FotoTeam.Browse.Diff get_version` v7 returned error 801 for `phototest`, which has no Shared Space access.
- **Shared Space (main account, read-only):**
  - What works: `SYNO.FotoTeam.Browse.Diff` v1–v7 is advertised, and v7 `get_version`, `list` and `get` succeed. `list` returns the same `item`/`similar`/`has_next` shape as Personal; `get` returns `item` and `album` groups.
  - What doesn't: `list_user_event` is rejected with error 103, and a fabricated older cursor is rejected with error 700.
  - The Shared Space cursor is independent of the Personal cursor.
  - Whether Shared edits and Shared favorites appear in these feeds is untested, because no writes were made.

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
- `cache_key` is a version identifier. Synology does not publish the contract, but the 2026-11-05 write probe found no edit that changed thumbnail bytes without changing it.

## Open questions for focused probes

Before hardening the production data layer, record or directly test:

1. Timeline behavior when the user setting groups by month instead of day.
2. Normal browser caching with DevTools cache disabling turned off.
3. Thumbnail responses while Synology is still generating a rendition.
4. `SYNO.Foto.Browse.Diff` cursor retention (how old a version/time pair remains valid) and the entry shape inside `modify`/`delete`; the version-pair mechanics are confirmed in the change-feed section above.
5. Sort stability for multiple items with identical `time` values.
6. Session expiry and reauthentication error codes on the Photos endpoints.
7. Whether `m` is preferable to `sm` on high-density displays at the intended grid cell size.

## Uploads

Uploads are multipart POSTs to `SYNO.Foto.Upload.Item` v8 (`SYNO.FotoTeam.Upload.Item` for Shared Space). The destination is chosen by method and fields:

| Destination | Method | Destination fields |
| --- | --- | --- |
| Timeline (either space) | `upload` | `uploadDestination="timeline"`, `folder=["PhotoLibrary"]` |
| Owned album (Personal endpoint) | `upload` | `album_id`, `folder=["PhotoLibrary"]` |
| Folder | `upload_to_folder` | `target_folder_id` only |

Every request carries `duplicate="ignore"`, `name` (JSON string), `mtime` (epoch seconds) and the file part. The folder form was captured from the web app (no `folder`, no `uploadDestination`, no client-generated thumbnails); its Shared Space form is unverified. A successful response names the item and an `action` of `new` or `ignore` (an already-present file). The NAS indexes asynchronously and generates thumbnails after the transfer, so an immediate listing can lack the item or show its thumbnails as not ready. Poll `Browse.Item` `get` for the uploaded IDs until every thumbnail is ready.

## Album sharing and incoming albums

Detailed request shapes, evidence and open points are in the [album-sharing capture summary](capturefindings/album-sharing.md). The facts the client depends on:

- Sharing is an attribute of an owned normal album. `Sharing.Passphrase` v1 `set_shared` and `update` manage access to the same album ID; the album stays `type: normal` in `Browse.Album` v4 `list` (`category: normal`), and `additional.sharing_info` carries the sharing metadata.
- `permission` updates are incremental. Adding public view access leaves an existing named-user downloader in place. Public access is written as a `member` of `type: public` but read back as `privacy_type`. Password and expiry are fields of the same `update`: an empty JSON string clears the password, expiry `0` clears the expiry, and `action: delete` revokes one grant. `set_shared(enabled: false)` clears grants and the link in the readback but can leave a nested sharing reference, so use the `shared` flag and effective permissions.
- Two ID spaces: permission writes use DSM UIDs; `UserInfo.me.id` and permission `user_id` use Photos internal IDs.
- Public-link visitors use `/mo/sharing/webapi` with `Core.Sharing.Login` and passphrase-scoped reads. Signed-in recipients use the normal `/webapi` endpoint with passphrase-scoped `Album` get and `Item` list; both keep the owner's album and item IDs. `Sharing.Passphrase.get_permission` reports effective view, download, manage, own and upload capability.
- Incoming albums are listed with `Sharing.Misc` `list_shared_with_me_album` (v2). An album identity is the owner ID plus the album ID; the sharing reference is what selects other-owned content (a get by album ID alone returns nothing).
- A Provider (role `upload`) adds a personal photo with `NormalAlbum` `add_item` carrying the sharing reference and item IDs. Recipient downloads use `Download` v2 with the passphrase; the single-original form is verified, compressed and multi-item forms are not.

## Collection indexes, folders and Recently Added

- **People**: `Browse.Person` v1 `count`/`list` with `show_more=true`, `show_hidden=false` and `additional=["thumbnail"]`, 100 per page. `suggest` is v3 (`name_prefix`, limit 10); rename is v1 `set`; merge is v2 `merge`. A person's photos use the ordinary Timeline v6 and Item v7 requests with `person_id`.
- **Subjects**: `Browse.Concept` v2 with `show_hidden=false`; photos use `concept_id`.
- **Tags**: `Browse.GeneralTag` v2; photos use `general_tag_id`.
- **Folders**: `Browse.Folder` v2 `get` resolves the root, `list` enumerates children; direct items are `Browse.Item` v7 `list` with `folder_id`. Folder root and child enumeration are captured for Shared Space; pagination and restricted-permission behavior are not.
- **Recently Added**: `Browse.RecentlyAdded` v6 `get_timeline` and `list`. Day membership follows `indexed_time` (milliseconds); the item's `time` stays the capture time. The server decides the window; its expiry boundary is not known. There is no verified Shared Space form.
- All indexes return a count; the client reads it before and after paging and rejects the result if it changed or if IDs repeat.

## Video and Live Photo requests

Item pages list the converted renditions in `additional.video_convert` (`mobile`, `low`, `medium`, `high`, `orig_h264`). `SYNO.Foto.Streaming` v2 serves converted ranges and `SYNO.Foto.Download` v2 serves the stored original, both as `206` responses with a `Content-Range`. `SYNO.Foto.Browse.Unit` v1 `get` for an item returns its Live Photo members; the motion video is the single video unit. Synology's display `orientation` can differ from the original's, and the web client suppresses motion in that case. See the [video streaming summary](capturefindings/video-streaming.md) for the range behavior.

## Shared Space: captured versus inferred

- Captured (web app, Shared Space account): Library and Favorites timelines (`FotoTeam.Browse.Timeline` v6, `Browse.Item` v7, `/t/` thumbnails), original stills (`FotoTeam.Download` v2 with unit IDs), explicit downloads (item IDs), original video ranges (item ID kept separately from the unit ID), favorite writes, counter-clockwise rotation, folder root and child listing, and adding Shared Space items to a Personal album (`NormalAlbum` `add_item`/`create` by item ID alone, with no space parameter).
- Inferred from the matching Personal contract and covered only by fixtures: People, Subjects and Tags timelines (same constraint fields), `FotoTeam.Streaming` v2, `FotoTeam.Browse.Unit` v1, clockwise rotation, favorite removal, and thumbnail regeneration (see above).
- Not available: Shared Recently Added, a Shared Favorites change feed (`list_user_event` is read only for Personal Space), and any verified Shared Space contribution to an incoming album.
- Restricted-account behavior has not been observed.

## Album member origin

An album can contain items from either space, and neither numeric item IDs nor `owner_user_id` identify a member's space (the observed `owner_user_id` of zero is not a general rule). Album reads use `Browse.Item` v7 `get` with `album_id`; stills use `Download` v2 `unit_id` with `album_id`, even for Shared Space members; thumbnails try `/p/` and then `/t/` contextually. The only available discriminator is a metadata match against `Item` get results from both spaces (ID, owner, capture time, type, Live Photo type, filename, size and thumbnail unit and revision). A targeted mixed-album capture would replace this heuristic.

## References

- Synology, DSM Login Web API Guide: <https://kb.synology.com/en-us/DG/DSM_Login_Web_API_Guide/2>
- Unofficial Synology Photos API documentation: <https://github.com/zeichensatz/SynologyPhotosAPI>, vendored as a submodule at `docs/SynologyPhotosAPI/` (run `git submodule update --init docs/SynologyPhotosAPI` if the directory is empty)
- Additional reverse-engineered examples: <https://github.com/N4S4/synology-photos-api>

## Full-size photo transport

A bounded read-only probe on 2026-10-02 confirmed that Cirrus advertises `SYNO.Foto.Download` versions 1–2 at `entry.cgi`. The viewer uses an authenticated GET with `api=SYNO.Foto.Download`, `version=2`, `method=download`, `unit_id=[<thumbnail.unit_id>]`, and the opaque `cache_key`, plus the existing session authentication. The sampled PNG decoded to 1170 × 2532 pixels, matching the item's full-resolution metadata; this is independent of the `sm`/`m`/`xl` thumbnail renditions. A request targets one photo, not an archive of several items.

Keep authentication out of persistent identity and logs. Use unit ID plus cache revision and endpoint version for the full-image cache key. Treat non-image/error responses as failures; never label an enlarged thumbnail as full resolution. The initial viewer preview continues to use the already displayed thumbnail while the full-image resource is fetched and decoded.

### Explicit downloads

The local-only web-app capture `downloads.har` shows a separate form-encoded POST to `SYNO.Foto.Download` v2, method `download`, with `force_download=true`, `item_id` as a JSON array of item IDs, and `download_type` as the JSON string `"source"` or `"optimized_jpeg"`. A single item returned an attachment named for the original or a server-generated compressed filename. Two items returned a server-generated `download.zip` for both modes; the archive responses did not advertise a content length in this capture. The capture does not establish the maximum number of IDs, compressed-mode fallback response, or error response behavior. A separate read-only check found that the original item download for one Live Photo was a ZIP rather than the still returned by the unit-based viewer request. Preserve the returned filename and reject error payloads rather than assuming that compressed mode always produces a JPEG.

## Photo locations and map data

Read-only probes against `cirrus` on 2026-10-06 established the location data path used by the map implementation ([completed Map plan](https://github.com/finia2NA/syno/issues/46)). The Synology mobile map has no desktop web equivalent, so these shapes were discovered directly rather than from a HAR.

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

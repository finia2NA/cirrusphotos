# Video playback support

Status: in progress. The initial playback slice is implemented: advertised-quality resolution, converted/original ranged transport, lowest-priority segment caching, the Settings default, ordinary-video viewer opening, and the native player bridge. Read-only protocol probes against `cirrus` captured the item conversion shape plus working initial and nonzero ranged requests for converted and stored-original videos; see [the sanitized capture](../captures/video-streaming-probe-2026-10-09.md). Manual playback acceptance and the remaining enhancements in this plan are still open.

## Outcome

Video items should open in the existing in-window viewer, show their poster immediately, and begin native macOS playback without downloading the original file first. The user can choose a default playback-quality policy in Settings. Playback should prefer a NAS-converted rendition for quick startup when the policy permits it, while retaining an explicit Original option.

Video data uses the existing total disk budget but is less valuable than every photo rendition. Only the current video's demanded byte ranges are cached; there is no adjacent-video prefetch or whole-library video warming. Previously cached ranges remain playable offline, but a partly cached video is not presented as fully available offline.

This slice covers ordinary items whose `type == "video"` in Personal Library, Favorites, albums, and map-filter collections. It does not animate the video component of Live Photos, add background playback, picture-in-picture, AirPlay, editing, downloads, or video transcoding performed by the Mac.

## Evidence and required verification

Captured evidence:

- `cirrus` reports `SYNO.Foto.Streaming` through `SYNO.API.Info`, with API versions 1 through 2 and `entry.cgi` as its path.
- Synology Photos' own UI strings contain Original, High, Medium, Low, and Mobile video-quality labels.
- Item pages request and decode `video_convert` and `video_meta`. A live response shows `video_convert` is an array of `{quality, metadata}` objects and that an empty array represents no advertised conversion.
- Among the 1,000 newest videos, the observed advertised sets were High (765), `orig_h264` (170), none (32), High + `orig_h264` (17), and Medium + `orig_h264` (16). Low and Mobile were not advertised in that sample.
- A GET to `SYNO.Foto.Streaming` v2 with item unit ID, `type="unit"`, cache key, and an advertised `quality="high"` honored `Range: bytes=0-1023` with `206`, an exact `Content-Range`, `video/mp4`, an MP4 `ftyp` prefix, ETag, and Last-Modified.
- Asking for an unadvertised converted quality returned 404. Asking the streaming endpoint for `quality="original"` returned API error 120 (`quality`/`condition`). Quality fallback must therefore happen in the client, and the raw original must use the download endpoint.
- `SYNO.Foto.Download` v2 honored both initial and nonzero 1 KiB video ranges with `206`, exact `Content-Range`, `video/mp4`, ETag, and Last-Modified. It can back arbitrary seeking for the stored Original.
- The existing authenticated URL session has a host-scoped certificate exception. A raw authenticated playback URL handed directly to `AVPlayer` would bypass that session and cannot be assumed to pass TLS or session authentication.

The capture is sufficient to specify the item model, converted/original transport, range cache, and quality resolver without a user-provided HAR. During transport integration, repeat a bounded request for advertised Medium and `orig_h264` items as coverage. Record sanitized observed fixtures in `Tests/SynologyAPITests/Fixtures/`. If later observations contradict the capture, update this plan before adding compatibility guesses.

## Product decisions

### Quality policy

Add a Settings picker named **Default video quality** with:

- **Automatic** (default): target High and apply the same closest-available rule as an explicit High choice. Use Original only when no compatible converted rendition is advertised. This prioritizes quick startup and avoids making the largest source file the normal remote path.
- **Original**: request the stored file without a quality downgrade. Report an actionable playback error if AVFoundation cannot decode it; do not silently switch quality after an explicit Original choice.
- **High**, **Medium**, and **Low**: target that converted quality. If it is unavailable, select the closest advertised converted rendition. At equal distance, choose the lower rendition rather than the higher one. Use Original only when no compatible converted rendition is advertised.
- **Mobile**: target the smallest converted quality, moving upward only when Mobile is not advertised.

Use the ordered server-quality ladder `mobile < low < medium < high < orig_h264`. `orig_h264` is an observed streaming rendition and is not the stored Original. Keep `orig_h264` internal; it is the next step above High. The stored Original is a separate explicit policy/resource and is not part of converted-distance selection.

Resolve a target only from the current item's `video_convert` array:

1. Return the exact advertised target when present.
2. Otherwise minimize absolute distance on the ladder.
3. For equal distances, prefer the lower-ranked candidate.
4. If the array has no recognized compatible rendition, use the stored Original.

Examples: Medium with Low + High chooses Low; High with Medium + `orig_h264` chooses Medium; Medium with High only chooses High; Low with Medium only chooses Medium. Never send the requested label first and wait for the NAS to fall back—the live endpoint returned 404 for unadvertised labels.

Do not infer pixel dimensions or bitrates from the labels; display Synology's semantic user-facing quality name plus supplied dimensions when useful. Present `orig_h264` as a localized “Original resolution (compatible)” or another label confirmed during UI implementation, never as the raw Original.

The setting is a current-format preference, not part of navigation restoration. Store the enum raw value in `UserDefaults`; discard an unknown value and return to Automatic, consistent with the pre-1.0 compatibility policy.

The viewer toolbar should show the effective rendition (for example, `High · Playing`) and offer a per-video quality menu. A per-video change restarts the asset at the closest valid playback time and does not change the default. Do not add an undocumented keyboard shortcut. If playback shortcuts are added, define them as named commands in `LibraryCommands` first.

### Playback behavior

- Remove the browser guards that reject `type == "video"`; the same Space, double-click, accessibility Open action, and single-selection command should open photos and videos.
- Keep the clicked thumbnail/poster visible during metadata resolution and until the first video frame is ready.
- Use native AVFoundation playback controls, audio routing, captions/tracks when exposed, scrubbing, and full accessibility semantics. Do not build a custom media engine.
- Keep left/right arrows as previous/next library-item navigation when the viewer canvas owns focus. Seeking remains available through native playback controls. Space remains the existing menu-backed Close Viewer command for this slice; playback is controlled through the visible native control. Revisit Space only as a separate, menu-backed interaction decision.
- Pause and release the player when navigating, closing the viewer, changing collections, invalidating the viewer, or losing the current selection generation. A late player/error callback must not update the next item.
- Preserve poster and cached-range usefulness if network validation or continuation fails. Show whether playback stopped because the remainder is not cached.
- Do not autoplay on open. The native play action starts network demand. This prevents an accidental open or rapid arrow navigation from consuming large transfers.
- Do not prefetch adjacent video bytes. Continue prefetching photo originals only under the existing policy.

### Cache policy

Use one cache budget and one LRU. Do not create a separate unbounded AVFoundation or `URLCache` store.

The implementation uses fixed-size persistent 64 KiB video segments keyed by account namespace, video resource revision, effective quality, and byte-range index. This is intentionally much smaller than the original 4 MiB proposal: an observed 1 MiB response took 171.98 seconds, and buffered `URLSession.data(for:)` withheld that range from AVFoundation until completion, causing its resource loader to time out. Coalesce overlapping requests so AVFoundation, a retry, and another viewer do not download the same range twice.

Retention order becomes highest to lowest:

1. active timeline;
2. location index;
3. metadata page;
4. configured photo thumbnail;
5. smaller fallback photo thumbnail;
6. full-size photo;
7. optional large photo preview;
8. video playback segment.

The current video's segments receive an in-use lease so budget trimming cannot delete bytes underneath active playback. The lease changes eviction eligibility, not persistent priority, and is removed on pause/close/navigation. New video segments should stop being admitted when the budget cannot retain them after honoring higher classes; playback may continue without persistence. Metadata-only clear preserves video bytes and validators, while full clear removes them and cancels range work.

Validation follows the existing cached-first contract:

- Serve a cached requested range immediately.
- On first network demand for that video/rendition in a run, validate the resource descriptor using the observed supported mechanism (conditional range, `HEAD`, or refreshed manifest). Do not invent `HEAD` if the endpoint does not support it.
- If the revision or validator changed, atomically invalidate every segment for that rendition before publishing new bytes.
- If validation fails, continue from cached contiguous bytes and report the failure without deleting them.
- Never treat a validation marker as proof that an absent range is cached.

If the verified endpoint is HLS rather than a progressive byte-range resource, retain the same policy but key cached media by the stable rendition plus canonical manifest-relative segment identity. Refresh the manifest through the authenticated transport and never persist authenticated absolute URLs. If segment identity is not stable across sessions, make video caching session-only for the first release and document that limitation rather than risking incorrect media assembly.

Alternative policies considered:

- **Stream only:** simplest and acceptable as a first checkpoint, but gives no offline replay and repeats data after reopening. Keep as a feature flag/fallback while the segment cache is being verified.
- **Cache the whole converted file after playback:** simpler persistence, but wastes bandwidth when the user watches only part of a large video and usually cannot accelerate an early seek.
- **Cache original files:** useful for explicit offline download, but consumes the budget quickly and does not solve unsupported codecs or fast startup. Defer this to an explicit “Download for Offline” feature with user-selected scope.
- **Rely on `URLCache`/`AVAssetCache`:** rejected as the primary cache because ownership, authentication, eviction order, validator behavior, and partial progressive-media coverage would not match the repository contract.

## Architecture and interfaces

### 1. Decode observed video capabilities

Modify `Sources/SynologyAPI/PhotoModels.swift`:

- Add `VideoConversion`/`VideoRendition` Codable value types matching only the captured response shapes.
- Add `videoConvert` to `PhotoItem.Additional` and its coding keys.
- Add a `VideoResource` value that contains stable item/unit identity, cache revision, original filename when needed, and the available rendition descriptors. Its initializer must fail when required observed identifiers are absent.
- Keep `VideoMetadata.duration` as the UI duration source; add codec, dimensions, bitrate, rotation, or container fields only when observed and useful for playback selection.

Update `PhotoItem.withFavorite` so constructing `Additional` preserves the new field shape. Add decoding fixtures for ready, processing, failed, missing, numeric/string variations actually observed, and unknown future keys. Unknown conversion states should decode as unavailable, not as ready.

### 2. Add ranged streaming to the transport

Modify `Sources/SynologyAPI/PhotosTransport.swift` and `Sources/SynologyAPI/SynologyClient.swift`:

- Add a capability/descriptor request that resolves `VideoQualityPolicy` to an observed available rendition.
- Add a bounded ranged-media operation returning status, bytes, total length/content range, MIME type, validators, and the effective rendition. Require `206` for partial responses when the endpoint supports ranges; reject malformed or oversized responses.
- Keep session cookies, `_sid`, `SynoToken`, certificate handling, redirects, and any URL refresh inside `SynologyClient`.
- Never expose or log an authenticated URL. Diagnostics may include item/unit ID, requested/effective semantic quality, range bounds, status, byte count, cache outcome, and sanitized error.
- Make cancellation close the underlying URLSession work promptly. Use a separate video transfer gate so playback cannot occupy the two photo-original slots or six thumbnail slots.

Add `SynologyDiagnostics.videoTransport` and `videoPlayback` categories. Extend every `PhotosTransport` fake explicitly; do not add a default protocol implementation that could hide an unsupported path.

### 3. Add repository range coordination and persistence

Create:

- `Sources/PhotoCache/CachedPhotosRepository+Videos.swift` for cached-first range resolution, shared jobs, validation, priority promotion, reset handling, and leases;
- `Sources/PhotoCache/VideoRangeCache.swift` for segment math, contiguous-range assembly, and pure request planning;
- `Sources/PhotoCache/VideoTransferGate.swift` for a bounded visible-only lane (start with two concurrent range requests for the active video, no speculative lane);
- `Sources/PhotoCache/VideoPlaybackSource.swift` as the consumer-facing actor that owns one item/rendition session and exposes content information plus byte ranges without exposing credentials.

Modify:

- `CacheKey.swift`: add stable descriptor and segment keys including namespace, revision, effective quality, and segment index.
- `DiskCache.swift`: add `videoDescriptor` and `videoSegment` kinds and the current-schema tables/columns needed to delete all segments for one rendition atomically. Bump the schema and recreate the cache; do not migrate the alpha schema.
- `CachePriorityPolicy.swift`: add `videoPlayback` below `optionalThumbnail`.
- `RepositoryState.swift`: add shared video range jobs, descriptor validation jobs, and active leases to `RepositoryImageWork` or rename it to `RepositoryMediaWork` if that produces a clearer single owner. Do not create a second repository actor.
- `CachedPhotosRepository+CacheReset.swift`: metadata clear leaves video cache/jobs intact under the same bounded survival rule as admitted image transfers; full clear cancels them and deletes their files.

`VideoPlaybackSource` should give the app an opaque custom-scheme asset URL plus an `AVAssetResourceLoaderDelegate` bridge, or an equivalent verified AVFoundation integration. The delegate translates loading requests into async repository range calls and supplies content type, length, and byte-range support. This keeps AVFoundation behind the authenticated session and its certificate policy. Delegate callbacks must carry viewer selection generation and rendition identity so stale callbacks cannot publish.

Do not buffer an entire video in `Data`. Assemble only the requested response range, cap each network request, stream bytes to disk, and keep memory bounded to a small number of segments. If the observed endpoint cannot satisfy byte ranges, add an explicit capped sequential-stream path and do not label arbitrary seeking as supported.

### 4. Extend viewer state without turning it into an image-only model

Modify `PhotoViewerState.swift`, `ViewerImageWork.swift`, `PhotoViewerSession.swift`, `PhotoViewerSession+Assets.swift`, and `PhotoViewerSession+Prefetch.swift`:

- Rename image-specific state that now owns both media types where necessary (`ViewerMediaWork`, `mediaStatus`), while keeping photo fields typed rather than overloading video data into `fullImageData`.
- Add video state carrying the opaque playback source identity, poster status, requested/effective quality, cached coverage, buffering/ready/failure state, and duration.
- In `startAssetsForCurrentMetadata`, branch on the item's media type. Videos load the existing thumbnail poster immediately, resolve a video descriptor only after verified metadata, and create no full-image job. Photos keep the existing path unchanged.
- Cancel the current video source on navigation and close. Do not retain adjacent video sources or segments in the viewer session.
- `retry()` retries the current video descriptor/range path without discarding cached segments or the poster.
- Keep favorite mutation, metadata windows, immutable playlist navigation, map filters, albums, and collection invalidation behavior shared between photos and videos.

Preserve the rule that provisional page metadata can read cached media but cannot authorize a new authenticated network transfer.

### 5. Add the native player presentation

Create `Sources/SynoTimelineApp/VideoPlayerView.swift` as an AppKit-backed SwiftUI representable using `AVPlayerView`/`AVPlayerLayer` and native controls. It should:

- create an `AVURLAsset` backed by the repository resource-loader bridge;
- display the existing decoded thumbnail as the poster until the first frame is ready;
- observe item status, buffering, duration, end, and errors with cancellable observation tokens;
- publish only when selection generation and rendition still match;
- pause and detach the player on navigation, close, quality change, or view removal;
- restore the closest valid time after a per-video quality switch;
- honor Reduce Motion for the existing open/close transition and avoid animating player content independently.

Modify `PhotoViewerView.swift` to choose `PhotoViewerCanvas` for photos and `VideoPlayerView` for videos, replacing the unsupported-video panel with buffering, retry, conversion-processing, offline-partial, and format errors. Modify `PhotoViewerPresentation.swift` to own the player presentation state separately from image decoding and to expose effective quality/status for `ViewerToolbarTitle`.

Modify `PhotoViewerCanvasController` or introduce a media-neutral viewer controller so focus, Back/Escape, collapse animation, and previous/next navigation remain coherent for either child. Do not force video through `PhotoViewportTransform` or `FullImageDecoder`.

Modify `LibraryBrowserView.swift` to remove both `type != "video"` open restrictions. Update `ThumbnailCell.swift` accessibility text from “Open photo” to “Open video” for videos while retaining the duration badge.

### 6. Settings and commands

Add `VideoQualityPolicy` in `SynologyAPI` (wire-independent semantic cases) or `PhotoCache` if resolution policy requires cache knowledge. In `LibraryModel.swift`, add the persisted default with strict fallback to Automatic. Pass it through `AppShellView.openPhoto` into `PhotoViewerPresentation` and `PhotoViewerSession`.

Add the picker and concise explanatory text to `CacheSettingsView.swift`. The text should state that converted qualities start faster and use less bandwidth, while Original may be slower or unsupported by the Mac. The existing maximum-cache control remains the only budget control.

Add a toolbar quality menu only for videos. If a play/pause keyboard shortcut is later selected, add `Play/Pause Video` to `LibraryCommands` and route it only while a video viewer is active. No view-only shortcut may be introduced.

## Delivery sequence

Each checkpoint should build and have focused tests before continuing:

1. **Protocol evidence:** use the existing sanitized capture, add its response shapes as fixtures, and repeat bounded Medium/`orig_h264` requests as integration coverage. No user HAR is required for the currently observed contract.
2. **Transport spike:** play one known video through an authenticated, certificate-safe AVFoundation resource loader with no persistent video cache. Verify startup, seek, cancellation, and every quality on `cirrus`. Delete spike-only code or turn it into the typed transport path.
3. **Models and transport:** land strict observed decoding, semantic quality selection, bounded ranged responses, diagnostics, and fake transports.
4. **Cache:** land descriptor/segment persistence, shared range jobs, validator invalidation, leases, eviction rank, reset behavior, and cache usage accounting.
5. **Viewer session:** add the typed video state and cancellation rules while leaving photo behavior unchanged.
6. **UI:** enable opening, add the native player/poster/error states, toolbar effective-quality menu, Settings default, accessibility labels, and media-neutral focus/transition behavior.
7. **Documentation and final verification:** update `docs/PROJECT.md`, `docs/ARCHITECTURE.md`, `docs/plans/WIP_CACHING_PLAN.md`, and the root `AGENTS.md` overview to describe only implemented behavior. Mark this plan done only after automated and manual acceptance passes.

## Automated verification

### `SynologyAPITests`

- Decode every sanitized `video_convert` and `video_meta` fixture; missing/unknown states fail closed.
- Quality resolution is deterministic for Automatic and each explicit policy, chooses the nearest advertised rank, and chooses down on an equal-distance tie.
- Request encoding matches the captured v2 contract exactly.
- Range responses accept valid `206`/`Content-Range`, reject mismatched bounds, full-body surprises, invalid content types, empty bodies, redirects outside the allowed host, and payloads over the cap.
- Authentication material and URLs never appear in diagnostics or error strings.

### `PhotoCacheTests`

- Segment planning handles aligned, unaligned, overlapping, first, final, and beyond-end requests without gaps or duplicate bytes.
- Concurrent overlapping readers share transfers; cancellation of one subscriber does not cancel another.
- Cached bytes arrive before validation; failed validation keeps them usable; changed validators atomically discard old rendition segments.
- Original and each converted quality have isolated keys. Two item revisions cannot share segments.
- Video segments evict before optional previews and all other photo resources; active leases prevent mid-playback removal and are released on stop.
- No adjacent video range request is issued. Photo adjacent-prefetch tests remain unchanged.
- Metadata clear preserves admitted/cached video work; full clear cancels jobs and removes descriptor/segment files.
- Offline requests succeed only for fully covered demanded ranges and report the first missing range accurately.
- Memory and pending-job counts remain bounded during rapid seeks and viewer navigation.

### `SynoTimelineAppTests`

- A video is openable by pointer, Space command, and accessibility action.
- Poster, buffering, playing, paused, failed, conversion-processing, and offline-partial states render deterministically.
- Photo/video navigation tears down the previous media path and stale callbacks cannot replace current state.
- Per-video quality changes preserve time, do not mutate the default, and show the effective fallback.
- The Settings preference rejects unknown persisted values and round-trips valid values.
- Viewer focus retains Escape/Back and previous/next behavior; any new shortcut is backed by a named menu command.
- Favorite and Info-panel behavior remains available for the active video.

Run `swift test` after the focused suites. The opt-in live test must use a small known converted video and bounded ranges; it must not download an entire original during routine CI.

## Manual acceptance on `cirrus`

- Open short and long H.264 and HEVC videos, plus MOV and MP4 containers. Confirm poster-first display, correct orientation/aspect ratio, audio, duration, scrubber, and end behavior.
- Compare Automatic, Original, High, Medium, Low, and Mobile startup time and network bytes. Confirm the toolbar reports the actual fallback rendition and unavailable requested quality.
- Seek repeatedly and watch the same interval again; confirm cached intervals avoid repeat transfers and memory stays bounded.
- Throttle the network and confirm a converted quality begins substantially earlier than Original where the NAS provides it.
- Disconnect after caching selected intervals. Confirm those intervals play, missing intervals report offline status, and no item is falsely marked fully offline-ready.
- Navigate rapidly photo → video → video → photo, close during buffering, change quality during playback, clear metadata during playback, and full-clear during playback. Confirm no stale frame, audio, crash, or orphan transfer remains.
- Fill the cache past budget and confirm video segments are evicted before photo thumbnails, previews, and originals, except for the currently leased video.
- Confirm favorites, Info, albums, Favorites, map-filter collections, restoration to the browser position, and viewer open/close transitions still work.

## Completion criteria

The feature is complete when the observed Synology contract is captured in tests, video items use the shared viewer/navigation path, converted quality produces measurably faster startup than whole-original download on `cirrus`, all network access stays inside the authenticated transport, segment caching is bounded and lowest priority, the quality default and effective fallback are visible, photo behavior has no regressions, and the project/architecture/cache documentation describes the implemented result rather than this proposal.

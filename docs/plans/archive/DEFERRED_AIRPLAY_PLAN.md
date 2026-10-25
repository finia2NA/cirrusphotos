# AirPlay photo presentation

Status: deferred and investigation closed at the user's request on 2026-10-25. No product implementation was made. Discovery and pairing worked, but none of the tested direct-media paths displayed a photo on the intended LG TV; native-resolution output was not established. This records the investigation and the original conditional design, not an active implementation task.

## Final disposition and cleanup — 2026-10-25

The feature is set aside. Do not resume hardware testing or implement the proposed integration without a new user request. The feasibility table below preserves what was tried, what failed, and what remains unknown; failure on this receiver does not prove AirPlay photo presentation impossible on all receivers.

- **Worked:** receiver discovery, native PIN entry and authenticated pairing; manually connected mirroring and extended-display output, including a held test image after detaching the Mac preview.
- **Failed:** native AVPlayer playback of generated H.264 clips (including looping), Apple's reference HLS stream, and the same generated clip in QuickTime. The TV entered its AirPlay screen but did not display the media. Authenticated legacy JPEG delivery returned 501; modern playback returned 404; the experimental CarPlay-derived control stream returned 400.
- **Rejected as a product approach:** manually connecting an extended display, placing a second window on the TV, or accepting a fixed 1080p substitute. These tests demonstrated connectivity only.
- **Unresolved:** a compatible app-initiated photo transport and actual TV-resolution output. Long-term hold, photo replacement, stop behavior, and zoom following were not validated for a direct sender. Zoom was optional and was not the reason to stop.
- **iOS comparison:** Synology Photos was started through Control Center Screen Mirroring, so it did not supply a working direct-media flow to reproduce on macOS. Separate UIKit external-display content is plausible; Synology's exact implementation was not established.

Removed the disposable `tools/AirPlayPhotoProbe/` project, its app bundle, virtual environment, downloaded protocol sources, generated media, and probe-specific temporary files. No probe processes were running at cleanup. Pairing keys were never persisted by the probe; receiver-side pairing records, if any, were not changed. No AirPlay dependencies or integration were added to the production app. The remaining sections preserve the original proposal for reference only; their instructions are not work to execute now.

Protocol references inspected during investigation:

- [pyatv](https://github.com/postlund/pyatv), with version 0.18.0 used by the probe, supplied pairing and the tested media-session implementation.
- [dart_cast hardware investigation](https://github.com/abdelaziz-mahdy/dart_cast/blob/main/doc/specs/2026-07-25-airplay-hardware-results.md) documented similar modern-receiver failures; it did not establish a working LG sender.
- [DiPlay receiver source](https://github.com/shihabal3amri/DiPlay) supplied the CarPlay-derived experimental message shape. It was not established as a generic TV media protocol, and the LG rejected the tested setup.

## Goal and behavior

The source idea in [Ideas.md](../Ideas.md) is: “Photo in viewer is sent to tv, stays on that pic if exiting the viewer, switches when new full screen image is shown”. Here, “full screen image” means a photo opened in the existing in-window viewer; entering macOS full-screen mode is not required.

Implement an explicitly started, app-owned photo presentation session. Manual connection through the system menu bar, extended-desktop setup, dragging windows to the TV, and a 1080p-only substitute are explicitly rejected. Zoom/pan following is optional; ordinary photo casting is acceptable without it.

Required behavior:

- Put one AirPlay control in the main window’s top toolbar, using the familiar AirPlay symbol, native route selection, and an active appearance while casting. When idle, show it only when system discovery reports an additional route; starting also requires a usable viewer photo. The same control provides route changes and **Stop AirPlay Presentation** while casting, including after the viewer closes. Only start sending after deliberate route selection; opening a viewer by itself must never initiate casting.
- While presenting, follow photos opened or navigated to in any shared browser: Personal Library, Favorites, albums, Library filters, and Map results.
- Initially send the whole oriented photo, aspect-fitted on black. Optionally follow settled zoom/pan changes using the containment geometry below: every photo region visible on the Mac must remain visible on the TV, with additional photo content where the TV aspect ratio allows. Dismissal animations, chrome, filename, metadata, and selection overlays remain local.
- A new viewer photo replaces the previous one when its first usable bitmap is ready. Upgrade that same photo when a better preview or original arrives. Retain the last submitted photo while its replacement loads or fails; never submit an unrelated retained bitmap under a new item identity.
- Closing the viewer, returning to a collection, changing sidebar destinations, or changing browser selection leaves the last successfully submitted photo on the TV. Closing the viewer cancels its unfinished replacements and upgrades.
- Opening a video leaves the last still photo on the TV. Ordinary videos and Live Photo motion are outside this slice; a Live Photo's still image follows normal photo behavior.
- Provide **Stop AirPlay Presentation** in the toolbar/status controls and Library menu even while the viewer is closed. Stop releases our media/player resources; it does not promise to disconnect a system-wide AirPlay route.
- Receiver loss ends automatic following and reports a concise status. Reconnection requires an explicit start; do not silently resume presenting private photos. Quitting the app ends the session. No session, receiver, or held image is restored after relaunch.

Required output sizing: use the actual TV pixel resolution, including 4K where appropriate, rather than a hard-coded 1080p default. Discovering that resolution and verifying the complete receiver path preserves it are mandatory feasibility checks, currently unresolved for native media routing. Do not silently substitute a guessed resolution or call stream dimensions the TV resolution. Output remains SDR with no audio, slideshow timer, or photo transition. HDR, multiple receivers, video casting, and an extended-display presentation mode remain separate work; optional zoom/pan following is described below.

## Existing integration points

Read [PROJECT.md](../../PROJECT.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) before implementation. Relevant source:

- `Sources/SynoTimelineApp/App.swift`: app-scoped observable owners, `WindowGroup`, menu construction, and application lifetime.
- `Sources/SynoTimelineApp/AppShellView.swift`: `openPhoto(_:)`, `closeViewer()`, collection changes, `applicationToolbar`, and viewer ownership.
- `Sources/SynoTimelineApp/PhotoViewerPresentation.swift`: seed image, `receive(_:)`, `decodeThumbnail(_:selection:)`, `decodeFull(_:selection:)`, rotation/rollback, invalidation, and `close()`.
- `Sources/SynoTimelineApp/LibraryControls.swift`: `LibraryCommands` and menu-backed commands.
- `Sources/SynoTimelineApp/VideoPlayerView.swift`: existing video playback is view-owned and dismantled on close. Its custom-scheme repository loader is not a demonstrated AirPlay transport and must not become this feature's transport by assumption.
- `Sources/PhotoCache/FullImageDecoder.swift`: existing EXIF and display-rotation handling. Reuse the viewer's oriented result rather than decoding or downloading a second original.
- `scripts/App-Info.plist` and `scripts/run.sh`: test the signed app bundle as well as a SwiftPM build.

No new Synology endpoint, write, authentication path, cache schema, or repository media pipeline is planned. AirPlay consumes bitmap output already supplied by the viewer. Keep NAS credentials, cookies, authenticated URLs, and original filesystem paths out of receiver-facing media and diagnostics.

## Platform evidence and unresolved transport

Apple documents [AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview), its macOS [player association](https://developer.apple.com/documentation/avkit/avroutepickerview/player), and [AVPlayer external playback](https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback). These provide a public media-routing path, but do not establish a direct still-image sender or guarantee that a paused/looped generated movie holds a picture indefinitely on a particular receiver. The media adaptation below is a proposal requiring hardware evidence, not an established capability of this app.

The installed macOS SDK headers confirm:

- `AVRoutePickerView.player`, `AVPlayer.allowsExternalPlayback`, and `AVPlayer.isExternalPlaybackActive` are available on macOS.
- `prioritizesVideoDevices`, `usesExternalPlaybackWhileExternalScreenIsActive`, and `externalPlaybackVideoGravity` are unavailable on macOS. Do not copy iOS examples that use them. Bake aspect fitting and black borders into the generated frames instead.
- Route-picker presentation delegate callbacks mean the picker opened/closed; they do not prove that a receiver connected. Observe actual external-playback state and playback failures separately.

### Discovery and toolbar availability

Use public [`AVRouteDetector`](https://developer.apple.com/documentation/avfoundation/avroutedetector) with `isRouteDetectionEnabled`, `multipleRoutesDetected`, and `AVRouteDetectorMultipleRoutesDetectedDidChangeNotification`. Observe changes rather than running an app-owned network polling timer. The installed SDK documents that route detection increases power consumption; enable it while a main window is visible and the app is active, stop it while unnecessary, and refresh the observation on activation. Keep discovery independent of photo fetches and do not start playback to discover routes.

`multipleRoutesDetected` is a coarse additional-playback-route signal, not a list of same-network TVs or proof of a usable video receiver. Native routing can discover nearby devices; it is not a strict same-subnet test. Check the intended receiver, an audio-only route, and no receivers during the probe. Use the system signal as the initial availability hint; only actual external-video playback establishes a connected presentation. If strict video-only filtering or exact network membership cannot be achieved publicly, record that limitation and resolve it before promising that behavior. Do not add private device enumeration or speculative Bonjour service parsing to hide the limitation.

Toolbar rules: idle plus unknown/no extra route hides the control; a detected route shows it, with Start disabled until a usable viewer photo exists. Connecting or active presentation keeps the control visible and Stop available regardless of discovery fluctuations or viewer lifetime. A lost-route error remains dismissible in that control; after dismissal, return to discovery-based visibility. A discovery notification alone must never terminate a working cast or hide its Stop action.

### TV resolution feasibility

Native `AVRoutePickerView`/`AVPlayer` routing has no verified public receiver-pixel-size query in the inspected interfaces. [`AVPlayerItem.presentationSize`](https://developer.apple.com/documentation/avfoundation/avplayeritem/presentationsize) describes the media item, and `preferredMaximumResolution` constrains media selection; neither establishes the TV’s pixel resolution. Receiver codec limits, stream resolution, negotiated AirPlay output resolution, and physical panel resolution are different facts.

The probe must identify a public, receiver-associated source of actual pixel dimensions, record its provenance, and verify that output reaches that resolution on the intended TV. Make output dimensions a required transport capability (`AirPlayOutputGeometry`, containing pixel size and provenance), not a constant or a guess based on the Mac’s screen. Route changes invalidate this geometry and any encoded pending asset. A temporary diagnostic test clip may use a known test size for connection experiments, but that does not satisfy the product requirement.

Core Graphics can report the active pixel mode of an extended display, but that is not the required transport and may be below the panel’s native resolution. Extended-display mode was tested only to distinguish connectivity from media delivery and was explicitly rejected as a product solution. Do not propose it again as a fallback. Native-resolution output remains a requirement, while zoom following remains optional.

A custom AirPlay sender was evaluated in the now-removed isolated probe because the public media-player route did not display a picture on the intended TV. The probe uses the published pyatv implementation for normal PIN pairing; it must not extract the Mac’s existing pairing keys, bypass authentication, or ship a hand-written legacy photo endpoint on assumption. Any custom transport needs verified receiver compatibility, session cleanup, credential ownership, licensing, and native-resolution delivery before product integration. A Synology web-app HAR would not resolve this Mac-to-TV uncertainty.

### iOS comparison and next investigation boundary

The user confirmed that the working Synology Photos iOS presentation is started through Control Center's Screen Mirroring. This agrees with [Synology's iOS instructions](https://kb.synology.com/en-global/DSM/help/SynologyPhotos/iPhone). It is not a known-working direct-photo/media sender for comparison with the failed Mac media requests.

Apple's [connected-display documentation](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display) explains that UIKit apps can present separate full-screen, noninteractive content on an AirPlay-connected display while retaining their own controls locally. This is a plausible explanation for the observed iOS behavior, not confirmation of Synology's implementation. These UIKit scene APIs do not establish a corresponding connection/presentation API for this AppKit macOS application, and they do not prove 4K delivery.

Do not continue guessing nearby stream types or client UUIDs after the rejected CarPlay-derived experiment. The next useful evidence must be either (a) an identified, documented macOS API/library that starts the required app-owned presentation, or (b) a sender that demonstrably plays direct media on this LG without Control Center Screen Mirroring, with an inspectable protocol implementation or authorized session trace. Verify visible output and actual output resolution before building app integration. No clean implementation meeting the current requirements is established yet; optional zoom is not the blocker.

## 1. Prove the receiver path first

Create a disposable SwiftPM executable under `tools/AirPlayPhotoProbe/`, independent of NAS access. Use two bundled/generated nonprivate test patterns, including a portrait image and orientation markers. Record results in a **Feasibility results** section of this plan before creating production integration.

Probe implementation:

1. Build a small AppKit window with `AVRoutePickerView` associated with one retained `AVPlayer` (or `AVQueuePlayer` if looping is necessary). Set `allowsExternalPlayback = true` and observe `isExternalPlaybackActive`, player-item status, failure-to-end notifications, and time-control state.
2. Establish the selected TV’s pixel dimensions using the resolution gate above, then use `AVAssetWriter` and a pixel-buffer adaptor to encode an ordinary MP4 at those dimensions. Start with H.264, 30 fps, two seconds, baked black letterboxing, and no audio. Verify codec/encoder support at the actual dimensions; if a different public codec is required, document and test it. Use a completed local file URL, not an `AVAssetResourceLoader` or authenticated NAS URL.
3. Test playing then pausing on the still frame. If the receiver does not retain the frame, test `AVPlayerLooper` with the same still clip. Choose the simplest strategy that passes the checks below; retain the player throughout the session and between photos.
4. Replace photo A with B without recreating the route picker or player. Remove the local preview/controller view entirely while retaining only the session owner, and verify the receiver remains active. Test Stop by pausing, clearing items, and disabling external playback; distinguish our presentation ending from a system route staying selected.
5. Exercise cancellation, discovery, and route changes. Picker cancellation must not be treated as connection. An audio-only receiver must not be reported as a successful photo presentation. Verify the toolbar visibility rules and that one control can manage the active route and Stop.
6. Measure an optional zoom/pan replacement using the geometry below at the actual TV resolution. Record settled-update latency and visual interruption; smooth gesture mirroring is not a requirement.

Pass criteria on the user's intended TV/receiver:

- Shows the image through external video playback while the Mac continues showing the independent browsing UI; desktop mirroring is not a substitute.
- Establishes actual TV dimensions through a public receiver-associated capability and verifies native-resolution output; neither a guessed output size nor a silently downscaled 4K path passes this requirement.
- Holds the photo for at least 30 minutes after the local viewer closes, without an end card, visible looping, black flashes, or repeated pairing. Record any receiver screensaver/sleep limitation.
- Switches A → B → A repeatedly on the same route. Record encode duration and visible switch latency; target under two seconds after a bitmap is ready, and investigate repeated delays above five seconds before proceeding.
- Stop ends our displayed content; cancellation, receiver shutdown, network loss, and switching back to the Mac leave understandable local state and release resources.
- An inactive/minimized local window does not destroy the sender. No silent audio track may be added merely to disguise a failed photo path without documenting and reassessing the design.

A successful Apple TV test does not establish support for every AirPlay smart TV. Record the actual supported/tested receiver; do not claim generic compatibility.

**Failure boundary:** Product integration remains blocked until a direct, in-app sender is proven with this TV at the required resolution. The completed-file route has failed initial testing. Investigate normal authenticated direct-photo or modern-media sessions in the probe; any LAN HTTP/HLS transport must first have a concrete design for network permission, interfaces, per-session capabilities, URL lifetime, cleanup, and bounded ownership. Never substitute an extended display, system screen sharing, or a manually moved window. A working screen-sharing connection is not proof of photo/media-session compatibility.

### Feasibility results — 2026-10-23

Sender: macOS 27.0.1 (26A434), Swift 6.4 / SDK 27.0. Receiver: LG webOS OLED65C37LA; advertised AirPlay source version 377.40.00. TV firmware has not been independently recorded.

| Check | Observed result | Implication |
| --- | --- | --- |
| Bonjour and native discovery | TV is listed by `dns-sd` and `AVRoutePickerView`; `AVRouteDetector.multipleRoutesDetected` is true. A soundbar is also listed. | Discovery works; it is not proof of video/photo delivery. |
| Native player with generated H.264 still clips | Clips encode and play locally. TV switches to its default AirPlay screen without showing the picture, as confirmed by the user. Initial external-playback state briefly became true then false; looping did not establish visible output. | Proposed completed-local-file transport has not passed. |
| Native player with [Apple’s public HLS reference](https://developer.apple.com/streaming/examples/) | Plays locally; user reports the TV remains on its default AirPlay screen. | Failure is broader than the synthetic clip alone; root cause remains unestablished. |
| QuickTime with the generated clip | User reports it also does not work. | Failure is not isolated to the probe; this does not establish that every direct sender is impossible. |
| Mirroring / extended display | User reports both work. A dedicated probe window displayed blue, then orange; orange remained after the local preview was detached. | Connectivity comparison only. Explicitly rejected as a product workflow. |
| Extended-display modes | Active 1920 × 1080; enumerated modes expose no 3840 × 2160 mode. | Does not satisfy native-resolution delivery and must not relax the requirement. |
| Receiver capability response | Read-only `/info` reports a 1920 × 1080 display. Advertisements indicate screen mirroring and video v2, but not legacy video, legacy photos, or slideshow support, interpreted using pyatv’s feature definitions. | Do not treat mirror geometry as panel resolution or assume the legacy JPEG endpoint will work. |
| Unauthenticated legacy requests | `/server-info` and `/slideshow-features` return HTTP 403. | Authentication/unsupported functionality must be distinguished; no bypass attempted. |
| Direct modern sender | pyatv 0.18.0 reaches the pairing flow. Normal user PIN pairing and connection verification succeed. On an authenticated connection, `/server-info` returns 404 and `PUT /photo` returns 501. The instrumented modern attempt authenticates successfully, accepts `SETUP` and `RECORD` with 200, then returns 404 to `POST /play`; a following optional `PUT /setProperty` returns 501 and ends the library call. | The legacy JPEG request is unimplemented. Skipping the optional property request alone cannot fix the tested modern path, because its actual playback request already returned 404. Another compatible media-session mechanism is still unproven. |
| Experimental video-control stream | Authenticated base `SETUP` succeeds; a CarPlay-derived type-130 video-control `SETUP` returns 400. No media command is sent. Probe then deliberately sends `TEARDOWN`, which returns 200. User reports the TV's AirPlay app closes to Home, not a whole-TV crash. | This stream shape is not accepted. The observed return to Home does not establish a receiver crash because the probe also explicitly ended its session. Do not automatically repeat this experiment. |
| Synology Photos on iOS | User confirms presentation starts through Control Center Screen Mirroring. | Confirms the iOS screen/display route works, not direct media compatibility. Separate UIKit external-display content is possible but Synology's exact implementation is unverified. |
| Hold, switching, native resolution, zoom | Not accepted for a direct sender yet. | All required direct-sender acceptance remains open; zoom is optional. |

The disposable probe was removed during cleanup on 2026-10-25. Its native PIN-entry sheet successfully handled real user submissions and completed authenticated requests without logging or saving PINs or derived keys. Diagnostics recorded only request methods, route names, and status, excluding bodies. The following integration design never proceeded past its feasibility gate and is retained as historical reference.


## 2. Publish identified viewer photo frames

Modify `Sources/SynoTimelineApp/PhotoViewerPresentation.swift`; add `Sources/SynoTimelineApp/ViewerPhotoFrame.swift`.

Define a main-actor immutable `ViewerPhotoFrame` containing:

- A presentation UUID (unique per viewer instance), `PhotoViewerSelection`, item ID, monotonically increasing frame revision, and source quality (`provisional` for either thumbnail/preview, or `original`).
- The already oriented immutable bitmap to present. Do not include authenticated resources or filenames. Preserve existing pixel-interpolation preferences locally; the output encoder resamples explicitly for its output size.

Expose `latestPhotoFrame` and one typed photo-event callback. Events must cover selection changes, usable frames, and source detachment, so stale asynchronous work can be invalidated before a new bitmap arrives. Do not infer photo identity by independently observing `image` and `state`.

- Supply the initial seed frame only when the opening item has a displayable still image and the source contains an image. Retain it so a coordinator attached after initialization can replay the current frame.
- In `receive(_:)`, publish the new selection token before starting decodes, including transitions to videos or unresolved metadata. A selection change invalidates pending output work even when it has no bitmap yet.
- Publish a frame after the accepted thumbnail/large-preview decode or oriented original decode, using the existing selection checks. Do not downgrade an already displayed original. Provisional upgrades use frame revisions; distinguishing configured thumbnails from large previews is unnecessary for this slice.
- Publish after optimistic photo rotation and its rollback as well as authoritative redecoding. Same-item changes need a new revision even if the selection token stays unchanged.
- `close()` and `invalidateForNewIndex()` detach the source once, cancel pending frame work, and prevent later publication. Detachment does not clear an already submitted TV image.

Keep the observer non-owning with respect to the viewer. The controller must not retain a `PhotoViewerSession`, playlist, metadata pages, compressed originals, or speculative neighbor work after viewer close.

## 3. Add independent session ownership and encoding

Add these production files only after step 1 passes:

- `Sources/SynoTimelineApp/AirPlayPresentationController.swift`: `@MainActor ObservableObject` owning one presentation, its state, selected source identity, generation, pending work, and last submitted output.
- `Sources/SynoTimelineApp/AirPlayPhotoEncoder.swift`: off-main-actor bounded SDR conversion/MP4 encoding using AVFoundation, Core Video, and Core Graphics. Share immutable bitmap input safely under Swift 6 isolation rules; do not send mutable `NSImage` across actors or silence concurrency errors with broad unchecked annotations.
- `Sources/SynoTimelineApp/AirPlayPhotoTransport.swift`: main-actor protocol and AVPlayer implementation, with `replacePhoto`, `stop`, required `AirPlayOutputGeometry`, a stable player for the route picker, and a typed event stream for actual route/playback state. Implement only the hold strategy proven in step 1.
- `Sources/SynoTimelineApp/AirPlayRouteAvailability.swift`: main-actor observable wrapper around route detection and application/window activity. Inject a detector adapter in tests; the controller consumes availability without conflating it with connection status.

Suggested controller interface:

- `attachSource(id:currentFrame:)`, `receive(_ event:)`, and `detachSource(id:)` register/follow the active viewer without starting presentation.
- `preparePresentation()` prepares the current frame for explicit route selection.
- `stop()` invalidates all work, ends owned playback, and clears held resources.
- Published state distinguishes idle, preparing, awaiting route selection, presenting, replacing, and failure. Keep the identity of the last submitted photo separate from the desired photo; without receiver acknowledgement, call it submitted rather than confirmed visible.

Encoder input includes the required output geometry and, when optional zoom following is enabled, the latest identified viewport snapshot. Missing/invalid output geometry blocks product encoding. The controller owns a monotonically increasing operation generation. Every asynchronous encoder completion and player callback must match both the operation generation and source/frame token before changing output or status. Check identity again immediately before replacement. Stop, source replacement, detachment, and route loss invalidate pending operations.

Retain at most one active encoding and one replaceable latest pending frame. A cancelled encoder must finish cancellation before the next encoder starts; key repeat must not create concurrent encoders. Drop superseded frames rather than queueing a slideshow. Keep the previous playable asset until replacement is ready. An encode failure retains the previous submitted image, reports failure, and allows a later valid frame to recover.

Reuse the same player and route association across replacements. Do not interpret normal route activation delay as immediate failure; use a documented bounded connection timeout (initially 30 seconds), distinguish cancellation from playback failure, and do not auto-retry indefinitely. After connection loss, disarm following until an explicit restart.

Generate metadata-free media in a private per-session temporary directory. Keep only the current, pending, and any transport-required retiring asset; delete retiring files only after the player/looper no longer references them. Set an initial 64 MB total generated-media ceiling and fail cleanly if exceeded. Remove files on stop and after failures, and prune abandoned directories from prior runs at next startup. Generated movies are disposable presentation output, separate from the repository cache and its LRU. Metadata-only reset may leave the submitted image in place; full cache clear must cancel encodes, stop the presentation, and remove its generated copies too. In `LibraryModel.swift`, add an app-layer full-clear handler installed by `App.swift`; call it in `clearCache()` after its admission guard and before awaiting the repository. Do not call it from `clearMetadataCache()`. The existing repository reset stream carries only a revision and cannot distinguish these scopes; do not infer scope from it or introduce a second repository reset API.

## 4. Integrate controls and lifecycle

- In `App.swift`, create one `@StateObject AirPlayPresentationController`, inject it into `AppShellView`, and pass it to `LibraryCommands`. This owner survives `PhotoViewerView` destruction. End its work on app termination; app exit already follows the last main-window close.
- In `AppShellView.openPhoto(_:)`, attach the new presentation's current frame and photo-event callback. Use weak captures and source UUID checks. In every close/replacement/invalidation path, detach the matching source while preserving the last submitted photo. Avoid relying on a SwiftUI image `.onChange` callback to capture intermediate assignments.
- Use a focused scene value for the active viewer source so only the key main window can take control. A background window's decode must not steal the presentation. Source handoff happens when a main window becomes active or opens/navigates its viewer; a window without a viewer holds the TV image. Detaching an older window must not detach the current owner. Keep this focus handling small; do not refactor unrelated existing command routing.
- Add `Sources/SynoTimelineApp/AirPlayControls.swift`: one accessible AirPlay control in the main top toolbar, styled like native macOS media-routing controls. Its anchored compact popover contains the native `AVRoutePickerView` bound to the stable transport player, concise status, and **Stop AirPlay Presentation** when applicable. Use the standard AirPlay symbol and semantic active appearance. Keep this as one start/manage/stop entry point; do not add a second permanent Stop button or a system menu-bar extra. Native picker internals cannot be customized with an injected Stop row, so keep Stop in the owning popover using public UI. Apply the discovery visibility rules above across viewer, browser, Albums overview, and Map. Start requires a usable photo and detected availability; Stop remains enabled during connection and active casting even if discovery becomes unavailable.
- In `LibraryControls.swift`, add **AirPlay…** and **Stop AirPlay Presentation** to the Library menu using the same actions and enabled-state definitions (including discovery-gated Start and always-reachable Stop during a session). The menu command opens the app popover containing the native picker; do not invoke private picker selectors or search its internal button hierarchy. Use a focused presentation request to anchor it in the key main window. No new keyboard shortcut is needed.
- Keep the native picker available to change the selected route during a session. Report connection using actual video external-playback state, not merely picker dismissal or route availability. Use generic receiver status unless a public API provides a name; do not manufacture a device name from discovery.
- Existing video playback remains local for this slice. Verify that its independent AVPlayer does not take over the photo route or replace the held image; if AVFoundation routing interferes, resolve that before accepting this step.
- Inspect `scripts/App-Info.plist` after the probe. Add only purpose strings/permissions demonstrated to be necessary by this app's actual routing path. Do not broaden the NAS TLS exception or add arbitrary network exceptions for generated local media.

## 5. Optional zoom/pan following

The request is feasible at the geometry/rendering level. A generic AirPlay media receiver has no established public command channel for “zoom this still photo to this center”; sending only a zoom factor and center therefore is not the proposed transport. Compute the framing on the Mac, bake the crop into newly encoded media, and reuse the active route. Completed-clip replacement may be too slow for continuous interaction. Implement settled updates only if the probe shows acceptable behavior; failure of this optional slice must not block ordinary photo presentation or degrade the local viewer.

### Geometry contract: the TV contains the Mac view

“Everything on the Mac” here means all visible **photo content**, excluding toolbar, metadata, and backdrop. Do not simply apply the same zoom multiplier relative to each screen’s fit size: different aspect ratios can cause the TV to crop content that the Mac shows.

1. Read the logical resting `PhotoViewportTransform`, including actual viewport, image frame, and pan. Invert its image-to-view transform to obtain `R`, the Mac viewport’s visible rectangle in oriented image coordinates, intersected with the photo bounds. Normalize x and y separately against the oriented image dimensions so upgrades from thumbnail to original preserve framing. Use a documented top-left origin throughout.
2. Convert `R` into coordinates of the bitmap being encoded. Given actual TV dimensions `(Tw, Th)`, calculate `s = min(Tw / R.width, Th / R.height)`. This is the largest undistorted uniform scale that keeps the whole Mac-visible rectangle on the TV. The TV then covers an image-coordinate rectangle `E` of size `(Tw / s, Th / s)` containing `R`.
3. Initially center `E` on `R`. Shift it only to reveal more valid image at photo edges while preserving `R ⊆ E`. Per axis, a valid origin must stay in `[R.max - E.length, R.min]`; choose the origin closest to the centered position among those maximizing overlap with the photo bounds. If no full-photo-bounded placement exists, retain containment and letterbox the part outside the photo. Never stretch, cut off a Mac-visible part, or invent content to fill the TV.
4. Render the original oriented bitmap into that TV-sized output canvas. Wider TV framing can reveal more photo to the sides; taller framing can reveal more above and below. At fit zoom, `R` is the whole photo and this reduces to ordinary aspect fit. Different logical pixel densities do not change the framing rule.

For example, a square Mac-visible crop 1000 × 1000 in a sufficiently large photo expands to approximately 1778 × 1000 on a 16:9 TV, retaining all of the square and revealing its surroundings to either side. Near the photo boundary, shift the expansion inward where possible; use black only when no additional image exists.

### Files and interfaces

- In `Sources/TimelineCore/PhotoViewportTransform.swift`, add a pure `visibleImageRect`/normalized rectangle accessor based on the viewport/image-frame intersection.
- Add `Sources/TimelineCore/PhotoPresentationFraming.swift` with `containingFrame(visibleImageRect:imageSize:outputPixelSize:)`; return the source rectangle and output transform, validating finite nonzero inputs. Keep AppKit and AVFoundation out of this geometry type.
- In `PhotoViewerCanvasView.swift`, add `onViewportChanged` carrying a selection-identified normalized visible rectangle plus a revision. Publish after zoom (toolbar, double-click, wheel, pinch), drag/trackpad pan, resize/toolbar-inset changes, image configuration, and reset. The existing `onZoomChanged` omits pan and is insufficient. Use the logical transform, never transient opening/dismissal layer geometry.
- Forward that callback through `PhotoViewerCanvas.swift` and `PhotoViewerView.swift` to `PhotoViewerPresentation.swift`. Join bitmap and viewport only when their selection identities agree. Keep viewport revisions separate from bitmap revisions and replay the latest matching pair on attach/start. On rotation/replacement, wait for matching geometry rather than joining the new orientation with old framing.
- Extend the presentation controller to coalesce geometry changes after 200 ms without a new change, flushing promptly at gesture end. Use the existing single-encoder/latest-pending bound; do not encode each trackpad sample. Local gestures never wait for encoding or network work.
- Preserve the latest normalized viewport across image-quality upgrades. Cancel obsolete encodes on further viewport changes. Selection changes reset framing to that photo’s current viewer transform. Closing the viewer freezes the last submitted framing and cancels pending zoom work, preserving the hold-after-close behavior.

Probe acceptance for this optional slice: stable route, no black flash/re-pairing, and final framing visible within two seconds of gesture end on the intended receiver. Record observed latency; if replacement cannot provide acceptable behavior, defer zoom following explicitly and keep ordinary fit-photo output. Do not build a continuous stream, custom receiver app, or desktop mirror just to satisfy this optional behavior.

## 6. Verification and acceptance

Automated coverage belongs in `Tests/SynoTimelineAppTests/`:

- Add `AirPlayPresentationControllerTests.swift` with controllable fake encoder/transport. Check explicit start, initial replay, no casting before start, A → B with delayed A completion, frame upgrade ordering, same-item revisions, rotation rollback, video selection, decode/encode failure, close/invalidation during encoding, stop during connection/replacement, stale player events, route loss, and explicit reconnect.
- Check one active encoder plus one latest pending input, release of obsolete frames/assets, cleanup ceilings, metadata/full reset differences, and detachment not retaining the viewer/session. Test source handoff and a late detach from an old window.
- Extend `PhotoViewerPresentationTests.swift` for correctly identified seed/thumbnail/preview/original events, generation changes before frame arrival, no video-poster publication, no events after close, and orientation/rotation event behavior.
- Add `AirPlayPhotoEncoderTests.swift` using tiny asymmetric/portrait fixtures: playable H.264 output, aspect-fit borders, orientation, bounded dimensions, no copied source metadata, cancellation, and output cleanup. Inspect decoded sample pixels rather than matching encoded bytes. Do not use a real receiver in unit tests.
- Add `AirPlayRouteAvailabilityTests.swift` for unknown/no/detected route, activation/background transitions, audio-only discovery ambiguity, and discovery loss during an active cast. Check that the same toolbar entry offers Stop after viewer close and never disappears while casting. Add control/command coverage with viewer open/closed and in overview destinations. Existing Space/Escape and browser commands must retain their behavior.
- Test output geometry discovery failure, route-specific resolution changes, stale geometry completions, and actual-size encoder input; no 1080p or other guessed fallback is allowed.
- If zoom following is implemented, add `Tests/TimelineCoreTests/PhotoPresentationFramingTests.swift`: wide/tall/square Mac and TV aspect ratios, off-center pan near each edge, fit zoom, rotated images, normalized geometry across preview/original dimensions, invalid inputs, and noninteger sizes. Assert `R ⊆ E`, correct output aspect ratio and uniform scale, plus maximal valid-image overlap. Test that canvas pan/resize emits geometry, transient dismissal does not, coalescing sends the final state, stale crop encodes cannot win, and close holds the submitted crop.

Run `swift build --product SynoTimeline`, focused AirPlay/presentation tests, then `swift test` after integration. Build the app with `./scripts/run.sh --build-only` and run hardware acceptance in that signed bundle. Existing unrelated working-tree changes must be preserved.

Manual acceptance on the intended receiver:

1. Verify discovery-based top-toolbar visibility with no receiver, an arriving/departing TV, and an audio-only route. Start from a photo and cancel the picker; start again and connect. Verify a second observer cannot see metadata or the Mac desktop. Record actual TV dimensions and independently verify delivered resolution, including a 4K TV where applicable.
2. Navigate rapidly through a cached photo, an uncached photo, an original upgrade, a decode failure, a portrait, a rotated photo, and a video. The newest usable photo wins; video playback remains local and does not disturb the held TV image.
3. Close with Back, Escape/Space, and trackpad dismissal. Browse another destination, change selection, and wait 30 minutes. Open a photo from another collection and verify following resumes within the existing presentation.
4. Test NAS offline with cached images, receiver/network loss, switching routes, switching main windows, minimize/deactivate, and explicit Stop with no viewer. Cached content still works; disconnected sessions do not silently resume.
5. If zoom following is implemented, zoom/pan at each image edge and resize the Mac viewer between wide, tall, and square shapes. Verify all Mac-visible photo content stays visible on TV and additional content fills the wider/taller extent where available; verify hold-after-close preserves the submitted crop.
6. Clear metadata, clear all cache, quit, and relaunch. Check the intended held-image/stop behavior and disposable-file cleanup. Repeat screen-reader access to controls and menu commands.

## Completion and documentation

After implementation and hardware acceptance, update the current scope in root `AGENTS.md`, viewer behavior in `docs/PROJECT.md`, and session ownership/data flow/resource limits in `docs/ARCHITECTURE.md`. Record the tested receiver and remaining compatibility limits. Do not describe this proposed feature as current behavior before it exists.

Mark the Ideas entry implemented only after those checks pass. Archive this plan and update `docs/plans/README.md` following the existing convention. Remove disposable probe code once its useful checks have moved into production tests; retain the feasibility results here. No compatibility layer or persisted presentation schema is needed.

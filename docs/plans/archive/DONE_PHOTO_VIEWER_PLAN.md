# Full-size photo viewer

Implementation is complete and reviewed. Build and automated tests pass; visual and interaction checks below remain for the user.

## Scope

Keep the library mounted and open a photo in the same window, animating its visible thumbnail into an aspect-fit image. The viewer fits within the main content area initially; zoomed/panned content can extend beneath translucent navigation chrome. The toolbar has no library header title, hides Retry for a healthy connection, and switches to image zoom plus filename, capture date, and loading state while viewing. Escape/back returns to the preserved library position. Video playback is outside this photo-viewer step.

## Follow-up: compositor transitions and swipe dismissal (complete)

The Timer/`NSImage.draw` transition loop was replaced with a layer-backed canvas (black backdrop layer plus a separate image layer, Core Animation position/bounds/opacity only, presentation-layer retargeting). A single internal phase model (resting, opening, interactive dismissal, awaiting destination, returning, closing) replaces the overlapping animation flags. At fit zoom a predominantly downward two-finger trackpad swipe (precise scroll events with gesture phases, direction lock, dead zone, velocity tracking) interactively scales and translates the still photo and fades the backdrop; releasing past a viewport-relative distance or downward-velocity threshold fires one interactive-dismiss callback that the shell resolves through the same `BrowserRevealRequest`/`LibraryBrowserBridge` close pipeline as Back/Escape, otherwise the photo springs back. Above fit zoom precise scrolling pans and never dismisses; click-drag never dismisses; Reduce Motion and videos keep their existing behavior.

- [x] Open/close animate layer geometry and opacity with no per-frame `NSImage` draw.
- [x] Fit-zoom downward two-finger swipe translates/scales the photo and reveals the grid through the fading backdrop.
- [x] Release under threshold returns to the exact fit frame; release over threshold finishes into the current live thumbnail.
- [x] Zoomed photos pan with two-finger scroll; horizontal/upward/incidental scrolling and click-drag never dismiss.
- [x] Reduce Motion omits the spatial gesture; regular Back/Escape/Space close still works.
- [x] Interrupted transitions, image upgrades, resize, and repeated close cannot strand state or run cleanup twice.
- [x] Pure dismissal geometry/direction lock in `TimelineCore`; canvas routing/phase tests in `SynoTimelineAppTests`.

## Sequential implementation and review

1. **Transport and cache** — Verify a full-image endpoint, retain filenames in compatible metadata, and add independently keyed cached-first full-image resources. Use cancellable, bounded current-image/prefetch scheduling, HTTP validation, and disk eviction before thumbnails. Review endpoint evidence, lifecycle, and tests before proceeding.
2. **Viewer state and navigation** — Add a bounded section-aware navigation model, current-image loading with immediate thumbnail fallback, stale-result rejection, and cancellation on selection changes/close. Load nearby full images only after the current image succeeds. Cross section boundaries without loading the full catalog. Review rapid navigation, boundaries, offline/error states, and memory limits.
3. **Viewer and chrome integration** — Connect thumbnail activation and source geometry to a same-window expansion/collapse transition. Add aspect fit, mouse/trackpad zoom and pan, zoom-slider synchronization, arrow keys, and back/Escape. Let content render behind translucent sidebar/top chrome while fitting initially into the unobscured content rectangle. Remove the library toolbar title and hide healthy-connection Retry. Review integration, build, and relevant regressions.
4. **Final review** — Update current architecture/cache documentation, run the suite, and commit the completed work. The user performs visual and interaction testing; do not use computer automation.

## Constraints

Preserve aspect ratios, authenticated session sharing, cached-first browsing, bounded page/row retention, system appearance, and macOS 27 minimum. Full-image originals/previews must not be confused with thumbnail renditions. A cache hit must remain visible if revalidation fails; unsupported image formats and videos need an honest recoverable state. Do not log or persist authenticated URLs or tokens.

## User visual checks

- Scroll the library beneath the transparent top bar; confirm no library title and no Retry while healthy/connected.
- Open portrait and landscape photos near viewport edges; confirm thumbnail-to-fit expansion and immediate preview.
- Confirm filename, capture date, loading state, then full-image replacement without a fit/zoom jump.
- Pinch, pan, use the zoom slider, and toggle the sidebar; confirm fit excludes chrome and enlarged content continues underneath it.
- Hold left/right arrows, including across section boundaries; ensure an earlier request never replaces the current image.
- Pause on an image, then step to a neighbor to exercise speculative loading.
- Return with Back/Escape; confirm the library position and thumbnail-size preference remain intact.
- Revisit cached images offline and exercise retry after a loading failure.
- With Small or Medium selected, enable “Load large previews in viewer”; confirm the clicked thumbnail upgrades to a sharper preview before a slow original and rapid arrow navigation reuses adjacent previews. Disable it and confirm the previous thumbnail-to-original behavior. With Large selected, confirm the option is disabled and cached previews are reused without another visible intermediate stage.
- With a full-resolution original displayed, open and close a photo and confirm both transitions stay smooth; interrupt an open by zooming and confirm there is no jump.
- At fit zoom, swipe two fingers downward: confirm the photo follows the gesture, scales down slightly, and the grid shows through a fading backdrop. Release after a short/soft swipe to confirm it springs back; release after a long or fast swipe to confirm it finishes into the current thumbnail. Navigate to another photo and repeat to confirm the destination tracks the current item.
- Two-finger scroll while zoomed: confirm the photo pans and never dismisses. At fit zoom, try horizontal and upward two-finger swipes and click-drag: confirm none of them dismiss.
- Toggle Reduce Motion: confirm the spatial swipe dismissal is unavailable but Back/Escape/Space still close the viewer.

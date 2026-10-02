# Full-size photo viewer

Implementation is complete and reviewed. Build and automated tests pass; visual and interaction checks below remain for the user.

## Scope

Keep the library mounted and open a photo in the same window, animating its visible thumbnail into an aspect-fit image. The viewer fits within the main content area initially; zoomed/panned content can extend beneath translucent navigation chrome. The toolbar has no library header title, hides Retry for a healthy connection, and switches to image zoom plus filename, capture date, and loading state while viewing. Escape/back returns to the preserved library position. Video playback is outside this photo-viewer step.

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

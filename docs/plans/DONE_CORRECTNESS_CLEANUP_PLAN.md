# Browser, viewer, sidebar, and Favorites correctness plan

## Purpose

Resolve six related correctness problems before adding more product features:

- closing the viewer must return to and animate into the photo currently being viewed;
- destination scroll positions must restore reliably across launches and destination changes;
- the sidebar and its toggle must use the native macOS split-view behavior;
- Favorites membership must follow authoritative server ordering after local mutations;
- an open Favorites viewer must retain its original navigation membership until it closes;
- photo timestamps must preserve the camera's capture-local wall time instead of converting through the Mac's current timezone.

The work should keep the browser and cache bounded. It must not add polling or turn the full library into an in-memory array.

## Confirmed causes

### Viewer return

`AppShellView.closeViewer` only supplies a collapse rectangle when the selected item is the originally clicked item. After arrow navigation, the existing canvas therefore performs its destination-less fade. The browser beneath the viewer never receives viewer selection changes, so it remains at the opening position. The original thumbnail anchor is a weak reference to a reusable view and is not a safe long-lived return target.

### Restoration

The persisted semantic anchor is suitable: item ID, UTC day fallback, local pixel offset, and page-offset hint are the right data. The failures are sequencing defects:

- initial nonzero content insets can overwrite an already-applied saved anchor with scroll position zero;
- the anchor callback closes over mutable `selectedCollection`, so teardown of an old browser can save under the newly selected destination;
- provisional geometry can replace unresolved restoration intent during resize, snapshot replacement, or teardown;
- a retained provisional page can be mistaken for authoritative proof that the saved item disappeared;
- the 350 ms persistence debounce has no explicit termination flush.

### Sidebar

The sidebar is a custom `ZStack` overlay containing plain buttons, not a standard sidebar. The toolbar inserts a fixed alignment spacer even when the sidebar is collapsed, and the whole custom panel opts into interactive glass. Those choices explain the stationary toggle, shared toolbar assembly, and pointer deformation. Initial focus is not assigned to the detail viewport, so keyboard navigation can visibly focus the first sidebar button.

SwiftPM is not a limitation here. The executable is already run as an app bundle and can use `NavigationSplitView`, sidebar-styled `List`, native toolbar placement, and AppKit focus APIs. An Xcode project is not required.

### Favorites ordering

The optimistic Favorites projection fabricates one-item sections at the end of a day. It does not know the server's ordering within that day. Removal can guess the wrong section when the item's page is not cached, and shifting several local one-item pages can overwrite overlapping cache keys in dictionary order. The fabricated descriptors use the same cache-key format as authoritative server pages, so later cache or network activity can produce duplicates, omissions, or a photo at the wrong position.

### Favorites viewer membership

The intended behavior is partly explicit: local favorite changes update item flags, browser-only projection revisions do not invalidate the viewer, and resident viewer pages retain unfavorited items. It is not guaranteed after a viewer metadata page is evicted. Reloading that page goes through the live Favorites filter, where removed items are absent and later offsets have shifted. Suppressing viewer invalidation alone cannot freeze a remotely paged playlist.

### Capture-local timestamps

The exact `IMG_3872.PNG` record in `docs/captures/firstone.har` contains `time: 1790803838` and no timezone/offset metadata. Its pixels show 21:30. GMT component decoding produces September 30 at 21:30, while the viewer's timezone-unspecified `DateFormatter` applies Tokyo and displays October 1 at 06:30. Synology's observed `time` value is a capture-local wall clock encoded in an epoch-shaped integer, not an instant that should be converted to the viewer computer's zone. Timeline grouping and request bounds already use GMT and are correct.

## Shared design decisions

1. Use one collection-scoped scroll-intent resolver in the browser coordinator. It owns restoration, viewer-follow requests, explicit day jumps, and ordinary position preservation with this precedence:
   1. current explicit user or viewer request;
   2. unresolved persisted restoration;
   3. preservation of the current semantic viewport position.
2. Keep live viewer-follow intent separate from persisted navigation state. Following the viewer may update the eventual semantic anchor, but a saved anchor must not act as a continuously replayed scroll command.
3. Resolve photos by item ID and UTC day against the current collection index. Viewer section indexes and ordinals are session-relative hints, never live browser coordinates.
4. Stop writing speculative Favorites membership into authoritative timeline/page cache keys. The NAS remains the source of truth for membership and ordering.
5. Treat live Favorites browser membership and an open viewer's playlist as separate state. Favorite status updates immediately in both; playlist membership changes only when a viewer is opened.
6. Preserve current bounds: at most eight browser pages and three resident viewer pages. Any viewer playlist overlay must store only local mutation metadata and the minimum displaced item metadata, not the full collection.
7. Treat `PhotoItem.time` as floating capture-local calendar components. Use GMT when deriving display strings or day identity so wall time is preserved independently of the Mac's current timezone.

## Implementation sequence

### 1. Convert the shell to the native sidebar

- Replace the custom sidebar overlay with `NavigationSplitView(columnVisibility:)` and a selection-backed `List` using sidebar style and stable collection IDs.
- Use the system sidebar toggle. Remove the custom toggle, traffic-light width calculation, fake leading toolbar item, manual sidebar transition, and interactive glass modifier.
- Put size/viewer controls in the detail toolbar, visually separate from the system toggle.
- Let the detail column own its width and safe-area geometry. Remove manual sidebar-width subtraction from browser and viewer layout. Preserve the intended under-toolbar presentation deliberately.
- Assign initial first responder to the detail timeline once the window is ready. Restore it after viewer dismissal while preserving normal Tab and accessibility navigation into the sidebar.
- Keep destination selection, restoration storage, and viewer dismissal behavior, but capture the destination value in every callback.

Visual acceptance on the target macOS release is required because native toolbar grouping and exact Photos-style placement are not fully testable with unit tests. Check expanded/collapsed toggle placement against the supplied Photos screenshots, launch with Keyboard Navigation on and off, resizing, light/dark appearance, Reduce Motion/Transparency, loading/empty states, and viewer toolbar state.

### 2. Make scroll restoration transactional

- Introduce a typed, generation-bearing `BrowserScrollIntent` and a single coordinator resolver. Include collection, item ID when known, UTC day, local offset, page-offset hint, source/reason, and request identity.
- During configure/rebuild, calculate geometry and content insets first, select one winning intent, then scroll once. Never apply inset preservation after restoration in the same transaction.
- Keep unresolved item intent alive through provisional cached pages, validation, resize, display-size changes, and snapshot replacement. Re-resolve page hints against the new `LibraryIndex` by day and offset instead of retaining a snapshot-relative section index.
- Demand only the relevant bounded slice neighborhood. Do not declare an item absent merely because one cached/unverified hinted page lacks it.
- Capture the collection in each browser callback so teardown cannot write to another destination.
- While restoration is pending, persist the last meaningful semantic anchor rather than a temporary estimated position. Update the in-memory anchor immediately, coalesce `UserDefaults` writes, and flush on ordinary window/application termination.
- User scrolling cancels an older programmatic intent. Programmatic scrolling must continue to suppress its own feedback loop.

Add coordinator-level regression tests for initial nonzero insets, distant-page restoration, rapid Library/Favorites switching, teardown during pending restoration, cached-to-verified replacement, split days and shifted page boundaries, resize/sidebar/display-size changes, user cancellation, and immediate quit after movement.

### 3. Follow viewer selection and animate back to the live item

- Have `PhotoViewerPresentation` publish the resolved current item identity/day and a generation token whenever navigation settles or metadata reconciles identity.
- Send a coalesced viewer-follow intent to the browser beneath the overlay. It should reveal the current row only as needed and keep page demand bounded during key repeat.
- Add a pure `LibraryViewportGeometry` lookup for an item's cell frame. After reveal and layout, convert the document-space frame through the scroll/document views into window-content coordinates. Do not retain thumbnail views or reuse the opening source after navigation.
- Make close one idempotent sequence: freeze final selection, reject later navigation results, resolve/reveal the live destination, obtain its current rectangle, and run the existing collapse animation. Use a bounded fallback; if the item no longer exists in the live collection, retain the nearest deterministic day/remaining-item position and fade instead of animating into an unrelated photo.
- Reduce Motion continues to use a short fade. Closing during the opening transition must begin from the currently rendered frame rather than jump to the final fitted frame.
- Destination switching while a viewer is open dismisses/fades the old viewer without issuing a reveal into the new collection.
- Restore timeline first responder after dismissal.
- Add a viewer-aware “Toggle Favorite” command to the appropriate macOS menu and assign `.` to that command. The toolbar heart invokes the same action but must not be the sole declaration of the shortcut. Disable the menu item when no viewer is open or the current item cannot be changed.

Add tests for navigating within a row, across pages, and across days before close; rapid navigation plus Escape; unloaded/offline/missing destinations; resize/sidebar/display-size changes; close during opening; repeated Back/Escape; destination switching during close; unfavoriting the exit item in Favorites; and menu/toolbar favorite actions sharing enablement and behavior. Manually verify that `.` is visible beside the menu command and works while the viewer has timeline or canvas focus.

### 4. Replace speculative Favorites pages with authoritative refresh

- Keep the immediate optimistic favorite flag and Personal Library badge update. Keep writes serialized and keep per-item pending/error state.
- Do not add/remove/repartition Favorites timeline sections or pages before the server confirms the write. Remove the synthetic local-section projection and its cache-key shifting/rollback machinery.
- After a successful mutation, advance the Favorites metadata generation, reject older timeline/page jobs, and perform one explicit authoritative Favorites timeline refresh. Invalidate verified Favorites item pages for on-demand reload even when a returned descriptor is structurally unchanged.
- Keep the last cached Favorites browser visible during refresh. An added favorite appears in that collection after the successful write and authoritative timeline/page response; immediate guessed membership is intentionally not preserved.
- Coalesce consecutive successful writes so only the latest completed mutation triggers the final refresh. A refresh may not replace a newer mutation generation.
- Distinguish write failure from refresh failure. Roll back the optimistic flag only when the write fails. If the write succeeded but refresh failed, keep the new favorite status, mark Favorites metadata stale, and allow retry.
- Update `docs/ARCHITECTURE.md` and the root overview after implementation: local mutation will trigger a bounded authoritative Favorites refresh, not polling.

Replace tests that assert tail insertion and zero refetches. Cover authoritative beginning/middle/end ordering, equal timestamps, multiple pages in one day, multi-day sections, uncached removal targets, rapid mutations, stale in-flight work, cache eviction, write rollback, successful write plus refresh failure, and reopening after refresh.

### 5. Codify the open Favorites playlist

This step needs a narrow session overlay because the server API exposes a live filtered collection, not a snapshot cursor.

- Make the state split explicit and session-owned: `ViewerPlaylist` freezes navigation membership/order when a Favorites viewer opens, while an ID-keyed live favorite-status overlay continues to drive heart fill, pending state, errors, and optimistic rollback. Do not model the playlist as an effect that continuously copies the live browser list.
- On opening a Favorites viewer, record a playlist generation distinct from the live collection generation. Closing disposes the frozen playlist and adopts the current live Favorites collection on the next open.
- Before dispatching each local removal, record a ledger entry containing mutation generation, pending/committed state, original item ID, original day-local/section position, and the item's metadata. Commit it when the NAS write succeeds; remove or reverse it on rollback. Capturing only successful removals is insufficient because viewer page reads can overlap the write.
- Route viewer metadata-page reads through a session-scoped translator. For an original page range, translate offsets around that session's tombstones, merge stored removed items back at their original positions, and trim to the original range. Do not write reconstructed pages into global authoritative cache keys.
- Handle multiple removals/re-favorites with a deterministic ordered ledger. Keep only the ledger, removed-item metadata, and the existing three resident reconstructed pages. Release all session state on close; reopening uses current live Favorites membership.
- Delaying or coalescing the live Favorites browser refresh while its viewer is open is permitted as an optimization, but it is not the playlist guarantee: both cached-page favorite filtering and later `favorite_only` server requests can change identities at frozen offsets.
- Build the offset translator as a pure component before wiring networking. If tests show that a requested original range cannot be reconstructed with bounded adjacent live requests for split-day/multi-section layouts, stop and choose explicitly between a larger session metadata snapshot and a documented navigation limit. Do not silently weaken the playlist guarantee.
- Use a typed timeline update reason (authoritative replacement, local status change, mutation refresh) instead of relying on the ambiguous `forceRevision` boolean. Authoritative external replacement may keep the current explicit viewer invalidation policy; local membership refresh must not replace the open playlist.

Tests must remove first/middle/last items near page and split-day boundaries, navigate far enough to evict and then revisit each page, traverse both directions without duplicates/skips, handle multiple removals and re-favorites, overlap page reads with mutations, roll back failures, retain the three-page RAM bound, close/reopen into live membership, and exit while the selected item is no longer in the live browser.

### 6. Preserve capture-local photo timestamps

- Set the viewer date formatter to GMT so `PhotoItem.time` is rendered as the wall-clock components supplied by Synology rather than converted through `TimeZone.current`.
- Keep the stored integer, timeline UTC/GMT day grouping, section request bounds, cache keys, and cached page schema unchanged. No cache migration is required.
- Document the domain semantics near `PhotoItem.time` or expose a capture-wall-time formatter/component type so future UI does not accidentally treat the value as an absolute instant.
- Do not infer a timezone from address, GPS, filename, the Mac, or the NAS. The requested UX needs the local wall time, not the underlying absolute instant, and current metadata contains no reliable offset.

Add a deterministic formatting test using `1790803838` with a stable locale and a simulated Tokyo default timezone. Assert September 30 at 21:30 both before viewer session hydration and after resolved metadata arrives, and assert agreement with `utcDayID == "2026-09-30"`. Include representative Germany/Japan wall-time fixtures that display the same clock components without conversion.

## Conflict resolution and dependency order

- Native sidebar conversion comes first because it changes detail width, safe areas, focus, and thumbnail coordinate conversion. Viewer return geometry must not retain the old manual sidebar inset model.
- Restoration and viewer follow share one scroll authority. Implementing independent pending-anchor and viewer-scroll mechanisms would recreate the current races.
- Authoritative Favorites refresh removes the unsafe global projection, while the session playlist overlay preserves viewer UX. The overlay must never freeze or reconstruct the live browser globally.
- On Favorites viewer exit, resolve the final item against the live browser by ID/day. If it was removed, use a deterministic live fallback and fade; never interpret the frozen playlist ordinal as a live destination.
- Capture-time formatting is independent of the sidebar/Favorites work and can be implemented as a small early correctness fix. It must not change timeline grouping or reinterpret cache timestamps.

## Confidence and external evidence

The sidebar, restoration, viewer-follow, and authoritative-refresh changes have direct code-level causes and a clean implementation path. Exact native toolbar geometry needs an on-device visual pass.

The session playlist translator is the only material uncertainty. The pure mapping tests in step 5 are a required design checkpoint because the API does not provide a stable server snapshot token. A HAR capture is not needed for the recommended authoritative-refresh approach. It would help only if local reconstruction of NAS ordering is reconsidered: capture adding and removing Favorites within a single day spanning multiple pages, followed by the Favorites timeline and item-list requests, including their order and pagination parameters.

No additional HAR is required for the timestamp correction because the exact failing item is present in the existing capture. If optional timezone discovery is later desired, capture opening `IMG_3872.PNG` and its Info panel in Synology Photos, retaining the `SYNO.Foto.Browse.Item method=get` response with `exif`, `gps`, `address`, and `geocoding_id`; repeat with known Germany and Japan camera photos and record the web UI's displayed time.

## Likely files

- `Sources/TimelinePrototype/App.swift`
- `Sources/TimelinePrototype/LibraryBrowserView.swift`
- `Sources/TimelinePrototype/NavigationRestoration.swift`
- `Sources/TimelinePrototype/PhotoViewerView.swift`
- `Sources/PhotoCache/CachedPhotosRepository.swift`
- `Sources/PhotoCache/PhotoViewerSession.swift`
- `Sources/PhotoCache/LibraryViewportGeometry.swift`
- restoration, viewport, repository, API-model, and viewer tests under `Tests/`
- `AGENTS.md` and `docs/ARCHITECTURE.md` after behavior changes are implemented

Reference APIs: [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [AppKit state restoration](https://developer.apple.com/documentation/AppKit/restoring-your-app-s-state-with-appkit), and [SwiftUI focus](https://developer.apple.com/documentation/swiftui/focus).

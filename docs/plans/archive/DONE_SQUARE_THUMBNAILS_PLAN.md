# Square Thumbnails Plan

## Goal

Add an optional square-thumbnail presentation to every collection that uses the shared day-grouped browser. When enabled, each thumbnail fills its existing square grid slot and excess image content is cropped instead of letterboxed. Add both browser display options requested with this work to the macOS **Library** menu:

- **Crop Thumbnails to Square** toggles between the current aspect-fit presentation and square, aspect-fill thumbnails.
- **Always Show Timeline** keeps the compact day navigator painted when it is not hovered, dragged, or keyboard-focused.

Also add a small leading content inset so the first thumbnail column and day headings no longer touch the sidebar/detail boundary.

The two options are app-wide browser preferences and persist across launches. They apply consistently to Personal Library, Favorites, opened Personal Space albums, library-filter results, and Map-filter results because those destinations share `LibraryBrowserView`.

## Current behavior and constraints

- `FixedPhotoGrid` already assigns every item a square slot. The current presentation does not fill that slot: `LibraryViewportGeometry` records an aspect-fitted image frame, `HostedRow` gives `ThumbnailCell` that fitted size, and `ThumbnailCell` uses `scaledToFit()`.
- The geometry's item frame is not cosmetic. It drives pointer and marquee hit-testing, selection outlines, keyboard reveal, scroll restoration refinement, and the source/destination rectangle for viewer transitions. Square mode must therefore change both the rendered cell and `LibraryViewportGeometry.itemFrames`; changing only `Image.scaledToFit()` would leave interaction and animation geometry inconsistent with the visible thumbnail.
- Slot sizes, row heights, day grouping, section/page demand, and document height must not change when square mode is toggled. Only the image frame inside each existing slot changes.
- `TimelineNavigator` always reserves its 72-point column today, but its rail, labels, and selection indicator fade out until hover, drag, or keyboard focus. “Always Show Timeline” changes that reveal policy; it does not reclaim or add layout width.
- The shared repository, thumbnail rendition selection, cached bytes, decode limits, transfer concurrency, and network validation are unaffected. Square mode is a presentation preference, not a new thumbnail resource or cache key.
- Existing viewer interpolation behavior is unrelated and remains unchanged.
- Per the pre-1.0 compatibility policy, use new preference keys with defaults rather than migration or legacy aliases.

## Implementation

### 1. Persist browser presentation preferences

Modify `Sources/SynoTimelineApp/LibraryModel.swift`.

- Add `@Published var cropsThumbnailsToSquare: Bool`, initialized from a new `UserDefaults.standard` Boolean key such as `cropsThumbnailsToSquare`, with `didSet` writing the value back.
- Add `@Published var alwaysShowsTimeline: Bool`, initialized and persisted the same way with a key such as `alwaysShowsTimeline`.
- Keep both defaults `false`. A fresh install therefore retains the current aspect-fit thumbnails and hover/focus-revealed timeline until the user opts in.
- Keep these as global browser presentation preferences rather than collection-specific state. Destination changes and app relaunches must retain them.
- Do not add these fields to the versioned navigation-restoration payload: they are ordinary independent preferences, like `itemsPerRow`, not navigation anchors.

### 2. Expose both options in the macOS Library menu

Modify `Sources/SynoTimelineApp/LibraryControls.swift` in `LibraryCommands.body`.

- In `CommandMenu("Library")`, place two SwiftUI `Toggle` commands after the Increase/Decrease Thumbnail Size commands and before the selection commands:
  - `Toggle("Crop Thumbnails to Square", isOn: $model.cropsThumbnailsToSquare)`
  - `Toggle("Always Show Timeline", isOn: $model.alwaysShowsTimeline)`
- Keep them enabled whenever the app is running. Their state is global and may be changed while a viewer, Albums overview, or Map overview is visible; the selected value must take effect when a shared browser is next shown.
- Do not assign hidden keyboard shortcuts. If shortcuts are added later, the menu commands remain their discoverable definitions.
- A follow-up added a top-toolbar button that toggles the same `cropsThumbnailsToSquare` preference in every shared collection browser; see "Follow-up: toolbar control and clipping fix" below.

### 3. Thread square presentation through the shared browser

Modify `Sources/SynoTimelineApp/LibraryBrowserView.swift`.

- Pass `library.cropsThumbnailsToSquare` from `LibraryBrowserView.body` into `LibraryBrowserScrollView`.
- Add the Boolean to `LibraryBrowserScrollView`'s input properties and retain the last applied value in its `Coordinator`.
- On initial construction, create `LibraryViewportGeometry` with the selected presentation.
- During `Coordinator.configure`, treat a square-mode change as a geometry/presentation change even when snapshot revision, width, and item count are unchanged:
  - capture the visible anchor before changing geometry;
  - recompute materialized item frames from retained pages;
  - end an active keyboard selection extension and cancel in-progress pointer/marquee interaction, matching the existing column-count relayout behavior;
  - increment `viewRevision` so visible hosted rows are rebuilt with the new image mode;
  - refresh document/selection geometry and restore the captured anchor.
- Keep `LibraryViewportGeometry.width`, `itemsPerRow`, row height, document height, and page demand stable across this toggle.
- Pass the selected mode into every `HostedRow`, then into each `ThumbnailCell`.
- In `HostedRow`, use the full square cell width and row height in crop mode. In fit mode, preserve the existing aspect-ratio calculation exactly. The outer slot frame remains unchanged in either mode.
- Ensure row-host revision bookkeeping includes a mode change through `viewRevision`; stale visible `NSHostingView` rows must not retain the previous `scaledToFit`/`scaledToFill` behavior.

### 4. Make viewport interaction frames match the presentation

Modify `Sources/PhotoCache/LibraryViewportGeometry.swift`.

- Add a stored Boolean presentation input, named consistently with the app-layer preference (for example `cropsThumbnailsToSquare`).
- Extend the initializer and relayout API so the value can be supplied and changed. Prefer extending the existing `setLayout(width:itemsPerRow:pages:)` operation, or rename it to a presentation-aware equivalent, rather than adding a second partial update path.
- Relayout must return `true` when width, items-per-row, or square mode changes. A square-mode-only change must run `recalculate()`/`materializeRows()` so loaded item frames update immediately.
- In `materializeRows()`, continue recording `itemSlotFrames` as the full square slot. Set `itemFrames` to:
  - the slot itself when square cropping is enabled;
  - `FixedPhotoGrid.fittedFrame(in:aspectRatio:)` when it is disabled.
- Keep `slotFrame(for:)`, unloaded placeholder geometry, row calculations, section lookup, and total height unchanged.
- Because `ordinal(at:)`, `ordinals(intersecting:)`, `frames(for:)`, `loadedFramesByOrdinal()`, and `frame(forItem:)` already consume `itemFrames`, they will automatically use the visible square in crop mode. Do not introduce caller-specific overrides that could make click, marquee, selection, and viewer animation rectangles disagree.
- Keep the default initializer behavior aspect-fit so existing call sites and tests that do not opt into square mode retain current behavior. Update production calls explicitly to make the preference flow clear.

This slice used the existing `FixedPhotoGrid` square slot and aspect-fit helper directly. The follow-up later added `FixedPhotoGrid.visibleFrame(in:aspectRatio:cropsToSquare:)` so rendering and geometry share one visible-frame definition; see "Follow-up: toolbar control and clipping fix" below.

### 5. Render and clip square thumbnails

Modify `Sources/SynoTimelineApp/ThumbnailCell.swift`.

- Add a presentation Boolean input.
- Render decoded images with `scaledToFill()` in square mode and the existing `scaledToFit()` otherwise.
- Clip at the item's selected visible frame — the full square slot in crop mode, the aspect-fitted rectangle otherwise — after that frame is imposed by `HostedRow`, so aspect-fill overflow cannot draw into adjacent cells. `FixedPhotoGrid.visibleFrame(in:aspectRatio:cropsToSquare:)` supplies the shared visible-frame geometry used by both rendering and `LibraryViewportGeometry`.
- Keep the placeholder, failure icon, favorite badge, video-duration badge, activation surface, and accessibility label inside the same visible frame.
- Do not change thumbnail loading, fallback rendition selection, decode size, caching, or task identity. Switching fit/fill must reuse the already decoded image where SwiftUI preserves the cell and must never trigger a distinct repository request merely because the presentation changed.
- Preserve pending-rotation rendering and badge placement in both modes.

### 6. Add the leading browser inset

Modify `Sources/SynoTimelineApp/LibraryBrowserView.swift` in `Coordinator.configure`.

- Replace the current zero left content inset with a small fixed value equal to the grid gap (`FixedPhotoGrid.gap`, currently 8 points), converted to `CGFloat` as needed. Keep the existing toolbar-derived top inset and zero bottom inset.
- Use the same 8-point right inset unless visual verification shows the existing navigator separation already supplies it; symmetric horizontal inset is preferred because `availableWidth(in:)` already subtracts both sides and avoids an edge-clipped final column. The essential acceptance criterion is an 8-point leading gap from the sidebar/detail boundary.
- Continue deriving geometry and document width from `availableWidth(in:)` so all columns remain equal and the requested 3–10 item count still fits without horizontal scrolling.
- Expand `insetsChanged` comparison to include every horizontal inset that can change. Preserve the existing anchor-restoration path so applying the inset does not jump the visible day/item.
- Day headings, loading/error placeholders, marquee coordinates, selection overlays, and row hosts must share the inset coordinate system; do not add independent SwiftUI padding only to `HostedRow`.

### 7. Support a persistently visible timeline

Modify `Sources/SynoTimelineApp/TimelineNavigator.swift` and its construction in `LibraryBrowserView.body`.

- Add an `alwaysVisible: Bool` input to `TimelineNavigator`.
- Change its reveal predicate to `alwaysVisible || pointerIsNear || dragging || (focused && keyboardActive)`.
- Pass `library.alwaysShowsTimeline` from the shared browser.
- Preserve hover labels, exact-day marker behavior, drag selection, keyboard focus, accessibility adjustable actions, reduce-motion handling, and the fixed 72-point reserved width.
- When `alwaysVisible` is true and the pointer is not hovering, the rail/month/year marks/current selection remain visible. The detailed hover card and cross-track hovered marker should still require an actual hovered/keyboard-active day; do not fabricate a hover target merely to keep the base timeline visible.
- Toggling the preference must update an already visible browser immediately through SwiftUI observation; it must not rebuild metadata or reset the selected day.

## Tests

### Automated geometry tests

Modify `Tests/PhotoCacheTests/LibraryViewportGeometryTests.swift`.

- Keep the existing aspect-fit test as the default-mode regression test.
- Add a square-mode test with wide and tall photos that asserts:
  - `frame(forItem:)` equals `slotFrame(for:)` for both aspect ratios;
  - points in areas that were letterboxed in fit mode resolve to the correct ordinal in square mode;
  - marquee intersection uses the square visible frame;
  - toggling only the presentation through the relayout API returns `true`, updates frames, and does not change `totalHeight`, `slotSide`, day origins, or ordinal placement.
- Extend the anchor-preservation test, or add a focused test, to prove a square-mode relayout keeps `y(for: anchor)` stable because row geometry is unchanged.

No new `TimelineCoreTests` are necessary unless production work introduces a pure helper there. Do not duplicate the existing `FixedPhotoGrid` slot/aspect-fit coverage.

### App-layer regression coverage

If the presentation choice is extracted into a small pure helper to choose fit versus fill, add a focused `SynoTimelineAppTests` test. Otherwise prefer the PhotoCache geometry coverage plus manual UI verification over fragile SwiftUI view introspection.

Run:

```sh
swift test
```

### Manual UI checks

1. Open Personal Library with the default option off. Confirm portrait and landscape thumbnails remain aspect-fitted and clicks in letterboxed slot space do not select an item.
2. Choose **Library > Crop Thumbnails to Square**. Confirm visible rows update immediately without a scroll jump, each thumbnail fills and clips to its square, badges stay inside the crop, and no thumbnail request/cache reset is triggered solely by the toggle.
3. In square mode, click near a cropped thumbnail's corners, marquee across corners, use arrow selection, and open/close the viewer. Confirm hit targets, selection outlines, reveal scrolling, and expansion/collapse transitions use the same square rectangle.
4. Toggle back to aspect-fit and confirm interaction rectangles shrink back to the visible image rather than the slot.
5. Verify the leading edge of headings, placeholders, and first-column thumbnails has an 8-point gap from the sidebar/detail divider at 3, 6, and 10 columns and after window resizing. Confirm there is no horizontal scrollbar or clipped last column.
6. Choose **Library > Always Show Timeline**. Move the pointer away and confirm the rail, date marks, and current selection remain visible while the navigator width does not change. Turn it off and confirm the existing hover/drag/keyboard reveal behavior returns.
7. Repeat square mode in Favorites, an opened album, a metadata-filter result, and a Map-filter result to confirm every shared browser honors the global preference.
8. Relaunch the app and confirm both toggles retain their values independently of the restored destination and scroll anchor.
9. Check light/dark appearance, cached/offline browsing, empty/loading/error states, favorite badges, video-duration badges, and an optimistic photo rotation for visual regressions.

## Documentation updates after implementation

- Update `docs/PROJECT.md` to state that the shared browser supports persisted aspect-fit or square-cropped thumbnails, has a small content edge inset, and can keep the compact day navigator visible.
- Update `docs/ARCHITECTURE.md` where fixed-grid rendering and navigator reveal behavior are described. Record that the slot geometry stays fixed while the selected presentation determines the materialized interaction/image frame.
- Update the root `AGENTS.md` project overview only if this feature materially changes the concise current-scope sentence; keep the overview short and avoid implementation detail.
- Remove the completed **Square thumbnails** bullet and its sub-bullets from `docs/plans/Ideas.md` only if the user-authored working-tree edit can be preserved cleanly. Do not overwrite or reformat unrelated ideas.

## Acceptance criteria

- The Library menu contains checked, persisted toggles for square-cropped thumbnails and an always-visible timeline, and every shared collection browser exposes the square-crop toggle in its toolbar.
- Square mode uses aspect fill with clipping inside the existing square slots in every shared collection browser.
- Rendered frames, hit-testing, marquee selection, selection outlines, keyboard reveal, and viewer source/destination transitions agree in both fit and square modes.
- Toggling modes is immediate, preserves the visible anchor, and does not alter row/document geometry or cause presentation-specific media requests.
- Browser content has a consistent 8-point leading inset and still fits the selected 3–10 columns without horizontal scrolling.
- The timeline's reserved width and navigation behavior remain stable; only its idle visibility changes.
- `swift test` passes, and current product/architecture documentation describes the shipped behavior.

## Follow-up: toolbar control and clipping fix

The first implementation was accepted but square mode rendered incorrectly: with `.clipped()` applied to the cell's `ZStack` before `HostedRow` imposed the fitted frame, `.aspectRatio(contentMode: .fill)` reported an oversized layout size for portrait/landscape images, so the clip bounds were the oversized child rather than the intended square. Aspect-fill content therefore escaped each square slot and produced an overlapping masonry layout.

Corrective work:

- Introduced `FixedPhotoGrid.visibleFrame(in:aspectRatio:cropsToSquare:)`, the single source of the visible item rectangle (full slot in crop mode, aspect-fitted rectangle otherwise). `LibraryViewportGeometry.materializeRows()` and `HostedRow` both use it, keeping the rendered frame and the hit/interaction frame identical.
- Moved clipping out of `ThumbnailCell` and onto `HostedRow`, applied immediately after the fixed visible-frame `.frame(...)` and before the outer slot-centering frame, so the crop is taken at the actual square/fitted boundary. Badges, the activation surface, and placeholders stay inside that frame.
- Added `BrowserThumbnailShapeControl` to the shell toolbar beside the items-per-row control. It is shown whenever a shared collection browser is visible (Personal Library, Favorites, opened album, filter result, and map filter), binds to `model.cropsThumbnailsToSquare`, uses a stable SF Symbol with an accessibility label and help text, and adds no keyboard shortcut because the Library menu command already exists. Animation was still deferred at this point; see the presentation-animation follow-up below.
- Added a focused `TimelineCoreTests` case for `visibleFrame` selection; the existing `PhotoCacheTests` square-mode geometry coverage already asserts the interaction/image frames match the slots.

Manual UI verification of the corrected square grid, toolbar button presence across destinations, and the fit-mode frame remains outstanding.

## Follow-up: presentation animation

The toggle previously applied the mode instantly by replacing retained `NSHostingView` roots. The animation slices that into a visible-frame morph that preserves the fixed grid:

- `FixedPhotoGrid.fillsFrame(cropsToSquare:isTransitioning:)` is the single pure decision for aspect-fill versus aspect-fit. It fills at rest in square mode and for the whole morph in either direction, so a shrinking frame never flashes letterbox bars in the aspect-fit direction. At the fitted rest frame fill and fit coincide for a known aspect ratio.
- `BrowserThumbnailPresentation` (`Sources/SynoTimelineApp/LibraryBrowserView.swift`) is one observable object owned by the scroll view's coordinator and observed by every `HostedRow`. Its `cropsToSquare` selects the target visible frame and its `isTransitioning` flag covers the morph. The coordinator animates a clean user-driven preference change with `.easeInOut(duration: 0.22)` and does **not** increment `viewRevision`, so already-attached rows keep their `AnyView` root and decoded image while `withAnimation` interpolates the inner `.frame(...).clipped()` between `FixedPhotoGrid.fittedFrame` and the full slot. Window resizing and items-per-row changes still bump `viewRevision` and apply instantly, never animating relayout.
- `LibraryBrowserViewportGeometry` is set to the final mode synchronously, so pointer/marquee hit-testing, keyboard reveal, selection geometry, and viewer transition sources never use stale prior-mode frames. The AppKit selection overlay draws from that final geometry, so selection outlines snap to the final frame while the thumbnail morphs; animating the outline (a separate `NSView.draw` layer) was judged not cleanly feasible and this deliberate choice is documented here and in `docs/ARCHITECTURE.md`.
- Rapid toggles cancel the previous completion task and only the latest target clears `isTransitioning`, so no stale end state remains. New rows materialized or scrolled into view read the current target directly and never replay an old animation.
- Reduce Motion (`@Environment(\.accessibilityReduceMotion)`, passed through `LibraryBrowserScrollView.reduceMotion`) applies the final presentation with no morph.
- The toolbar `BrowserThumbnailShapeControl` now shows `rectangle.arrowtriangle.2.inward` while square-cropped (clicking fits to aspect ratio) and `rectangle.arrowtriangle.2.outward` while aspect-fitted (clicking crops to square); labels/help and the Library menu toggle are unchanged and there is no keyboard shortcut.
- Focused pure tests were added for `FixedPhotoGrid.fillsFrame` and the `BrowserThumbnailPresentation` state machine (rest mode, snap, and rapid-toggle settling).

Manual checks still outstanding: watch the morph in both directions at low and high column counts, confirm clipping has no bleed and interaction geometry feels correct mid-transition, confirm Reduce Motion snaps, and check rapid toggling and viewer open/close during the morph.

# Library selection — Step 1

Status: Step 1 implemented.

## Scope and decisions

Use equal square slots, center each aspect-fitted photo inside its slot, and provide browser selection. The supplied Apple Photos screenshot is a visual reference for spacing and fitting, not a request for its other controls. Preserve native chrome, date navigation, cache rendition settings, bounded page loading, and the current collection viewer.

Confirmed scope:

- The last example is “Right → {(3,5)}”; all four examples independently start from the original selection.
- Retain day headings and start each populated day on a new row; apply selection to Personal Library and Favorites.
- Selection crosses day boundaries. Left/Right treat them as row breaks, including partially filled rows. Up/Down also cross into the adjacent day’s row.

Unspecified edge cases below use proposed defaults; they are implementation choices rather than additional user requirements.

Out of scope: viewing a selected subset (Step 2), bulk operations, video playback, new NAS write endpoints, persistent selections across app launches, and unrelated sidebar changes.

## Interaction contract

### Layout and sizing

- Every slot has the same width and height at the current viewport width. Photos retain their aspect ratio without cropping; unused slot space shows the browser background. Outline and favorite/duration badges follow the fitted thumbnail rectangle, not the square slot.
- Persist an integer `itemsPerRow` in 3...10. Default to 6 when this preference is absent; retire the old point-based display-height preference without changing cached rendition settings.
- The toolbar slider has eight discrete positions. Moving toward plus makes thumbnails larger by reducing the column count. Existing Increase/Decrease Thumbnail Size menu commands change the count by one, with correct endpoint disabling and an accessibility value such as “6 items per row”.
- Resize changes slot size but not column count. Preserve the visible photo anchor when resizing or changing columns. Preserve selection; reset an active keyboard extension sequence after reflow.
- Same-day rows continue across API page boundaries. Incomplete final rows stay left aligned; no padding slot represents a selectable item.

### Pointer selection

- A plain click replaces selection with the clicked item. Shift-click adds that item; it does not toggle or select an intervening range.
- A plain drag rectangle replaces selection with its intersected items. Shift-drag produces the symmetric difference of the selection captured at mouse-down and the current rectangle hits. Recompute from that baseline on every update, so crossing an item repeatedly does not toggle it repeatedly.
- Proposed hit policy: intersect the fitted image rectangle, excluding empty letterbox space. Clicking empty space clears selection; Shift-clicking empty space leaves it unchanged. Empty space within a slot can start a marquee.
- Use a small movement threshold to distinguish click from drag. A drag may start over a thumbnail; defer click commitment until the gesture is classified. Double-click selects the clicked photo and opens it once.
- Draw the marquee in document coordinates and support edge autoscroll. Include newly exposed rows during autoscroll and stop scrolling on mouse-up, focus loss, viewer opening, or collection change.
- Videos remain selectable as browser items; opening obeys the existing still-photo viewer eligibility rules.

### Keyboard selection

Order items by displayed row first, then column. Coordinates in the supplied examples are interpreted as zero-based (row, column).

Without Shift:

- Left/Up start from the earliest selected item; Right/Down start from the latest selected item.
- Move once in the requested direction and replace selection with the destination.
- Left/Right move one item in reading order and wrap between rows. Up/Down move to the adjacent visual row in the same column; when that row is shorter, clamp to its last item. Skip date headings, cross day boundaries, and stop at collection ends rather than wrapping the whole collection. For example, in a six-column view, Down from column 2 of a three-item final row moves to column 2 of the next day’s first row; Right from that same item moves to column 0 of the next day.
- With no selection, select the first visible item on the initial arrow press, without an additional movement.

With Shift:

- At the start of an extension sequence, choose the same directional border described above and retain it as an anchor. Move a separate cursor one step.
- Union the inclusive reading-order range between the fixed border and cursor into the existing selection. A vertical move therefore also includes the intervening items, not just its destination.
- Subsequent Shift-arrow presses move the cursor rather than recomputing a border from the changing selection. The result is the gesture-start selection plus the current inclusive border-to-cursor range. Reversing direction shrinks that range without removing items that were selected before the Shift sequence began.
- End the extension sequence when Shift is released, a pointer selection occurs, an unmodified arrow is used, the layout reflows, or the collection/index changes. Scrolling alone preserves selection.
- Reveal the cursor with the minimum scroll required to keep its slot visible below the toolbar. Keyboard selection replaces the browser's current arrow-key scrolling behavior; the date navigator and viewer retain their own focused keyboard behavior.

Expected independent examples for a six-column grid starting with {(1,3), (2,2), (3,4)}:

| Command | Result |
| --- | --- |
| Up | {(0,3)} |
| Left | {(1,2)} |
| Down | {(4,4)} |
| Right | {(3,5)} |

### Viewer and menus

- Add Open Selected Photo to the Library menu with Space. Enable it only in browser context when exactly one eligible photo is selected. With zero or multiple items selected, Space does nothing in Step 1.
- Double-click opens the clicked eligible photo through the same request path. Viewer arrows continue through the whole collection.
- On viewer close, select and reveal its current photo when that item still belongs to the live collection. If it was removed from Favorites, clear selection and retain the existing fallback reveal behavior.
- Define four directional selection commands and four Shift extension commands in the menu; attach their shortcuts there. AppKit event handling dispatches the same actions, with no duplicate key handling or hidden shortcuts. Scope these commands to the active browser so sidebar, navigator, viewer, and settings focus keep working.
- Expose selection state to accessibility, change thumbnail press behavior to select, and expose an explicit open action. Avoid replacing the existing single-click activation with an inaccessible pointer-only surface.

## Implementation slices

### 1. Deterministic grid geometry

Add a pure fixed-slot layout type in `TimelineCore`. Adapt `LibraryViewportGeometry` to expose slot frames, aspect-fitted image frames, visual row/column lookup, rectangle hit queries, and directional movement. Extend `LibraryIndex` with compact prefix-count mappings between collection ordinals, day offsets, and section/page locations.

Compute row allocation and document height from timeline counts and columns, independently of loaded image metadata. Materialize only nearby row contents. Give each split row one stable identity that may draw items from both adjacent pages. Loading or evicting a page must not move its neighbor into a different row. Missing metadata leaves the corresponding slot available as a placeholder.

Keep the eight-page window and overscan bounds. Visible row demand must include all contributing sections, including cross-page rows. Test restoration and viewer reveals against the revised geometry before adding interaction.

Update `LibraryModel`, `LibrarySizeControl`, and `AppShellView` for the integer preference. Remove the superseded layout implementation and its tests after confirming no remaining consumers.

### 2. Independent selection state

Add a pure selection value with selected ordinal ranges, collection/index generation, extension border/cursor, and drag baseline. Store normalized disjoint ranges rather than `PhotoItem` arrays: a large range should not load or pin every metadata page. Implement replace, union, symmetric difference, membership, count, first/last, and directional extension as independently testable operations.

Keep the AppKit interaction adapter small and separate from the already substantial browser coordinator. Window-scoped, collection-specific selection state should outlive recycled row hosts and destination view recreation. Retain selection across scrolling, zoom, and switching destinations within the session.

Ordinal selection belongs to one ordered metadata generation. Preserve it for identical descriptors and favorite-status-only updates. Clear it when descriptors change or page verification reveals changed item membership/order, even when timeline counts are identical; cancel outstanding gestures and cursor work. Do not silently apply old positions to different photos. Cached provisional selections must be invalidated on such a correction. This deliberately avoids an unbounded scan to reconcile a large selection by ID.

Loaded item IDs are used to validate open/reveal requests. Defer ID materialization for selected subsets to Step 2; do not modify `ViewerPlaylist`, which currently serves Favorites mutation stability.

### 3. Pointer interaction and rendering

Replace `ThumbnailActivationSurface`'s immediate single-click opening with a shared browser interaction adapter receiving mouse-down/drag/up, click count, and modifiers. Keep source-image anchors available for viewer animation.

Render selected outlines without restarting thumbnail fetch/decode tasks. Update only affected visible row hosts. The marquee overlay must not block thumbnail accessibility or unrelated controls.

For unloaded metadata, exact fitted-image hits cannot yet be known. Request only the bounded visible pages, recompute hits as metadata arrives during the gesture, and commit known image hits on mouse-up. Never fetch an entire drag span merely to build selection. Keyboard ranges can include unloaded positions because their ordering is known. Cancel stale pointer work on geometry/index changes rather than committing against obsolete coordinates.

### 4. Keyboard, scrolling, and viewer integration

Route menu-backed selection actions through the active browser bridge. Extend `BrowserScrollIntentCoordinator` with a selection-reveal intent or equivalent typed purpose, using known slot positions and bounded destination-page demand. Selection movement must not race restoration or viewer follow; manual scrolling cancels deferred reveal refinement without clearing selection.

Use one open-selected path to build `PhotoViewerSeed` and obtain a source anchor. Reveal/load an offscreen selected item first if necessary, then open only if selection identity and metadata generation still match. Handle unavailable metadata without opening the wrong photo. Preserve thumbnail-first animation and use fitted-image rectangles for both expansion and collapse.

Scope browser actions off while the viewer is active. Reconcile the viewer's final item with the current browser generation on close. Keep current collection navigation in `PhotoViewerSession` unchanged.

### 5. Verification and documentation

Automated tests:

- Grid counts 3 and 10, mixed aspect ratios, partial rows, split-day and split-page rows, exact unloaded geometry, page eviction/reload, and resize/column-change anchoring.
- All four supplied examples; row wrapping, collection limits, short rows/day transitions, no selection, Shift vertical ranges, repeated keys, direction reversal, and sequence reset.
- Plain/Shift clicks; drag baseline XOR, contraction and repeated crossings; metadata arrival mid-drag; selection surviving row recycling; generation invalidation.
- Single versus double click, Space eligibility, focus/menu routing, stale deferred opens, viewer return, and Favorites removal.
- Existing browser restoration, cache, and viewer suites remain green. Run `swift test` and build with the existing project tooling; do not introduce live NAS write tests.

Manual acceptance:

- Compare landscape, portrait, and panoramic fitting with the reference in both appearances and at every column count.
- Exercise drag autoscroll, Shift toggling, key repeat, zoom/resize, destination switching, offline cached pages, and Space/double-click opening.
- Verify large selections do not grow metadata retention or trigger bulk thumbnail/original downloads; hosted rows and decoded image work remain bounded.
- Verify menu discoverability, VoiceOver selection/open actions, native sidebar/navigator focus, and viewer animation rectangles.

After implementation, update the current-behavior sections in root `AGENTS.md` and `docs/ARCHITECTURE.md`, plus any user-facing control documentation. Until then those documents should continue describing the implemented app.

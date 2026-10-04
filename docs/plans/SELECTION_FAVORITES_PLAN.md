# Selection Favorites

Status: Planned.

## Goal

Expose the favorite button in the window toolbar while browsing the timeline and let the button or the Library menu's `.` shortcut change favorite status for the current selection. Preserve the existing single-photo viewer behavior, bounded metadata loading, optimistic cache updates, and authoritative Favorites refresh.

This plan applies to both Personal Library and Favorites. “Photo” below means any selected Synology Photos item that supports the existing favorite metadata and endpoint.

## Confirmed server behavior

The Synology Photos web client uses a form-encoded `POST /webapi/entry.cgi/SYNO.Foto.Browse.Item` with:

```text
api=SYNO.Foto.Browse.Item
method=set_favorite
version=7
id=[<item IDs>]
favorite=true|false
```

`docs/captures/favoriteunfavorite2photos.har` confirms that `id` accepts multiple IDs. The web client sent one request containing the same two IDs with `favorite=true` and one with `favorite=false`; both returned `{"success":true}`. The transport already models this as `setFavorite(itemIDs: [Int64], favorite: Bool)`.

The capture establishes two-item batching but not a maximum request size. Use a conservative fixed maximum number of IDs per request for very large selections. Do not retry an ambiguous failed write by dynamically changing its batch size: the server may have applied a request whose response was lost.

## Interaction contract

### Target state

Resolve the current favorite status of the complete selection before choosing the action.

- If at least one selected item is not a favorite, set every currently unfavorited selected item to favorite. Already-favorited selected items are unchanged and are not sent to the server.
- Only when every selected item is already a favorite, set every selected item to not favorite.
- The affected count is the number of items whose state will actually change, not the total selection count.

Examples:

| Selection | Result | Affected count |
| --- | --- | ---: |
| 4 favorites, 2 non-favorites | Favorite the 2 non-favorites | 2 |
| 6 favorites | Unfavorite all 6 | 6 |
| 6 non-favorites | Favorite all 6 | 6 |
| 96 favorites, 4 non-favorites | Favorite the 4 non-favorites | 4 |

### Confirmation

- When at most five items are affected, start the mutation without confirmation.
- When more than five items are affected, present a window-modal confirmation alert before optimistic state changes or server writes.
- Use an action-specific title and button, such as “Add 12 Photos to Favorites?” / “Add to Favorites” or “Remove 12 Photos from Favorites?” / “Remove from Favorites”. Include Cancel.
- The confirmation owns the already-resolved item IDs and target state. It must not recompute against a later selection.
- While resolving metadata, awaiting confirmation, or writing, disable another browser favorite action. Browsing and selection changes may otherwise continue; once writes begin, the captured operation survives destination changes.

### Toolbar and menu

- Keep one favorite item visible in the window toolbar at all times.
- In the viewer, retain the existing item-specific filled/empty heart, enablement, error help, and single-item mutation.
- In the timeline, show a generic heart with an accessibility label such as “Toggle Favorite for 12 Selected Items”. Disable it for an empty selection, unavailable network, or an active selection-favorite operation.
- Keep “Toggle Favorite” in the Library menu and attach `.` there. Route the command to the viewer when it is open and to the active browser otherwise.
- Do not add a separate hidden period-key handler to the AppKit browser. The menu command remains the shortcut definition.

## Implementation

### 1. Browser command state

Extend `BrowserSelectionCommand` with `toggleFavorite`. Expand the browser command publication from only `canOpen` to include whether a selection favorite action may begin. Preserve the existing owner identity so a stale browser cannot disable or invoke commands belonging to the active browser.

Have the browser command snapshot:

- collection;
- `LibraryIndex` fingerprint and selection generation;
- selected ordinal ranges;
- identities of selected items already known from retained pages.

Hand this immutable request to `LibraryModel`, which owns preparation, pending confirmation, progress, and failure state. Model ownership lets a confirmed write finish if the browser is recreated or the user changes destinations.

### 2. Bounded selected-item resolution

Add a focused resolver in `PhotoCache`, following the bounded approach used by `ThumbnailRangeDownloader`:

1. Map selected ordinals to `LibraryIndex.Location` values.
2. Group locations by timeline section.
3. Read only sections containing selected ordinals through the repository page API.
4. Wait for verified metadata before authorizing a write. Cached provisional data may be shown but must not decide the mutation.
5. Process one or two metadata pages concurrently and release each full page after extracting its selected items.
6. Retain compact mutation inputs only: item ID, current favorite status, source section, source collection, and enough day/item information to patch Personal Library cache entries.
7. Do not request thumbnails or originals and do not add resolved pages to the browser's eight-page retention window.

Before the first write, reject the operation if its index fingerprint is no longer current or if verification changes the identity of a selected item that was known when the command began. For previously unloaded ordinals, the verified item currently occupying that ordinal is the selected item. Abort rather than applying stale ordinals to a changed collection.

After resolution, calculate the target and affected subset using the interaction contract. If the affected set exceeds five, publish a pending confirmation value to the shell; otherwise begin the mutation immediately.

### 3. Modal confirmation

Present the pending confirmation from `AppShellView` with a SwiftUI alert so it is modal to the window. The alert must use the prepared action's count and target. Confirm passes that exact prepared action to execution; Cancel discards it and clears the busy state without publishing favorite changes.

### 4. Repository batch mutation

Add a batch mutation entry point to `CachedPhotosRepository`. Keep the existing single-item method as a wrapper so viewer behavior does not fork into a separate pipeline.

For one prepared action:

- Atomically reject or claim every affected ID against `RepositoryFavoriteState.pendingIDs` before publishing changes.
- Serialize the action behind the existing favorite write tail.
- Cancel a pending Favorites refresh and advance the Favorites mutation epoch once before the action.
- Apply one uniform target value to the affected IDs in `favorites.overrides`.
- Publish one batched favorite change rather than one stream event per item.
- Patch cached Personal Library pages by grouping changes per cache key and decoding/encoding each affected page once.
- Connect once, then call `PhotosTransport.setFavorite(itemIDs:favorite:)` once for an ordinary selection or sequentially for fixed-size chunks of a very large selection.
- Schedule one coalesced authoritative Favorites timeline refresh after the action finishes.
- Remove every claimed ID from the pending set and allow the next serialized write to proceed.

The batch change stream should contain an ID-to-value map plus source information needed for cache/view reconciliation. `LibraryPageWindow` should scan and rewrite each retained page once per batch. Viewer sessions should apply only changes relevant to their bounded metadata window and current item.

### 5. Failure and partial-success behavior

A single failed server request rolls back every ID in that request to its previous value. When a very large action uses several chunks:

- Keep successfully completed chunks.
- On the first failed chunk, stop issuing later chunks.
- Roll back the failed and unsubmitted IDs only.
- Reapply previous values to affected cached page entries rather than restoring whole raw page backups, because a page can also contain IDs from a successful chunk.
- Advance the mutation epoch as needed to reject older in-flight Favorites metadata.
- Refresh the authoritative Favorites timeline after any success or ambiguous state.
- Report a concise outcome containing successful and failed/unsubmitted counts.

Cache patch failure does not imply that a server mutation failed. Continue to treat the NAS as authoritative and rely on subsequent page validation and the Favorites refresh to repair local metadata.

### 6. Favorites collection behavior

All authoritative members of Favorites are favorites, so a normal Favorites selection resolves to “unfavorite all selected”. Optimistic changes remove heart badges but do not fabricate new Favorites membership or ordering. The authoritative refresh updates the collection geometry; its changed fingerprint invalidates the old ordinal selection. The viewer's existing session-local mutation ledger remains responsible only for an already-open Favorites viewer.

## Verification

### Automated tests

- Target calculation for empty, mixed, all-favorite, and all-unfavorite inputs.
- Affected count rather than selection count drives confirmation.
- Exactly five affected items bypass confirmation; six require it.
- Cancel performs no optimistic publication and no transport request.
- Confirmation executes the exact prepared IDs and target.
- Selections spanning unloaded, split-day, and split-page sections resolve correctly.
- Metadata resolution stays bounded and performs no thumbnail or original requests.
- A changed fingerprint or changed known item identity aborts before writing.
- Ordinary selections produce one transport call containing every affected ID.
- Very large selections use deterministic chunks with one target value.
- Pending-ID conflicts are rejected atomically before any optimistic update.
- Batch observers rewrite each retained page once.
- Cached Personal Library pages are decoded and encoded once per affected key.
- Full failure rolls back all affected statuses.
- Partial chunk failure preserves completed chunks, rolls back the remainder, and triggers one authoritative refresh.
- Favorites refresh changes the browser index without invalidating an unrelated open viewer playlist.
- Toolbar visibility, enablement, accessibility labels, active-window ownership, viewer/browser routing, and the menu-backed `.` shortcut.

### Manual acceptance

- Exercise zero, one, five, six, mixed, and large selections in Personal Library and Favorites.
- Confirm that a large selection with only five unfavorited items does not show the modal.
- Confirm that the toolbar heart never disappears when entering or leaving the viewer.
- Verify modal wording, default/cancel behavior, keyboard focus, and VoiceOver output.
- Switch destinations immediately after confirming and verify the mutation completes and both timelines reconcile.
- Exercise cached/offline browsing and confirm that unverified metadata never authorizes a write.
- Observe network requests and confirm affected IDs are batched with the uniform target.

## Documentation updates after implementation

Update the current-behavior sections in root `AGENTS.md` and `docs/ARCHITECTURE.md`. Keep `docs/SYNOLOGY_PHOTOS_API.md` as the source for the observed multi-ID request shape. Mark this plan implemented only after the automated suite and manual acceptance checks pass.

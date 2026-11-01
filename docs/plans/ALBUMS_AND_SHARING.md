# Albums and sharing implementation plan

Status: completed issue breakdown, retained as a historical plan. Current behavior is documented in the product and architecture sources below. Each linked issue contains its implementation context and acceptance criteria.

Sources: [current product](../PROJECT.md), [current architecture](../ARCHITECTURE.md), and [captured NAS contract](../captures/ALBUM_SHARING_ANALYSIS_2026-11-01.md). The supplied Synology screenshot is a content reference for the opened-album header, not a visual specification. Its temporary screenshot path must not become an application dependency. Use native macOS controls, restrained typography and whitespace; follow the project's [UI pattern reference](https://www.thefountaininstitute.com/blog/signs-vibe-coded-ui), with no decorative status dots, extra panels, or explanatory marketing copy.

## Product behavior

### Albums overview

- Keep one Albums destination. Show **Shared Albums** above **Albums**, using the same album cards and underlying collection identity.
- Classify currently listed owned normal albums using authoritative `shared`, not presence of a sharing reference, public/private mode, or whether the link has expired. An expired shared album still belongs in Shared Albums. Incoming invitations are not silently added to this scope: their enumeration is not captured.
- Each section defaults to one complete row of cards, with its own expand/collapse control. Expanded shows every album in that section. Column count remains responsive to width; collapsed content is limited by the resulting column count, not a fixed number of albums. Do not use horizontal scrolling as the expansion behavior.
- Persist the two expansion states independently across launches. Sharing changes move an album between sections without changing its ID, pin, or saved photo position. Retain existing album-name ordering within each section.
- Show both section headings, including when a section is empty. Do not show an ineffective expansion control when there are no additional rows.

### Album actions and export

- Right-click any album card or pinned sidebar album to offer the existing four commands: **Download**, **Download to…**, **Download Compressed JPEG**, **Download Compressed JPEG to…**. Use the same command construction and download manager as photo selections.
- Treat an album as a selection of its complete verified membership, without navigating to it, altering the user's active photo selection, or relying on its browser having been opened. Resolve its timeline on demand and pass all ordinals through the existing selection download path.
- Preserve existing download semantics: photo/Live Photo still eligibility, skipped videos, original versus compressed mode, Downloads jobs, cancellation, progress, collision-safe saving, and current single/multiple-item behavior. Report an album with no eligible photos through the download job; do not create an empty download silently.
- Dragging an album to Finder or another file-promise destination exports original photos to that drop location. This is the destination supplied by the drop, using the same machinery as “Download to…”, without opening another folder chooser. Begin metadata resolution and transfer only once a receiver accepts the file promise.
- Proposed packaging default: album drags promise one sanitized album-named ZIP even for a singleton, so the promised name/type does not depend on a metadata fetch during drag initiation. Menu downloads retain the existing path's packaging. Use the existing singleton ZIP wrapping support rather than a separate album exporter. No transfer occurs on cancelled drags or internal pin/reorder operations.

### Sidebar albums and internal drops

- Album context menus include **Add to Sidebar**; adding an existing pin is idempotent. Pinned albums appear under the existing Albums sidebar section, beneath the Albums overview entry, showing a small cover thumbnail and name.
- Persist the ordered unique album ID list per account/NAS namespace. Reordering affects pins only, never the NAS album order or overview sorting. Include **Remove from Sidebar** for pinned entries; this never deletes the album or changes sharing.
- Drag an album card into the Albums sidebar section to pin it at the insertion position. Drag pinned albums to reorder them, with an insertion indicator. Distinguish insertion targets from an album row's photo-membership drop target.
- Drag a selection of photos onto either an overview album card or a pinned album row to add those photos to that album. Do not remove photos from their source collection. Resolve and verify the captured selection before issuing the membership write. Reject stale, cross-account, foreign, or unauthorized drag payloads without exporting or mutating anything.
- This must work from **every timeline using the shared browser**: Personal Library, Favorites, any opened album, Map pin/cluster result timelines, and metadata-filtered timelines over any of those sources (including filtered Map results). Capture exactly the selected items in the displayed timeline; never substitute Personal Library ordinals, the unfiltered source's ordinals, or the entire source collection. Implement this once in the shared browser drag path, with no destination-specific enablement.
- Internal drops must not request promised files. Local album identity and photo-selection representations are separate from the external file-promise representation.
- Clicking a pin opens the same `.album(id)` collection as clicking its overview card, including its header, filter, viewer, and saved scroll position. Closing the opened album returns to the overview. The correct pinned row remains selected when the album is pinned.
- Retain cached pins and their order while offline or while the list is provisional. Prune IDs only after an authoritative complete album list proves that an album is unavailable; never prune because a request failed. Restore cached names/covers where possible.

### Opened-album header

- Add a header before the first photo/day heading containing cover thumbnail, name, capture-date range, sharing status, sharing action, and avatars for named recipients. Follow the supplied reference's information hierarchy while using existing app styling.
- The header scrolls with the album content; it is not another permanently fixed toolbar. It remains present for an empty album and while an album filter has no matches. Its metadata describes the source album, not the filtered subset.
- Sharing status distinguishes unshared, private shared, public view/download, and expired sharing using concise text. A **Share…** or **Manage Sharing…** button opens the sharing settings workflow; never infer permissions from a link alone.
- Show profile pictures for individual recipients with their names on hover and in accessibility labels. Resolve identity/profile data lazily and coalesce requests. Missing pictures, unavailable profiles, or offline requests use a native initials/person fallback with the recipient name still available. Groups use a group fallback; public access is status text, not an invented person avatar. Passwords are never shown in the header.
- Format dates with the existing capture-local date conventions. Empty albums have no invented date range. Header content must fit narrow windows without squeezing the photo grid or causing horizontal scrolling.

## Implementation structure

### 1. Album metadata and repository writes

- Extend `Sources/SynologyAPI/AlbumModels.swift`: retain `owner_user_id`, `shared`, album type and typed `sharing_info` (privacy, expiry/expired, password-enabled flag, named grants and sharing reference/link). Add explicit role/member types that preserve unknown wire values without granting capabilities. Keep DSM UID and Photos internal ID distinct.
- Extend `PhotosTransport.swift` and `SynologyClient.swift` with typed create/add/remove, album-get, sharing-read/write, principal-list and profile-read methods. Reproduce the captured API versions and JSON-inside-form encoding. Model update operations explicitly (`update`/`delete`) rather than treating permission arrays as replacement state. Use an explicit password change enum (unchanged/set/clear) so an omitted value and JSON `""` are not confused.
- Add `Sources/PhotoCache/CachedPhotosRepository+AlbumMutations.swift` and `+AlbumSharing.swift` behind the shared actor, with APIs such as `createAlbum(name:itemIDs:)`, `addItems(_:toAlbum:)`, `removeItems(_:fromAlbum:)`, `albumSharing(_:)`, and `updateAlbumSharing(_:changes:)`. Coordinate writes with metadata admission and collection mutation generations; refresh list count/cover, affected catalog/membership, and dependent filters through the existing engine. Do not build a second album cache or Diff consumer.
- Handle API-envelope failures and nonempty per-item errors without claiming complete success. Refetch authoritative album membership after ambiguous/partial outcomes. Fence old admitted reads so they cannot overwrite post-mutation state. Sharing-only changes refresh album/access metadata without invalidating unrelated Personal Library item details.
- Sharing setup uses captured `set_shared` plus `update`; changes use explicit public/user grant operations; disable uses `set_shared(false)`. Read back the resulting state. Do not invent atomicity or restore old grants on re-enable. Expose failure after partial success with the actual observed state.
- Update relevant persisted metadata schema versions and recreate incompatible data; no migrations. Never persist passwords, authenticated URLs, tokens, or session IDs in UI preferences or drag representations.
- NAS writes are not authorized merely by this planning task. Follow root `AGENTS.md` before executing any live write probes; local implementation and tests can use sanitized captured fixtures.

### 2. Reusable selection and export inputs

- Add `Sources/PhotoCache/PhotoSelectionSnapshot.swift`: collection descriptor, immutable timeline snapshot/fingerprint, selected ordinal ranges, and known IDs. This represents selected content independently of view focus, responder ownership, or `BrowserCommandSnapshot.active`.
- Preserve the exact source descriptor, including `.mapFilter` and `.libraryFilter`, in that snapshot. `SelectionItemResolver` must call the repository's collection-aware page API, which already dispatches derived collections to their registered membership readers; never pass a session-derived descriptor directly to `SynologyClient.readCollectionBatch` or reinterpret synthetic page offsets against a persistent timeline. Include source-registration/membership authority in validation so an expanding filtered result cannot silently change which IDs an ordinal denotes.
- Retain a repository-owned source-registration lease while an accepted derived-selection operation resolves, releasing it on success/failure/cancellation. Add a typed lease API for existing Map/filter registrations if necessary; changing sidebar focus must not cancel an accepted operation merely because its browser disappears. Actual dependency invalidation or a changed membership proof still fails conservatively before the mutation. Once exact verified IDs are resolved, the write does not depend on an active browser or registration. Do not solve lifetime by copying or rescanning the full source collection.
- Add a bounded `SelectionItemResolver` shared by download and membership resolution. Refactor `SelectionDownloadResolver.swift` to delegate common page verification while retaining its still-image eligibility policy. Membership resolution must not inherit the downloader's video-skipping rule: selected photo/video items supported by normal albums remain eligible for membership.
- Add `AlbumSelectionResolver` in PhotoCache. Acquire a verified `.album(id)` timeline using the current repository stream, build the full ordinal range and immutable selection, then use the common selected-page resolver. Keep the existing maximum of two selected-page reads in flight and final fingerprint verification. Incomplete verification, cancellation, or membership changes fail the job rather than silently downloading another selection.
- Avoid expanding a huge range into UI nodes or fake browser selection state. Retain only the metadata needed by the existing item-ID download API; introduce no full-library scan or duplicate collection materialization.
- In `PhotoDownloads.swift`, introduce a typed export source such as `.item`, `.selection`, or `.album` and one shared resolution entry point used by `start` and `fulfillPromise`. Keep cache reuse, Live Photo handling, original/compressed transport, cancellation and saving in the current pipeline. Preserve the existing distinction between individual-photo drag stills and menu download behavior. Remove superseded optional-field payload branches as callers are converted.
- Reuse `photoDownloadMenu` for album menus through a shared action specification that can also build SwiftUI menu content; do not duplicate four labels and their mode mappings independently.

### 3. Drag infrastructure at application scope

Current finding: `PhotoDownloadManager.shared` is already app-wide, and `PhotoFileDragSource` is already a standalone AppKit source. The limitation is its photo/browser-specific payload and lack of internal drag types, not the location of network/download ownership.

- Refactor `PhotoFileDrag.swift` into an application-level `MediaDragCoordinator` with an explicit drag payload enum and packaging policy; rename/replace old types and update `LibraryBrowserView.swift` and `PhotoViewerView.swift` callers. Keep AppKit mouse hit-testing in those views and keep transfers in the existing manager/repository.
- Build the selection payload in `LibraryBrowserScrollView.Coordinator.beginFileDrag` from its current `collection`, `timelineSnapshot`, `LibraryIndex`, and selected ordinals for every shared-browser instance. Do not gate the internal photo-selection representation on `.personalLibrary`, sidebar destination, or whether an external file promise is eligible. The album drop receiver resolves this captured source context, not `LibraryModel`'s current active selection at drop time.
- Advertise a file promise plus one private local representation on the same logical drag item. Local representations identify either an album or an immutable photo selection. Use an in-process session registry and opaque nonce bound to the repository/account, released at drag completion. Do not serialize repository objects, passwords, sharing tokens, or authenticated URLs onto the pasteboard.
- Use an AppKit pasteboard writer/provider adapter capable of advertising the private type alongside the file promise. Verify both representations coexist in one native dragging session; do not start competing SwiftUI and AppKit drag sessions for the same gesture.
- For album payloads, advertise a ZIP filename/type independently of cached count. External completion resolves full album membership on demand. Internal receivers consume only the local type and dispatch pin/reorder/add operations. Source operation masks express external copy, internal photo-add copy, and pinned reorder move as appropriate.
- Add `AlbumDropDelegate`/AppKit drop adapters at album cards and sidebar insertion/row targets. Validate target and source namespaces before accepting. Reject OS file drops: general upload is outside scope. Retain the current at-most-20-photo preview limit for selection drags and use an existing cover for album drags.

### 4. Overview, pin persistence, and navigation

- Add `Sources/SynoTimelineApp/AlbumPresentationStore.swift`, owned at app/window-shell scope and keyed by stable account/NAS namespace. Store independent section expansion flags and ordered pin IDs. Implement idempotent add/remove, reorder-by-ID, and authoritative missing-ID reconciliation. Publish changes so multiple windows stay consistent. Unknown schema versions are discarded.
- Refactor `AlbumsOverviewView.swift` into two reusable section views with a shared responsive-column calculation, card presentation, context menu, drag source, and photo drop target. Make `AlbumCardView` reusable outside its current private scope as needed. Extend `AlbumCoverView` with a sizing/style parameter for cards, sidebar thumbnails and header covers; retain repository cache reuse and view-scoped decoding.
- Add `AlbumSidebarSection.swift` to keep pin rows, drop positioning and reorder feedback out of `AppShellView.swift`. The shell supplies the shared presentation store and open-album action. Load the cached-first album list when pins need names/covers, even if the overview has not been opened.
- In `NavigationRestoration.swift`, introduce an explicit sidebar selection (`destination` or `albumID`) while mapping all album content to the existing opened album/collection route. Update `AppShellView` selection and `openAlbum`/`closeAlbum` consistently so pin clicks do not leave Albums-overview selection and pinned-row selection competing. Bump the navigation format and discard the older format without a compatibility decoder. Preserve current collection anchor behavior in the new format.

### 5. Header and sharing presentation

- Add `AlbumHeaderView.swift` and `AlbumHeaderModel.swift` driven by `LibraryModel` album summaries plus repository sharing/profile reads. Add `AlbumSharingSheet.swift` for enable/disable, link copying, privacy, Viewer/Downloader grants, password and expiry changes supported by the capture. Provider and incoming-invitation browsing remain separate scope unless requested.
- Fetch recipient identities with observed `SYNO.Foto.UserInfo` v1 `get` and Photos internal IDs (grant `db_id` where validated), then use returned profile-photo descriptors and the observed `SYNO.Personal.Profile.Photo` path. Keep these descriptors opaque and scoped to the configured NAS/authentication. Add typed profile models/transport reads and bounded repository-coalesced avatar loading; use fallback avatars on missing/unsupported descriptors rather than probing broadly.
- Add a header slot to the shared browser pipeline in `LibraryBrowserView.swift` and `LibraryBrowserScrollView`. Host the SwiftUI header in the existing flipped AppKit document ahead of the grid. Keep toolbar safe-area inset separate from measured header height. Extend `Sources/PhotoCache/LibraryViewportGeometry.swift` with a content-origin/header-height input so all photo frames, hit-testing, marquee, reveal/restore and viewer source rectangles share the same offset.
- Header space is presentation geometry, never an item ordinal or timeline day. Header clicks must not start marquee/photo drag. Resize/height updates preserve the current visible photo anchor; the header scrolls away naturally. Keep shared browser code generic with a header configuration rather than branching its pager for albums. Render the header also in loading/empty/filter-empty branches without creating a second scroll view around the browser.
- The day navigator continues to address populated photo days, excluding header height. Album filters keep showing the source header, and Back/Escape/viewer transitions retain their existing behavior. All new shortcuts, if any, must be defined by named macOS menu commands.

## Delivery order and verification

Implement in the numbered order below. Complete and verify **all seven normal-album steps before starting any shared-album issue**. GitHub issue bodies include technical dependencies and the complete sequence; native blocking relationships enforce the preceding step as well as earlier technical prerequisites.

| Order | Phase | Issue | Technical dependencies |
| --- | --- | --- | --- |
| 01 | Normal albums | [#58 — Album creation and membership mutations](https://github.com/finia2NA/syno/issues/58) | None |
| 02 | Normal albums | [#59 — Membership commands from any timeline selection](https://github.com/finia2NA/syno/issues/59) | #58 |
| 03 | Normal albums | [#60 — Complete-album downloads](https://github.com/finia2NA/syno/issues/60) | #59 |
| 04 | Normal albums | [#61 — Scrolling album header](https://github.com/finia2NA/syno/issues/61) | #58 |
| 05 | Normal albums | [#62 — Persistent sidebar pins and navigation](https://github.com/finia2NA/syno/issues/62) | #60, #61 |
| 06 | Normal albums | [#63 — Album drag export, pinning and reorder](https://github.com/finia2NA/syno/issues/63) | #60, #62 |
| 07 | Normal albums | [#64 — Photo-selection drops from every timeline](https://github.com/finia2NA/syno/issues/64) | #59, #63 |
| 08 | Shared albums | [#65 — Shared overview sections, status and recipient avatars](https://github.com/finia2NA/syno/issues/65) | #61, #62, #64; entire normal-album phase complete |
| 09 | Shared albums | [#66 — Private sharing management](https://github.com/finia2NA/syno/issues/66) | #65 |
| 10 | Shared albums | [#67 — Public access, password and expiry](https://github.com/finia2NA/syno/issues/67) | #66 |

All issues carry `albums`; steps 08–10 additionally carry `sharedalbums`. Existing backlog issues #5 (membership), #31 (pins/quick-add shortcuts), and #52 (create/rename/delete) are related; this sequence does not add their deferred rename/delete or Cmd+1–9 shortcut scope.

Meaningful automated checks belong in the existing SynologyAPI, PhotoCache and app test suites: captured mutation encoding/readback; partial-error handling; album export without opening its browser; rejection of stale membership/selection; independent section/pin persistence and account isolation; correct internal-versus-external drag dispatch without duplicate writes/downloads; packaging for singleton/mixed/video-only albums; and header-offset geometry preserving photo anchors/hit tests. Update existing navigation/drag/download tests to the new interfaces rather than retaining obsolete formats. No snapshot tests that merely mirror view layout are required.

For selection-to-album drops, exercise a source matrix covering Library, Favorites, an album, Map results, filtered Library/Favorites/album, and a filtered Map result. Use different IDs at matching ordinals in the displayed and underlying collections to prove the resolver chooses the displayed selection. Cover selected items across unloaded pages, filter membership changing during a drag, source-view dismissal after drop acceptance, and target-album refresh after success. Verify each case adds only the expected IDs and never invokes the download/file-promise path for an internal drop.

Manual acceptance (computer use only if explicitly requested): one-row behavior across resize; independent expansion restoration; shared/unshared section movement; all four album download commands; cancelled versus accepted external drag; pinning via menu and drag; pin reorder across launches; selection drops from Library, Favorites, another album, Map results, and metadata-filtered versions of each (including filtered Map results); offline pins; header on empty/filtered albums; avatar names/fallbacks; header scroll and viewer open/close destinations. Run normal build/tests appropriate to each completed slice. Do not perform live NAS write tests without the required authorization.

## Remaining information

No additional UX clarification is needed to record this plan. The collapsed-row behavior is explicitly confirmed. The owner-first shared/unshared sections use the currently supported normal album list. Incoming-album discovery, actual recipient download addressing, and Provider contribution need focused captures only if those capabilities enter scope. Avatar reads have captured endpoints and profile descriptors; implement conservative fallback pictures if the current server's profile descriptor is unsupported. No additional capture is required merely to design the header.

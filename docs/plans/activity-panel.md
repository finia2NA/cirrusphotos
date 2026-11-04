# Activity panel (issue #89)

Goal: one toolbar item replaces the Uploads, Downloads and Connection/Refresh items. It shows connection state, running work and unseen failures. Its popover has two tabs:

- **Activity** (default): what needs attention, transfers, changes in flight, and notices.
- **History**: a summarized log of every settled user-initiated change and transfer in this session.

Failures no longer appear as modal alerts. They open the panel without taking keyboard focus.

Read `CLAUDE.md`/`AGENTS.md`, `docs/PROJECT.md` (sections "Library, Favorites, and albums", "Viewer and Info panel", "Cache and network behavior", "Mutations and freshness") and `docs/ARCHITECTURE.md` (the `RepositoryError` paragraph, selection contract, favorites/annotations/album mutation paragraphs) first. Do not commit unless the user asks. Do not launch, quit or restart the app; the user runs it. Building and running tests is fine. Ask the user to do the UI checks listed under each slice.

Work in four slices, A → D. Each slice must build and pass `swift test` before the next one starts.

## Hard rules

- The repository stays UI-agnostic. `PhotoCache` never imports or calls the activity model. The app tracks work at its call sites; the repository only gains the result detail those call sites need (failed IDs, chunk progress).
- Every place that starts a NAS change or a transfer is listed in the inventory below and must be tracked. If you find one that is not listed, track it the same way and mention it in your report.
- Retry is offered only where the inventory says so. Rotation, deletion, album creation and album removal are never retried: repeating them is unsafe, or the outcome is uncertain.
- History is session-only. Nothing is persisted. No undo.
- Do not add a keyboard shortcut without a menu-bar command (see slice A, step 9).
- Logging stays as is: every failure still goes through `RepositoryError.record` (via `reportedFailure` or the handle's `fail`), so Console output is unchanged.

## UX contract (what "done" looks like)

**Toolbar item.** One icon-only button (`ToolbarItem(id: "activity", placement: .primaryAction)`) with three layers:

1. Base glyph = connection state. Suggested SF Symbols: `externaldrive.badge.checkmark` (connected), `externaldrive.badge.exclamationmark` (signed in, but the last Refresh or the library load failed, so cached content is shown), `externaldrive.badge.xmark` (login failed), `externaldrive` at secondary opacity (not started / logging in). The user may adjust symbols after seeing them.
2. A thin progress ring around the glyph while anything runs, including Refresh. The ring is determinate when exactly one transfer reports a fraction, otherwise indeterminate (rotating arc).
3. A red dot at the top-right while unseen failures exist.

The help text summarizes all three, e.g. "Connected · 2 running · 1 failed". The accessibility label is "Activity".

**Popover header.** Connection status text (today's `ConnectionToolbarItem` strings: "Connected", "Metadata unavailable", "Logging in…", "Login failed", "Opening library…", "Library unavailable", with the same `.help` details) and the Refresh button (moved here). Then a segmented picker: **Activity | History**.

**Activity tab sections, in order** (empty sections hidden):

1. **Needs attention**: failed or unconfirmed entries of any kind, newest first.
2. **Transfers**: downloads, edit handoffs, file promises and uploads, whether running, queued or finished. Finished transfers stay until dismissed or cleared (like Safari downloads).
3. **In progress**: running or queued short changes, e.g. "Favoriting 30 photos".
4. **Notices**: connection lost/restored, a failed full-photo load, and other non-actionable information (slice D).

A short change that succeeds leaves Activity immediately and appears in History. A failure stays in Needs attention.

**Rows.**
- Title from the wording table below.
- Secondary line: status or error message.
- Progress bar for running transfers.
- Trailing controls: **Cancel** on running cancellable transfers. An **X** (dismiss) on every settled entry and every notice. Running entries have no X.
- A failed entry with items has a disclosure chevron. Expanded, it lists one row per failed item: a cached `sm` thumbnail (or a file/photo symbol), the filename, and per-item **Retry** (if retryable) and **X**.
- Clicking a photo row reveals the photo in the browser when possible (slice C).
- The failed entry itself has **Retry All** (if retryable).

**Footer.** Activity tab: **Retry All Failed** (only when any retryable failure exists) and **Clear**, which removes every settled entry and notice and keeps running and queued ones. History tab: **Clear History**.

**History rows.** One row per summarized record, e.g. "Favorited 20 photos", "Added 12 photos to Trip", "Favorited 47 of 50 photos" (partial), "Deleting 3 items failed". The record keeps its items, and a chevron expands them. Each row has an X.

**Merging History records.** A new record merges into the newest one when all of these hold:
- both are fully succeeded;
- same `ActivityKind` (same kind and target, e.g. `.favorite(true)`, `.rating(4)`, `.addToAlbum(id:)`);
- the newest record finished at most 60 s before the new one finished.

Merging adds the counts, appends the items and updates `finishedAt`. Partial, failed, unconfirmed and cancelled records never merge.

**Opening automatically on failure.**
- When an entry becomes failed or unconfirmed (not cancelled), the panel opens on the Activity tab, scrolls to the entry and highlights it for about 1.5 s.
- It does not open if it is already open, if it opened automatically less than 10 s ago (the red dot still appears), or if the window is in native full screen with its toolbar hidden (the dot appears when the toolbar is revealed).
- It must not take keyboard focus: arrow keys and `.` must keep reaching the browser or viewer while it is open. See slice B, step 1.
- "Record-only" actions (sheets with their own inline error, see the inventory) never open the panel.

**Unseen failures** are cleared when the popover is shown with the Activity tab selected.

**Limits.** Keep at most 500 History records and 200 settled Activity entries; drop the oldest settled ones first. Running entries are never dropped.

### Wording

Use "photo/photos" for actions that only accept stills (favorites, rotation, ratings, tags, downloads) and "item/items" for actions that include videos (album membership, deletion). `n` = remaining while running, total when settled.

| Kind | Running | Succeeded (History) | Failed (Activity title) |
|---|---|---|---|
| `.favorite(true/false)` | Favoriting n photos / Unfavoriting n photos | Favorited n photos / Unfavorited n photos | Favoriting failed for n photos |
| `.rotate(dir)` | Rotating n photos | Rotated n photos left/right | Rotating failed for n photos |
| `.rating(r)` | Rating n photos ★★★ (0 → "Clearing rating of n photos") | Rated n photos ★★★ / Cleared rating of n photos | Rating failed for n photos |
| `.addTags(names)` / `.removeTags(names)` / `.newTag(name)` | Tagging n photos "a, b" / Removing "a" from n photos | Tagged … / Removed … | Tagging failed for n photos |
| `.addToAlbum(id, name)` / `.addToIncomingAlbum(name)` | Adding n items to Name | Added n items to Name | Adding to Name failed |
| `.createAlbum(name, itemCount)` | Creating album Name | Created album Name (with n items) | Creating Name failed |
| `.removeFromAlbum(id, name)` | Removing n items from Name | Removed n items from Name | Removing from Name failed |
| `.deleteAlbum(name)` | Deleting album Name | Deleted album Name | Deleting Name failed |
| `.deleteItems` | Deleting n items | Deleted n items | Deleting failed for n items |
| `.download(name)` / `.editHandoff(name, app)` / `.filePromise(name)` | name + status line ("Downloading…", "Saving…") | Downloaded name / Opened name in App / Exported name | name failed |
| `.upload(destinationName)` | Uploading n photos to Dest | Uploaded n photos to Dest | Uploading failed for n files |
| record-only: `.renameAlbum(from,to)`, `.renamePerson(name)`, `.mergePerson(source,target)`, `.albumSharing(name)` | — | Renamed album A to B, etc. | (History only) "Renaming album A failed" |

An unconfirmed outcome uses the failed title plus the status line "May have been applied. Refresh to check." Cancelled: "Cancelled" status, goes to History, never to Needs attention.

## Inventory: where changes start, and how each is treated

"Tracked" = `begin` → handle → settle (auto-opens on failure). "Record-only" = the existing sheet keeps its inline error and waits for the result; on completion it calls `record` (History only).

| Action | Call site today | Treatment | Retry |
|---|---|---|---|
| Browser/Info-panel favorite | `LibraryModel.executeFavoriteAction` (`LibraryModel+Favorites.swift`) | Tracked, count-down by chunk, failed IDs per item | Yes (absolute target) |
| Viewer favorite | `PhotoViewerPresentation.toggleFavorite` → `PhotoViewerSession.toggleFavorite` | Tracked | Yes |
| Browser rotation | `LibraryModel.rotateSelection` (`LibraryModel+Rotation.swift`) | Tracked | No (relative; an unconfirmed retry would double-rotate) |
| Viewer rotation | `PhotoViewerPresentation.rotate` | Tracked | No |
| Rating / add / remove tags | `LibraryModel.run(_:on:)` (`LibraryModel+Annotations.swift`) | Tracked; all items listed on failure (the write is chunked but the per-item result is not known) | Yes for rating/add/remove; no for new tag |
| Add to album (sheet, menu, drag onto card/pin) | `submitAlbumOperation` `.add`, `addCapturedSelection(_:sourceAlbumID:to: Int64)` | Tracked, serialized (see B.4); the sheet closes on submit | No in this plan (needs a re-verifying repository API; follow-up) |
| Add to incoming album | `addCapturedSelection(_:sourceAlbumID:to: PhotoCollectionDescriptor)` | Tracked, serialized | No |
| Create album (empty or with selection) | `submitAlbumOperation` `.create` | Tracked, serialized | No (never retried; see ARCHITECTURE) |
| Remove from album | `submitAlbumOperation` `.remove` | Tracked, serialized | No |
| Delete album | `LibraryModel.deleteAlbum` | Tracked, serialized | No |
| Delete items | `LibraryModel.confirmItemDeletion` | Tracked; the sheet closes on confirm | No |
| Rename album | `AlbumRenameView` | Record-only | — |
| Rename/merge person | `PersonEditView` | Record-only | — |
| Album sharing save | `AlbumSharingSheet` | Record-only | — |
| Download (menu, album card) | `PhotoDownloadManager.start` | Tracked transfer | Yes |
| Edit With | `PhotoDownloadManager.edit` | Tracked transfer | Yes |
| File promise (drag-out) | `PhotoDownloadManager.fulfillPromise` | Tracked transfer | No (the receiver's promise is consumed) |
| Finder upload | `PhotoUploadManager.start` | Tracked transfer, one entry per drop | Yes (failed files only; the NAS ignores duplicates) |
| Refresh | `LibraryModel.refresh` | Ring while running; failure → Needs attention (slice D) | Retry = Refresh |
| Thumbnail-only rotation / Fix Thumbnail Rotations | `rotateThumbnailPreviews`, `fixThumbnailRotations` | Unchanged (has its own modal progress and log). Follow-up candidate. | — |
| Cache clear / metadata revalidation / warming | Settings, warming windows | Unchanged (not NAS changes) | — |

## Types (new file `Sources/SynoTimelineApp/ActivityCenter.swift`)

```swift
import Foundation
import PhotoCache
import SynologyAPI

enum ActivityTab: Hashable { case activity, history }

/// What an activity does. Equatable values decide History merging, so include the target.
enum ActivityKind: Equatable, Sendable {
    case favorite(Bool)
    case rotate(PhotoRotationDirection)
    case rating(Int)
    case addTags([String]), removeTags([String]), newTag(String)
    case addToAlbum(id: Int64, name: String), addToIncomingAlbum(name: String)
    case createAlbum(name: String), removeFromAlbum(id: Int64, name: String), deleteAlbum(name: String)
    case deleteItems
    case download(name: String), editHandoff(name: String, application: String), filePromise(name: String)
    case upload(destination: String?)
    case renameAlbum(from: String, to: String), renamePerson(name: String)
    case mergePerson(source: String, target: String), albumSharing(name: String)

    var isTransfer: Bool { /* download, editHandoff, filePromise, upload */ }
    /// Kinds whose newer action replaces an older failure for the same photo.
    var supersedeFamily: SupersedeFamily? { /* .favorite → .favorite, .rating → .rating, else nil */ }
}

enum SupersedeFamily: Hashable { case favorite, rating }

struct ActivityItem: Identifiable, Sendable {
    enum Reference: Sendable {
        case photo(PhotoItem, collection: PhotoCollectionDescriptor)
        case file(URL)
    }
    let reference: Reference
    var id: String { /* "photo:<id>" or "file:<path>" */ }
    var name: String { /* filename ?? "Photo", or lastPathComponent */ }
    var photoID: Int64? { /* for supersede and retries */ }
}

enum ActivityPhase: Equatable { case queued, running, succeeded, failed, unconfirmed, cancelled
    var isSettled: Bool { self != .queued && self != .running }
}

/// What the user sees for a failure, plus what "Copy Details" needs (slice D).
struct ActivityFailure: Sendable {
    let message: String          // RepositoryError.localizedDescription
    let operation: String        // the operation string passed to RepositoryError.record
    let errorKind: String        // RepositoryError case name (make `caseName` internal→public `kindName`)
    let underlying: [String]     // filled in slice D
    let date: Date
}

/// Starts a new tracked activity for the given items. Returns false when it could not start
/// (for example another upload is running); the center then restores the items.
typealias ActivityRetry = @MainActor ([ActivityItem]) -> Bool

struct ActivityEntry: Identifiable {
    let id: UUID
    var kind: ActivityKind       // var: ActivityHandle.rename
    let startedAt: Date
    var phase: ActivityPhase
    var items: [ActivityItem]
    var totalCount: Int
    var completedCount = 0
    var fraction: Double?        // byte progress (transfers)
    var status: String?          // "Saving…", "Uploading 3 of 5: IMG_1.HEIC"
    var failure: ActivityFailure?
    var failedItems: [ActivityItem] = []
    var savedURL: URL?           // transfers: Show in Finder
    var finishedAt: Date?
    var cancel: (@MainActor () -> Void)?
    var retry: ActivityRetry?
    var isNotice = false         // slice D
}

enum HistoryOutcome: Equatable { case succeeded, partial(failed: Int), failed, unconfirmed, cancelled }

struct HistoryRecord: Identifiable {
    let id: UUID
    let kind: ActivityKind
    var outcome: HistoryOutcome
    var count: Int               // succeeded items (or 1 for item-less actions)
    var items: [ActivityItem]
    var finishedAt: Date
    var failure: ActivityFailure?
}

@MainActor
struct ActivityHandle {
    let id: UUID
    unowned let center: ActivityCenter
    func start()                                   // queued → running
    func progress(completed: Int)                  // count-down; clamps to totalCount
    func progress(fraction: Double?)
    func status(_ text: String?)
    func rename(_ kind: ActivityKind)              // e.g. the download name once resolved (entry.kind is `var`)
    func setItems(_ items: [ActivityItem])         // items known only after resolving; also sets totalCount
    func discard()                                 // removes the entry without a History record
    func succeed(savedURL: URL? = nil)
    /// Records the error through RepositoryError.record, then settles as failed, or as
    /// unconfirmed for RepositoryError.unconfirmed. CancellationError settles as cancelled.
    /// `failedItems` nil means all items failed. Returns the user-facing message.
    @discardableResult
    func fail(_ error: any Error, operation: String, failedItems: [ActivityItem]? = nil) -> String
    func cancelled()
}

@MainActor @Observable
final class ActivityCenter {
    static let shared = ActivityCenter()
    init(now: @escaping () -> Date = Date.init)

    private(set) var entries: [ActivityEntry] = []        // newest first
    private(set) var history: [HistoryRecord] = []        // newest first
    var isPresented = false
    var selectedTab: ActivityTab = .activity
    private(set) var highlightedEntryID: UUID?
    private(set) var unseenFailureIDs: Set<UUID> = []
    /// Set by the toolbar item; false while native full screen hides the toolbar.
    var canAutoPresent = true

    var attention: [ActivityEntry] { get }   // failed/unconfirmed
    var transfers: [ActivityEntry] { get }   // isTransfer, not failed/unconfirmed
    var inProgress: [ActivityEntry] { get }  // !isTransfer, queued/running
    var notices: [ActivityEntry] { get }
    var hasRunningTransfers: Bool { get }
    var runningCount: Int { get }
    var singleTransferFraction: Double? { get }

    func begin(_ kind: ActivityKind, items: [ActivityItem], totalCount: Int? = nil, queued: Bool = false,
               cancel: (@MainActor () -> Void)? = nil, retry: ActivityRetry? = nil) -> ActivityHandle
    func record(_ kind: ActivityKind, outcome: HistoryOutcome, items: [ActivityItem] = [], failure: ActivityFailure? = nil)

    func dismiss(_ entryID: UUID)                          // settled entries and notices only
    func dismiss(itemID: String, from entryID: UUID)       // removes one failed item; removes the entry when none remain
    func dismissHistory(_ recordID: UUID)
    func clearActivity()                                   // removes every settled entry and notice
    func clearHistory()
    func retry(_ entryID: UUID, itemIDs: Set<String>? = nil)   // nil = all failed items
    func retryAllFailed()
    func markFailuresSeen()
    func present(highlighting entryID: UUID? = nil)        // used by auto-open and Edit With
    func supersede(_ family: SupersedeFamily, photoIDs: Set<Int64>)
}
```

Behavior details the implementation must match:

- `begin`: inserts at index 0. `totalCount` defaults to `max(items.count, 1)`. Phase `.queued` or `.running`. If `kind.supersedeFamily` is set, call `supersede` with the photo IDs first.
- `succeed` on a non-transfer: remove the entry from `entries`, then append History with outcome `.succeeded`, `count = totalCount`. On a transfer, keep the entry (phase `.succeeded`, `finishedAt`, `fraction = 1`) and append History.
- `fail`: if `failedItems` is a strict subset, History gets `.partial(failed:)` with `count = totalCount - failed.count` and only the succeeded items. Otherwise History gets `.failed`/`.unconfirmed`. The entry stays, with `failedItems`, `failure` and phase set. Then `requestAttention(entryID)`.
- `requestAttention`: insert into `unseenFailureIDs`. If `!isPresented && canAutoPresent && (lastAutoPresent == nil || now - lastAutoPresent >= 10 s)`, call `present(highlighting:)` and set `lastAutoPresent`. `present` sets `selectedTab = .activity`, `highlightedEntryID`, `isPresented = true`. Clear `highlightedEntryID` after 1.5 s with a `Task.sleep`.
- `retry`: take the requested failed items, remove them from the entry (remove the entry if `failedItems` becomes empty), then call `entry.retry?(items)`. The retry closure starts a new tracked activity. If it returns false, put the items (and the entry, if it was removed) back unchanged.
- `supersede`: for every failed/unconfirmed entry whose `kind.supersedeFamily == family`, remove failed items with those photo IDs; drop entries that become empty.
- History append implements the merge rule from the UX contract. Trim to 500.
- Settled-entry trim to 200 (oldest settled first).

Put the wording table in an extension in `Sources/SynoTimelineApp/ActivityWording.swift`: `func title(for entry: ActivityEntry) -> String` and `func title(for record: HistoryRecord) -> String`.

## Slice A: model, panel and toolbar item; transfers moved

Status: implemented. Differences from the text below, which later slices should follow:
- `begin` also takes an optional `id:`, so a `cancel` closure can capture the entry's id.
- `ActivityHandle` also has `setRetry(_:)`, which sets a retry once resolution makes one possible.
- `fail` also takes `note:` (shown under the error; it replaces the status) and `logs:` (false when the caller already logged the error, as uploads do per file).
- `ActivityKind.mergesInHistory` limits History merging to counted bulk changes. Transfers and named one-off actions never merge.
- `ActivityFailure.unconfirmed` carries the unconfirmed flag.
- Per-item rows with Retry and X already exist, used by uploads. Slice C still adds reveal.
- Toolbar symbols (user's choice): `icloud` (connected or connecting, the latter dimmed), `icloud.slash` (degraded or failed), `exclamationmark.icloud` (connected while failures remain in Activity), `arrow.trianglehead.2.clockwise.rotate.90.icloud` with a rotate effect while anything runs, each `.fill` while the panel is open. The ring is drawn only for determinate single-transfer progress.

1. Create `ActivityCenter.swift` and `ActivityWording.swift` as specified. Make `RepositoryError.caseName` public as `kindName` (`Sources/PhotoCache/RepositoryError.swift`) and use it in `record` as well.
2. Tests: create `Tests/SynoTimelineAppTests/ActivityCenterTests.swift` (inject `now`). Cover:
   - lifecycle: success removes a non-transfer and keeps a transfer;
   - a failure stays and sets unseen;
   - `clearActivity` keeps queued/running entries;
   - `dismiss` refuses running entries;
   - per-item dismiss and removal of the empty entry;
   - merging: same kind within 60 s merges; different target, partial, or more than 60 s apart do not;
   - the 500/200 caps;
   - `supersede`;
   - `retry` removes items and invokes the closure with exactly those items;
   - auto-present throttling at 10 s and with `canAutoPresent = false`;
   - wording for singular/plural and the count-down title.
3. **Downloads** (`PhotoDownloads.swift`): `PhotoDownloadManager` keeps `tasks`, the save/unzip helpers and the cancellation logic. Remove `jobs`, `isPresented`, `PhotoDownloadJob`, `clearFinished`, `update` and `DownloadsToolbarControl`.
   - Add `init(activity: ActivityCenter = .shared, …)`.
   - In `start`, `edit` and `fulfillPromise`: `let handle = activity.begin(.download(name:) / .editHandoff / .filePromise, items: [], cancel: { [weak self] in self?.cancel(id) }, retry: …)`, where `id` is the handle's `id` so `tasks[handle.id]` works.
   - Replace each `update(id) { … }` with `handle.status(…)`, `handle.progress(fraction:)` or `handle.succeed(savedURL:)`.
   - The final name is known only after resolving, so add `ActivityHandle.rename(_ kind: ActivityKind)`. It replaces the entry's kind before it settles (the entry's `kind` becomes `var`).
   - Replace the catch blocks with `handle.fail(error, operation: "Download"/"File promise")`. Cancellation settles as cancelled through `fail`.
   - Retry for `start`: add `case items([PhotoItem], collection: PhotoCollectionDescriptor)` to `PhotoDownloadSource`. `resolve` returns the items, `collection` returns the collection, `initialName` uses `jobName`. The closure calls `start(repository:source: .items(resolvedItems, collection:), kind:, directory:)`, which needs a `start` overload taking a directory instead of `choose`; `start(…choose:)` calls it after `chooseDirectory`. An `.album`/`.incomingAlbum` source can retry with the same source.
   - Retry for `edit`: re-call `edit` with the same arguments, except pass the resolved `item` and `selection: nil`.
   - `fulfillPromise`: no retry.
   - `edit` previously set `isPresented = true`; call `activity.present()` instead.
   - `cancelAll()` cancels all tasks; the handles settle as cancelled from their tasks.
   - `hasActiveJobs` → `!tasks.isEmpty`.
4. **Uploads** (`PhotoUploads.swift`): keep `PhotoUploadManager`'s one-batch-at-a-time rule and `task`, `thumbnailPolls`, `fileURLs` and `cancel`. Remove `presented`, `status`, `progress` and `UploadsToolbarControl`. Keep `active`, which the drop targets read.
   - In `start`: `let items = urls.map { ActivityItem(reference: .file($0)) }` and `let handle = activity.begin(.upload(destination: destinationName), items: items, cancel: { [weak self] in self?.cancel() }, retry: { [weak self] retryItems in _ = self?.start(retryItems.compactMap(\.fileURL), repository:, destination:, destinationName:, finished:) })`.
   - Per file: `handle.status("\(index + 1) of \(urls.count): \(name)")`, `handle.progress(fraction:)`, and `handle.progress(completed: completed + failed)` after each file.
   - At the end: no failures → `succeed()`. Otherwise `fail(firstError, operation: "Upload", failedItems: failedFileItems)`. Keep each file's message: store a per-item message in `ActivityItem` (add `var message: String?`) and show it on the item row.
   - Cancelled → `cancelled()`, status "Upload cancelled. Check the destination before retrying."
   - A retry while another upload is active returns false, so `ActivityCenter.retry` leaves the failed items in place.
5. **Close guard**: `confirmStoppingDownloads()` checks `PhotoDownloadManager.shared.hasActiveJobs || PhotoUploadManager.shared.active` (unchanged API) and keeps its alert.
6. **Toolbar item** (new `Sources/SynoTimelineApp/ActivityToolbarItem.swift`): `struct ActivityToolbarItem: View` reads `@Environment(LibraryModel.self)` and `ActivityCenter.shared` (via `@State private var activity = ActivityCenter.shared` or an environment value).
   - Draws the three-layer icon from the UX contract at `ToolbarMetrics.controlHeight`. The progress ring is a `Circle().trim` stroke, 1.5 pt, accent color. Indeterminate = a rotating 25 % arc; with Reduce Motion, a static full ring at 40 % opacity.
   - Button toggles `activity.isPresented`; `.popover(isPresented: $activity.isPresented, arrowEdge: .bottom) { ActivityPanelView() }`.
   - Help and accessibility text as specified.
   - Connection state: add `var connectionState: ConnectionState` to `LibraryModel` with cases `.connecting`, `.connected`, `.degraded(String)`, `.failed(String)`. Derive it from `authenticationStatus`, `error(for: .library(.personal))` and `refreshFailure`, using exactly the label logic now in `ConnectionToolbarItem`. Delete `ConnectionToolbarItem` from `LibraryControls.swift`.
   - Running work includes `library.isRefreshing || library.isLoading`.
7. **Panel** (new `Sources/SynoTimelineApp/ActivityPanelView.swift`): width 380, list max height 460, `ScrollViewReader` scrolling to `highlightedEntryID` on change. Highlight = accent background at 15 % fading out.
   - Header (status text + Refresh button with spinner while refreshing; the button calls `Task { await model.refresh() }` and is disabled under the same condition as the menu command), picker, sections, footer as specified.
   - Each section uses its own `ForEach`.
   - `ActivityEntryRow`: title, status/error line (`.textSelection(.enabled)` on errors), progress, buttons, chevron (`DisclosureGroup` or a custom chevron button).
   - `ActivityItemRow`: thumbnail, name, per-item message, buttons.
   - Thumbnail: for `.photo(item, collection)` with `item.thumbnail != nil`, load once with `repository.thumbnail(descriptor, size: .sm, allowNetwork: false, collection:)` and take the first `.value` (decode with `NSImage(data:)`). Otherwise use `Image(systemName: "photo")` / `"doc"`. Do not fetch from the network.
   - "Show in Finder" button on succeeded transfers with `savedURL`: `NSWorkspace.shared.activateFileViewerSelecting([url])`.
   - `HistoryRow`: title, relative time (`Text(record.finishedAt, style: .relative)` + " ago"), chevron for items, X.
   - Call `activity.markFailuresSeen()` in `onAppear` and when `selectedTab` changes to `.activity`.
8. **AppShellView** (`statusToolbar`): replace the three items with `ToolbarItem(id: "activity", placement: .primaryAction) { ActivityToolbarItem() }`.
9. **Menu command** (`LibraryControls.swift`, `CommandGroup(after: .toolbar)`): `Button("Show Activity") { ActivityCenter.shared.present() }.keyboardShortcut("l", modifiers: [.command, .option])`. If the popover is open, the command closes it (toggle); name it "Show Activity"/"Hide Activity" accordingly.
10. Update existing tests that referenced removed API (`Tests/SynoTimelineAppTests/PhotoDownloadTests.swift` and others found by `grep -rn "jobs\|isPresented\|UploadsToolbarControl" Tests`). Keep their underlying assertions (saved file names, unzip, cancellation) and assert on `ActivityCenter` entries instead of `jobs`.
11. User checks: the toolbar shows one item. Downloads and uploads appear under Transfers with progress, Cancel, finished state, Show in Finder and Clear. Refresh works from the popover and ⌘R. ⌥⌘L toggles the panel. The connection glyph changes on login failure.

## Slice B: short changes tracked; alerts removed; auto-open

Status: implemented except step 1's AppKit fallback (pending the user's focus check). Step 10 replaced the busy gate with a queue (`favoriteWriteTail`) rather than running presses concurrently, so a repeated toggle of the same photo resolves after the previous write instead of failing as busy. Differences from the text below:
- The viewer begins its activity before calling `toggleFavorite()` (which returns `Result<Void, any Error>?`, nil when nothing started) instead of an `onStart` hook; nil discards the activity. Its retry uses the same `FavoriteActivity` path as the browser, not a `LibraryModel` callback.
- Errors before the first chunk stay ordinary errors (not `BatchFavoriteError`); the app treats them as all photos failed.
- `serializedAlbumWrite` (awaitable) backs both `enqueueAlbumWrite` and album rename, so rename also waits its turn. `deletingAlbumID` and `AlbumOperation.writing` are gone; `ItemDeletion.deleting` is gone.
- Selections that fail verification report `ActivityKind.unverified(action:)` ("Rotate failed" etc.) through `LibraryModel.reportUnverified`/`reportNotStarted`.
- "Could Not Load Albums" in the Add to Album submenu is only logged; the menu already says so.

1. **Auto-open without focus.** First verify how a programmatic `isPresented = true` SwiftUI popover behaves. With the panel open, the browser must keep receiving arrow keys and `.`, and the viewer must keep receiving its keys. Ask the user to check this once B.2 is in place.
   - If the popover takes key status, replace the SwiftUI `.popover` with an `NSViewRepresentable` anchor that owns an `NSPopover` (`behavior = .semitransient`, `contentViewController = NSHostingController(rootView: ActivityPanelView())`).
   - For automatic presentation, call `popover.show(relativeTo:of:preferredEdge:)` and then `anchorView.window?.makeKey()`, restoring the window's previous `firstResponder`. A user click still shows it normally.
   - Set `activity.canAutoPresent` from the anchor's window: false when `window.styleMask.contains(.fullScreen)` and the toolbar is not visible.
2. **Favorites, browser and Info panel** (`LibraryModel+Favorites.swift`, `Sources/PhotoCache/CachedPhotosRepository+Favorites.swift`, `RepositoryResources.swift`):
   - Repository: change `setFavoritesBatch(action:)` to `setFavoritesBatch(action:progress:)` with `progress: (@Sendable (_ confirmedIDs: [Int64]) -> Void)? = nil`, called after each successful chunk with that chunk's IDs.
   - Repository: add `public let failedIDs: [Int64]` (failed plus unsubmitted, in order) to `BatchFavoriteOutcome`; keep the counts as computed properties.
   - Repository: if the failure happens before any chunk (`connect` or `itemActionSpace` throws, or the pending-ID busy check), throw `BatchFavoriteError` with all IDs failed, so the app always knows which IDs failed.
   - `setFavorite(itemID:…)` passes `progress` through.
   - Add `public func restricted(to ids: Set<Int64>) -> SelectionFavoriteAction` (filters `affectedIDs`, `sectionsByID` and `itemsByID`; `expectedTimelineFingerprint: nil`). Confirm `setFavoritesBatch` does not depend on the fingerprint, and document it in the doc comment.
   - App: `executeFavoriteAction(_:repository:)` builds items `action.affectedIDs.compactMap { id in action.itemsByID[id].map { ActivityItem(reference: .photo($0, collection: action.collection)) } }`. If an ID has no item, still create the entry with `totalCount = affectedIDs.count`.
   - Then `handle = activity.begin(.favorite(action.targetFavorite), items:, totalCount: action.affectedIDs.count, retry: { [weak self] retryItems in guard let self, let repository = self.repository, repository.namespace == capturedNamespace else { return false }; Task { await self.executeFavoriteAction(action.restricted(to: Set(retryItems.compactMap(\.photoID))), repository: repository) }; return true })`.
   - Call with `progress: { ids in Task { @MainActor in confirmed += ids.count; handle.progress(completed: confirmed) } }`, where `confirmed` is a main-actor counter owned by this call (e.g. a small `final class Counter` captured by the closure).
   - Catch `BatchFavoriteError` → `handle.fail(error.underlyingError, operation: "Favorites", failedItems: items filtered to error.outcome.failedIDs)`. Other errors → `handle.fail(error, operation: "Favorites")`.
   - Resolution failure ("could not be verified") → begin and immediately fail an entry of the same kind with `items: []`, no retry.
   - Delete `browserFavoriteFailure`, `dismissBrowserFavoriteFailure()` and the "Favorite Update Failed" alert. Keep the confirmation alert (more than 5 items) unchanged.
3. **Favorites, viewer** (`Sources/PhotoCache/PhotoViewerSession+Favorites.swift`, `PhotoViewerPresentation.swift`):
   - Change `toggleFavorite()` to `toggleFavorite(onStart: @escaping @Sendable (PhotoItem, _ target: Bool, TimelineSection) -> Void) async -> Result<Void, any Error>?`. It returns nil when a guard prevents starting, calls `onStart` right before `repository.setFavorite`, and returns `.failure(error)` in the catch (keep the existing rollback and `favoriteFailures` assignment so the viewer status line still shows it).
   - `PhotoViewerPresentation.toggleFavorite()`: in `onStart`, hop to the main actor and `begin(.favorite(target), items: [.photo(item, collection)])`. On return, `succeed()` or `fail(error, operation: "Viewer favorite")`.
   - Retry closure: calls a new `LibraryModel.retryFavorite(item:collection:section:target:)`. It wraps `repository.setFavorite(itemID:item:in:collection:to:)` in a tracked entry. Pass it to the presentation through a closure property set when the viewer is created in `AppShellView`, the same way other viewer callbacks are wired.
   - Add a test in `Tests/PhotoCacheTests` (the existing viewer favorite tests) for the nil / success / failure results.
4. **Album writes** (`LibraryModel+Albums.swift`, `AlbumOperationView.swift`):
   - Add `@ObservationIgnored private var albumWriteTail: Task<Void, Never>?` and `func enqueueAlbumWrite(_ handle: ActivityHandle, _ body: @escaping @MainActor () async -> Void)`. It chains `let previous = albumWriteTail; albumWriteTail = Task { await previous?.value; handle.start(); await body() }`. Entries begin with `queued: true`. The repository's album mutations reject concurrent writes (`claimMutation(.album)`); the queue prevents that busy error.
   - `submitAlbumOperation`: after validating, set `albumOperation = nil` (the sheet closes) and enqueue. The kind comes from `operation.kind` (+ album name from `operation.albums`/`albums`; created name from `trimmed`), with items from `operation.selection?.items`. The body is the existing switch; on success call `refreshAfterAlbumOperation` and `handle.succeed()`; on error call `refreshAfterAlbumOperation` and `handle.fail(error, operation: "Album operation")`.
   - The sheet's "Updating album…" state and `writing` flag go away. "Preparing…" (album list / selection loading) stays.
   - `addCapturedSelection(_:sourceAlbumID:to: Int64)`: stop setting `albumOperation` (no sheet). Begin `.addToAlbum(id:, name:)`, where the name comes from `albums` (fallback "album"), with items empty until resolved. Then enqueue a body that runs the existing verification + `addMissingItems`. After resolving, set the entry's items and `totalCount` via a new `handle.setItems(_:)`. Return `true` when started.
   - Same for the incoming-album overload (`.addToIncomingAlbum(name:)`).
   - `sourceAlbumID == albumID` → settle with `succeed()` and no History record: add `handle.discard()`, which removes the entry silently.
   - `deleteAlbum(_:)`: enqueue `.deleteAlbum(name:)`; replace `deletingAlbumID` gating with the queue, but keep `deletingAlbumID` if views use it for a spinner on the card.
   - Remove `albumOperationError` and its alert. In `AlbumMembershipMenu.swift` the "Could Not Load Albums" path currently sets `albumOperationError`; replace it with `RepositoryError.record(error, operation: "Album membership")` only, since the menu item already says so.
   - Remove `albumOperation == nil` from guards whose only purpose was blocking during writes (`canCreateAlbum…` at line 10, `beginItemDeletion`, etc.). Keep it where it prevents two sheets at once.
5. **Deletion** (`LibraryModel+Deletion.swift`, `ItemDeletionView.swift`): `confirmItemDeletion` closes the sheet (`itemDeletion = nil`) and runs a tracked `.deleteItems` entry with the resolved items; no retry. Remove the `deleting` state from the sheet and the "Delete Failed" alert. A resolution failure begins and fails an item-less entry.
6. **Rotation** (`LibraryModel+Rotation.swift`, `PhotoViewerPresentation.rotate`): track `.rotate(direction)` with resolved items (browser) or the viewer item; no retry. Remove `rotationFailure` from both, `dismissRotationFailure()`, and the "Rotation Failed" alert. Keep the viewer's image restore on failure.
7. **Ratings and tags** (`LibraryModel+Annotations.swift`): in `run`, after resolving the action, begin with the matching kind and items from `action.items`. Retry for `.edit(.rating/.addTags/.removeTags)` re-runs `repository.annotate(action.restricted(to:), edit:)` through `run`'s tracking path. Add `restricted(to:)` to `SelectionAnnotationAction` with fingerprint nil; check that `performAnnotation` skips the fingerprint check when it is nil.
   - `.newTag`: no retry.
   - Validation messages now assigned to `annotationFailure` (e.g. line 126 "The selected photos have no tags.", "could not be verified") become an item-less failed entry of that kind.
   - Remove `annotationFailure`, `dismissAnnotationFailure()` and the "Rating or Tag Failed" alert. Keep `annotationBusy` as is.
8. **Record-only sheets**: in `AlbumRenameView`, `PersonEditView` and `AlbumSharingSheet`, after the awaited call succeeds or fails, call `ActivityCenter.shared.record(kind, outcome: .succeeded/.failed, failure:)`. Build the failure with a small `ActivityFailure(error:operation:)` initializer that does not re-log. The sheets keep their own error text and behavior.
9. Tests:
   - `SelectionFavoritesTests` (`Tests/PhotoCacheTests/SelectionFavoritesTests.swift` around lines 554/621): assert `failedIDs` for a mid-batch chunk failure, and that `progress` reports confirmed chunks in order.
   - `SelectionFavoritesAppTests`: replace assertions on `browserFavoriteFailure` with assertions on `ActivityCenter` (inject a fresh `ActivityCenter` into `LibraryModel`: add `activity: ActivityCenter = .shared` to `LibraryModel.init(session:)` and use `self.activity` everywhere in `LibraryModel` extensions).
   - Album queue: two queued adds run in order, and the second starts after the first finishes.
10. Optional, separate step (ask the user before doing it): `toggleSelectionFavorite` ignores a press while `browserFavoriteBusy` is true, so fast favoriting in the browser drops presses. The repository already serializes writes and rejects only overlapping IDs. Removing the global gate would let rapid presses on different photos all run; overlapping ones would become busy failures with Retry.
11. User checks: favorite offline in the browser and in the viewer → the panel opens without stealing keys and the failure lists the photos. Bulk favorite counts down, and partial failure shows "Favorited n of m" in History. Album add from sheet, menu and drag runs without a modal, and two adds queue. Deletion and rotation are tracked. No failure alerts remain.

## Slice C: per-item interaction

Status: implemented. `ActivityCenter.revealableCollection` (set by `AppShellView` to the shown collection while no viewer is open) replaces the planned `canReveal` closure; History item rows reveal too.

1. **Reveal.** Add `var revealHandler: (@MainActor (PhotoItem, PhotoCollectionDescriptor) -> Bool)?` to `ActivityCenter`. `AppShellView` sets it in `.task`/`onAppear`: when no viewer is open and `collection == selectedCollection` (the currently shown browser's descriptor), call `browserBridge.reveal(BrowserRevealRequest(itemID: item.id, dayID: item.utcDayID, sectionOffsetHint: nil, selectOnCompletion: true))` and return true; otherwise return false.
   - `ActivityItemRow` is a button calling it. When it would return false, the row shows `.help("Open <collection title> to show this photo")` and does nothing.
   - To decide that without calling, add `var canReveal: (PhotoCollectionDescriptor) -> Bool`, also set by `AppShellView`.
   - Navigating to another collection and revealing there is a follow-up.
2. Per-item Retry and X, **Retry All** and **Retry All Failed**, wired to `retry(_:itemIDs:)` / `retryAllFailed()` / `dismiss(itemID:from:)`. Retry buttons appear only when `entry.retry != nil`.
3. Supersede: `begin` already calls it for favorites and ratings. Test that a new favorite of a failed photo removes it from the old failure.
4. User checks: expand a failure, retry one photo, retry all, dismiss one, click a row to reveal in the current browser.

## Slice D: notices and Copy Details (overlaps issue #11)

Status: implemented. Notices are entries of `ActivityKind.notice(title:)` with a `noticeKey`. A failed Refresh posts no connection notice (it is already a failure), and a later successful Refresh removes older Refresh failures (`resolveFailures(of:)`). Connection notices come from `didSet` on authentication status, the Refresh failure and collection errors. `ActivityFailure.underlying` lists types and codes only, without messages; the report adds the item list and scrubs `_sid`, `SynoToken`, `passwd`/`password`, `otp_code` and `account` values. Video playback failures remain part of #11.

1. **Notices**: add `func notice(_ title: String, detail: String?, key: String)` to `ActivityCenter`. A notice with the same `key` replaces the previous one. Notices never auto-open, never go to History, and are cleared by Clear and X. Sources:
   - **Connection**: in `LibraryModel`, observe `connectionState` changes (`didSet` on the stored inputs, or a computed-change hook where `authenticationStatus`/`refreshFailure` are assigned). Transition to `.degraded`/`.failed` → notice key `"connection"`: "Can't reach the NAS. Showing cached content." Transition back to `.connected` from either → same key: "Connected to the NAS again." There is no reachability monitor, so these come only from sign-in, startup and Refresh results; say so in the docs.
   - **Refresh**: `LibraryModel.refresh()` catch → a tracked-style failure entry. Add `ActivityKind.refresh`, wording "Refresh failed", retry = `Task { await refresh() }`, no History (Refresh is not a change). Add `ActivityKind.recordsHistory` (false for `.refresh`) and honor it in `succeed`/`fail`. A manual Refresh failure auto-opens.
   - **Viewer full photo**: in `PhotoViewerPresentation.receive`, when the current item's `fullImageStatus` becomes `.failure(message)` and `connectionState == .connected`, post notice key `"viewer:<itemID>"`: "Couldn't load full resolution of NAME". Do not post while degraded or failed (the connection notice covers it). Video playback failures are part of #11.
2. **Copy Details**: an "Copy Details" item in a context menu on failed entries and failed History records. It writes plain text to `NSPasteboard.general`:

   ```
   Cirrus Photos <CFBundleShortVersionString> (<CFBundleVersion>), macOS <ProcessInfo.operatingSystemVersionString>
   <ISO-8601 date> · <operation> · <errorKind>
   Message: <message>
   Underlying: <one line per underlying error>
   Connection: <connectionState description>
   Collection: <descriptor rawValue>
   Items: <id filename>, … (at most 50)
   ```

   - Fill `ActivityFailure.underlying` in `ActivityFailure(error:operation:)`: walk `BatchFavoriteError.underlyingError`, `RepositoryError.server(SynologyAPIError)` → add a public `diagnosticCode` to `SynologyAPIError` covering every case (e.g. `api(1003)`, `http(502)`, `transport`, `invalidResponse`, `configuration`), `URLError.code.rawValue`, and `NSError` domain/code plus `NSUnderlyingErrorKey` recursively (at most 5 levels).
   - Never include the NAS URL, host, session ID, `SynoToken` or credentials. Pass every line through a scrub that removes `_sid=…` and `SynoToken=…` values. Server text appears only as the already-displayed message.
3. Tests: `ActivityFailure` underlying chain for `BatchFavoriteError(.server(.api(…)))` and a nested `NSError`. Scrubbing removes `_sid`. Notice replacement by key. Connection transition notices.
4. User checks: go offline → one connection notice. Refresh offline → failure opens the panel. Back online → "Connected again". Copy Details output pastes correctly.

## Documentation (with the slice that changes the behavior)

- `docs/PROJECT.md`:
  - Rewrite the Downloads paragraph ("The permanent Downloads toolbar button…") and the Uploads sentences ("the Uploads toolbar names it", "The Uploads toolbar shows progress…") in terms of the Activity panel.
  - Update the Refresh bullet ("toolbar icon" → "Activity panel"; add ⌥⌘L Show Activity).
  - In the drag-out bullet, change "progress and failures appear in Downloads" to Activity.
  - Favorites/rotation/annotation/album/deletion failures are now reported in Activity.
  - Album add is non-modal and queued.
- `docs/ARCHITECTURE.md`: add an "Activity" section:
  - The app-owned `ActivityCenter` and its call-site tracking contract.
  - The inventory rule.
  - Session-only History with merging.
  - Retry restricted to repeatable actions, and why rotation/deletion/creation are excluded.
  - Album writes serialized in `LibraryModel`.
  - `BatchFavoriteOutcome.failedIDs` and the `progress` callback.
  - Notices derived from sign-in/startup/Refresh only.
- `AGENTS.md` "Current scope": add a short clause, e.g. "a toolbar Activity panel for connection state, Refresh, transfers, change status with retry, and session history". Do not expand it further.
- Comment on issue #89 with the per-action table from this plan only if the user asks.

## Follow-ups (not in this plan)

- Retry for album adds: needs a repository entry point that re-verifies captured item IDs against a collection without a consumed selection snapshot.
- Reveal across collections (navigate, then reveal).
- Thumbnail-only rotation as a tracked transfer instead of a modal sheet.
- A reachability signal for connection notices.
- #11: viewer progress line, "Medium · Loading" status format, and video buffering/stall states. Implemented outside this plan; see the Viewer status and progress section of `docs/ARCHITECTURE.md`.

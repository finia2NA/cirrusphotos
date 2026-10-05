# Info Panel

Status: Implemented; the Validation checklist below remains useful for manual UI checks.

## Execution order

1. `SynologyAPI`: decode `filesize` and `exif`, add the shared page-additional field list, request it from the client (step 1).
2. `PhotoCache`: build the page cache key from the shared field list (step 2).
3. `PhotoCache`: `SelectionInfoResolver` plus unit tests (step 3).
4. `SynoTimelineApp`: `InfoPanelFormatting` plus unit tests (step 4).
5. `SynoTimelineApp`: `InfoPanelModel` plus unit tests (step 5).
6. `SynoTimelineApp`: `InfoPanelView` and the window configurator (step 6).
7. `SynoTimelineApp`: App scene, Cmd+I command, shell and viewer wiring (step 7).
8. Documentation (step 8).
9. `swift test`, then the manual checklist (Validation).

## Goal

Add a small floating "Info" panel, modeled on Apple Photos' info window, that live-tracks the timeline selection and the full-size viewer:

- No selection: a small placeholder ("Select photos to view info").
- Multiple selected items: count, date range, cumulative file size (e.g. "57 Photos", "Apr 21 – Jul 8, 2026", "1.23 GB").
- One selected item or the viewer's current image: filename, capture date/time, camera, lens, megapixels, pixel dimensions, file size, format badge (HEIF/JPEG/PNG/...), ISO, focal length, aperture, shutter speed (e.g. "ISO 6400", "27 mm", "f/2.8", "1/17 s"). Videos show duration and size instead of camera fields.
- Summon/dismiss with Cmd+I, exposed as a named menu-bar command.
- The window floats above the app, has a small title bar whose close button is the only enabled traffic-light control, and does not appear in Mission Control/Exposé or the Cmd+` window cycle.

Out of scope (explicitly): Add a Title / Caption / Keyword / Location rows, person/face rows, the favorite heart, GPS/address display, EXIF editing.

## Confirmed data availability

A read-only probe (2026-10-06, using `scripts/test_synology_login.py` plumbing) established:

- `SYNO.Foto.Browse.Item` `method=list` **honors `additional: ["...","exif"]`**. Every page response then contains a per-item `additional.exif` object:
  ```json
  "exif":{"aperture":"F2.8","camera":"iPhone 13 Pro","exposure_time":"1/25 s",
          "focal_length":"9.0 mm","iso":"1250",
          "lens":"iPhone 13 Pro back triple camera 9mm f/2.8"}
  ```
- Values are display-ready strings. Items without EXIF (PNG screenshots, videos) return empty strings for all six fields.
- `filesize` is already present in every list item (see `docs/SYNOLOGY_PHOTOS_API.md` item-response shape) but is not decoded by `PhotoItem` today.
- `docs/captures/favorites.har` shows the web client's per-item `Browse.Item method=get` info-panel request; the web client does not bundle `exif` in lists, but the server accepts it there (probe above). This client will bundle it instead: no new transport method, no separate EXIF cache, no per-item requests, and cached pages show camera info instantly across restarts.

Decision: append `exif` to the page `additional` list. Cost accepted: roughly +88 bytes (empty) to ~200 bytes (full) per item, about 15–30% growth on the measured ~600-byte page item; previously cached pages stop matching their cache key and are re-fetched once, then reclaimed by existing LRU/budget trimming. No schema version bump.

Storage decision: preserve **every** key the server returns, not just the six fields displayed today. The model keeps the complete decoded EXIF object so future UI can surface additional fields without a transport or cache change; the initial layout still shows only the screenshot-style values (camera, lens, ISO, focal length, aperture, shutter). Because EXIF now travels inside the cached page payload, every returned key is persisted across runs, not just held in memory.

## Window implementation

Use SwiftUI's `UtilityWindow` scene (macOS 15+; the app targets macOS 27). It provides the default utility-panel behavior: floating level, non-minimizable, not focused unless needed, Escape dismisses when focused, receives the app's commands, and hides when the app deactivates. A small AppKit configurator enforces the Mission Control/window-cycle requirements, which SwiftUI does not document:

- `window.collectionBehavior.formUnion([.transient, .ignoresCycle, .fullScreenAuxiliary])`
  - `.transient` — floats in Spaces and hides in Mission Control.
  - `.ignoresCycle` — excluded from the Cmd+` window cycle.
  - `.fullScreenAuxiliary` — visible over the main window's full-screen space.
- `window.standardWindowButton(.zoomButton)?.isEnabled = false`
- `window.standardWindowButton(.miniaturizeButton)?.isEnabled = false`
  This matches the referenced screenshots' dimmed yellow/green dots.
- Use `.commandsRemoved()` on the scene and place the toggle manually so there is exactly one menu item.

Fallback if SwiftUI overrides the collection behavior: re-apply it asynchronously in `viewDidMoveToWindow`, and if the panel still appears in Mission Control, replace the scene with an AppKit-managed `NSPanel` hosted by `NSHostingView` using the same content view (keep the configurator code so the swap is small). Manual verification must confirm before considering the window step done.

## Implementation

### 1. Wire models and page requests (`SynologyAPI`)

`Sources/SynologyAPI/PhotoModels.swift`:

- Add `public let filesize: Int64?` to `PhotoItem`; add `case filesize` to `CodingKeys`.
- Add `public let exif: ExifInfo?` to `PhotoItem.Additional`; add `case exif` to `Additional.CodingKeys`. Update the `Additional(...)` construction inside `withFavorite` with `exif: nil`.
- New type that keeps every server key and exposes the six displayed fields as typed accessors:

  ```swift
  /// A JSON scalar as returned in an EXIF object. Non-scalar or unrecognized shapes decode to `.null`.
  public enum ExifValue: Codable, Sendable, Equatable {
      case string(String)
      case number(Double)
      case bool(Bool)
      case null
  }

  public struct ExifInfo: Codable, Sendable, Equatable {
      /// Every key the server returned, preserved verbatim for future display.
      public let raw: [String: ExifValue]

      // Accessors for the fields displayed today; nil for missing or empty values.
      public var aperture: String?      // "aperture"
      public var camera: String?        // "camera"
      public var exposureTime: String?  // "exposure_time"
      public var focalLength: String?   // "focal_length"
      public var iso: String?           // "iso"
      public var lens: String?          // "lens"

      /// True when at least one of the six display fields has a non-empty value.
      public var hasAnyValue: Bool
  }
  ```

  Decode with a dynamic-keyed container (`allKeys`) that decodes each value as `ExifValue` and stores it in `raw`; encode `raw` back symmetrically so the page cache round-trips unknown keys. `ExifValue` decoding tries Bool, then Double, then String, mapping anything else to `.null`; `.number` and `.bool` stringify for the typed accessors. Treat `nil` and `""` equally when deciding whether a display row is visible.

`Sources/SynologyAPI/PhotosTransport.swift` (or a new small `PhotosRequestFields.swift` in the same target): add one source of truth for the page request fields:

```swift
public enum PhotosRequestFields {
    public static let pageAdditional = [
        "thumbnail", "resolution", "orientation", "video_convert",
        "video_meta", "address", "favorite", "exif",
    ]
}
```

`Sources/SynologyAPI/SynologyClient.swift` `items(in:collection:)`: build the `additional` parameter (JSON array string) from `PhotosRequestFields.pageAdditional` instead of the inline literal.

### 2. Page cache key (`PhotoCache`)

`Sources/PhotoCache/DiskCache.swift` `CacheKey.page`: replace the hard-coded trailing additional-list string with `PhotosRequestFields.pageAdditional.joined(separator: ",")` (now ending in `,exif`). Sharing the list between the request and the cache key prevents the two from drifting. Do not bump `schemaVersion`; unreferenced old page entries are reclaimed by existing budget/LRU trimming.

### 3. Selection info resolver (`PhotoCache`)

New file `Sources/PhotoCache/SelectionInfoResolver.swift`, following the bounded pattern of `SelectionFavoriteResolver`:

```swift
public struct SelectionInfo: Sendable, Equatable {
    public let itemCount: Int
    public let newestDayID: String?      // "yyyy-MM-dd", capture-local day
    public let oldestDayID: String?
    public let resolvedCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let cumulativeSize: Int64?    // nil until every contributing section resolved
    public let isComplete: Bool
    public let hadFailure: Bool
    public let singleItem: PhotoItem?    // set when the selection has exactly one ordinal
}

public struct SelectionInfoResolver: Sendable {
    public init(repository: CachedPhotosRepository)
    public func resolve(collection: PhotoCollectionDescriptor,
                        snapshot: TimelineSnapshot,
                        selectedOrdinals: IndexSet) -> AsyncStream<SelectionInfo>
}
```

Algorithm:

1. Build `LibraryIndex(snapshot:)` and map every ordinal with `location(forOrdinal:)`. If any ordinal fails, finish with `hadFailure = true` and `isComplete = true`.
2. Derive `itemCount` and the day range immediately from the locations' `dayID` values (string min/max; the format sorts chronologically) and yield the first `SelectionInfo` with `cumulativeSize = nil`.
3. Group locations by `sectionIndex`; process sections in index order with at most 2 concurrent page streams via `repository.page(descriptor, collection:, allowNetwork: true, priority: .prefetch)`. Use the first emitted value of each stream (cached-first); update when a verified value arrives. Do not require verification to display.
4. For each section keep only `[pageOffset: PhotoItem]` for its selected ordinals plus that section's running contribution (resolved count, photo/video counts, size sum). When a section re-emits (cached first, verified later), subtract its previous contribution and add the new one before yielding. Aggregate incrementally: never rescan completed sections, so work stays proportional to the total resolved items rather than sections × items.
5. A section whose stream finishes without any value, or reports `.failure`, marks `hadFailure = true`. When every section has either produced a value or failed, yield the final value with `isComplete = true`; `cumulativeSize` stays `nil` if any selected item lacked `filesize` or any section failed.
6. For a one-ordinal selection set `singleItem`.
7. Stream termination cancels all page streams. Capture the index fingerprint and, after the final chunk, compare with `repository.latestTimelineSnapshot(collection:)`; if it changed, finish with `hadFailure = true` so the model re-runs.

### 4. Formatting (`SynoTimelineApp`)

New file `Sources/SynoTimelineApp/InfoPanelFormatting.swift`, small pure functions so they are unit-testable:

- `dayRange(newest:oldest:)` from day IDs using a GMT Gregorian calendar: `"Jul 8, 2026"` (same day), `"Apr 21 – Jul 8, 2026"` (same year), `"Apr 21, 2025 – Jul 8, 2026"` (cross-year). Locale-aware `.medium` month/day.
- `singleDateTime(_ time: Int64)`: GMT, `dateStyle = .long`, `timeStyle = .medium` (seconds included; capture-local wall clock, consistent with `CaptureWallTimeFormatter`).
- `byteCount(_ bytes: Int64)`: `ByteCountFormatter` `.file` style, adaptive.
- `megapixels(width:height:)`: `Int(Double(width * height) / 1_000_000)` truncated, `"39 MP"`.
- `formatBadge(filename:)`: extension map: heic/heif/hif → HEIF, jpg/jpeg → JPEG, png → PNG, tif/tiff → TIFF, dng → DNG, mov → MOV, mp4 → MP4, otherwise uppercased extension.
- `apertureValue(_:)`: web-client behavior — if the value starts with `"F"`, display `"f/" + rest` (`"F2.8"` → `"f/2.8"`).
- `duration(_:)` for videos: `m:ss`.
- Helpers that skip `nil`/empty strings.

### 5. Panel state model (`SynoTimelineApp`)

New file `Sources/SynoTimelineApp/InfoPanelModel.swift`:

```swift
@MainActor
final class InfoPanelModel: ObservableObject {
    @Published private(set) var content = InfoPanelContent()   // .empty by default
    func setVisible(_ visible: Bool)
    func updateBrowserContext(repository: CachedPhotosRepository?, snapshot: TimelineSnapshot?,
                              collection: PhotoCollectionDescriptor, selection: IndexSet)
    func updateViewer(active: Bool, item: PhotoItem?)
}
```

`InfoPanelContent` lives in this file.

Behavior:

- Browser and viewer contexts are tracked separately. The viewer is active from `updateViewer(active: true, …)` until `updateViewer(active: false, …)`. While active it always wins over the browser selection, including when `item == nil` (show a single-item loading layout, never an unrelated browser summary). Browser context updates are still stored while the viewer is active, but they do not start resolution and cancel any in-flight resolver stream.
- Keep the latest browser context while hidden; do no resolution work and cancel any in-flight resolver stream while hidden. On `setVisible(true)`, resolve the current context immediately (covers "opened while something is already highlighted").
- Browser context updates compute `itemCount` and the day range synchronously from `LibraryIndex(snapshot:)` (no page reads) and publish the summary immediately with `isResolvingSize = true`. A 150 ms debounce then starts `SelectionInfoResolver` for the exact size and type counts. Every new selection cancels the previous stream and increments a monotonic generation; emissions from superseded generations are ignored. Skip all work when the inputs are unchanged (same collection, same `IndexSet`, same snapshot fingerprint, same visibility, same viewer state).
- Guard `repository == nil` or `snapshot == nil` (login failed/library unavailable): show `.empty` or `.failure(String)` instead of starting resolution.
- Single browser selection: the resolver supplies `singleItem`; until it arrives show the single-item loading layout. Single content is built directly from the `PhotoItem` (it already carries `filesize`, `resolution`, and `exif` after step 1); no EXIF fetch.
- `InfoPanelContent` fields: kind (`.empty`, `.multiple`, `.single`, `.failure(String)`); multiple: `countText`, `dateRangeText`, optional `sizeText` plus `isResolvingSize`; single: `filename`, `dateTimeText`, `camera`, `lens`, `metrics: [String]`, `formatBadge`, `exposure: [String]` (ISO, focal length, aperture, shutter), optional `durationText`.
- Count noun for multiple: `"Photos"` when all resolved items are photos/live stills, `"Videos"` when all are videos, `"Items"` when mixed or not yet fully resolved.
- No Combine publishers: the shell pushes contexts; the model owns only resolver tasks.

### 6. Panel view (`SynoTimelineApp`)

New file `Sources/SynoTimelineApp/InfoPanelView.swift`:

- `@EnvironmentObject var infoPanel: InfoPanelModel`; fixed content width ~280 pt, `.fixedSize(horizontal: false, vertical: true)` so the window height follows content (multiple vs single). If the window does not resize on content changes, set the hosting view's `sizingOptions.insert(.preferredContentSize)` in the configurator.
- `.onAppear { infoPanel.setVisible(true) }`, `.onDisappear { infoPanel.setVisible(false) }`.
- Empty: secondary text "Select photos to view info."
- Loading (viewer active or single browser selection before metadata): filename headline when known, otherwise a small `ProgressView` row with "Loading info…".
- Multiple: headline `"57 Photos"`, then `dateRangeText`, then `sizeText` (replace with a small `ProgressView` while `isResolvingSize`, `"—"` on failure).
- Single: headline filename (`lineLimit(1)`, `.middle` truncation), date/time line, `Divider()`, then a grouped metadata block:
  - line 1: camera (body), line 2: lens (secondary, up to 2 lines);
  - metrics row: `39 MP · 5152 × 7728 · 14.6 MB` plus the format badge capsule;
  - when any exposure value exists: `Divider()`, then `"ISO 6400 · 27 mm · f/2.8 · 1/17 s"` (caption, secondary);
  - videos: duration in the metrics row instead of the camera block; hide camera/exposure entirely when `exif.hasAnyValue == false`.
- Accessibility: expose one combined element per section with labels such as "Info, 57 photos" or "Info, IMG_3987, July 8, 2026"; Cmd+I stays the single discovery path.
- Background `.background(InfoPanelWindowConfigurator())`: zero-size `NSViewRepresentable` that configures `view.window` per the "Window implementation" section.

### 7. App scene, command, and shell wiring (`SynoTimelineApp`)

`Sources/SynoTimelineApp/App.swift`:

- Add `@StateObject private var infoPanel = InfoPanelModel()`.
- Inject it into the main window content:
  `AppShellView(navigationRestoration:) ... .environmentObject(infoPanel)`.
- Add the scene:
  ```swift
  UtilityWindow("Info", id: "photo-info") {
      InfoPanelView().environmentObject(model).environmentObject(infoPanel)
  }
  .commandsRemoved()
  .defaultPosition(.topTrailing)
  ```

`Sources/SynoTimelineApp/LibraryControls.swift` in `LibraryCommands`, after the favorite command and a `Divider()`:

```swift
WindowVisibilityToggle(windowID: "photo-info")
    .keyboardShortcut("i", modifiers: [.command])
```

This is the required discoverable menu command and the only Cmd+I definition; do not add a hidden key handler.

`Sources/SynoTimelineApp/AppShellView.swift`:

- Add `@EnvironmentObject private var infoPanel: InfoPanelModel`.
- Extend the `LibraryBrowserView` `onSelectionStateChanged` closure so each selection change also calls
  `infoPanel.updateBrowserContext(repository: library.repository, snapshot: library.snapshot(for: collection), collection: collection, selection: state.selection.indexes)`.
- Call the same update from `finishSelection(_:)` (destination switch and launch) using `library.selectionState(for: collection).selection.indexes`, and from `.onChange(of: library.snapshotRevision(for: selectedCollection))`.
- Viewer: in `openPhoto`, after creating the presentation, call `infoPanel.updateViewer(active: true, item: request.seed.item)` and set `viewer.onInfoItemChanged = { [weak infoPanel] item in infoPanel?.updateViewer(active: true, item: item) }`. When the viewer finishes closing call `infoPanel.updateViewer(active: false, item: nil)` so the panel returns to the browser selection.

`Sources/SynoTimelineApp/PhotoViewerPresentation.swift`:

- Add `var onInfoItemChanged: ((PhotoItem?) -> Void)?`.
- In `receive(_ next:)`, call `onInfoItemChanged?(next.item)` (fires again when verified metadata for the same selection arrives, and on every navigation).
- Do not notify from `close()` or `invalidateForNewIndex()`; the shell owns the viewer-active transition, and during an invalidation the displayed item remains valid. The shell callback captures `infoPanel` weakly to avoid a retain cycle.

### 8. Documentation

- `docs/SYNOLOGY_PHOTOS_API.md`: add an "Item EXIF in page lists" subsection with the probe evidence and field names; state that values are pre-formatted display strings with empty strings when absent, and that `aperture` uses `"F"` notation.
- `docs/ARCHITECTURE.md`: one paragraph on the info panel: `UtilityWindow` with transient/ignoresCycle behavior, `InfoPanelModel` context/debounce, bounded `SelectionInfoResolver` page reads, EXIF bundled into item pages.
- `AGENTS.md` "Project overview": extend the UI-scope sentence with the floating Cmd+I info panel.
- `docs/plans/README.md`: add this plan under its WIP name; rename to `DONE_INFO_PANEL_PLAN.md` and update the entry when complete.

## Validation

Automated:

- `swift build --build-tests` and `swift test` (all four test targets).
- `Tests/SynologyAPITests/PhotoItemTests.swift`: decode a list fixture containing `filesize` and a filled `exif` object (probe values above) asserting all six typed accessors and snake_case mapping; decode an exif object with an extra unknown key and mixed value types, assert it appears in `raw`, and assert it survives an encode/decode round trip (the page-cache path) and `withFavorite`; decode empty-string exif; assert `hasAnyValue` behavior.
- New `Tests/PhotoCacheTests/SelectionInfoResolverTests.swift` with a mock `PhotosTransport`:
  - selection across two sections: first emission has exact count/day range with `cumulativeSize == nil`, final emission has the exact sum and photo/video counts;
  - a section that emits cached data and then verified data updates the size once without double counting;
  - single ordinal produces `singleItem`;
  - a failed page sets `hadFailure` and leaves `cumulativeSize == nil` while count/date stay exact;
  - stream cancellation stops further page requests;
  - cached-first values are emitted without waiting for verification.
- New `Tests/SynoTimelineAppTests/InfoPanelTests.swift`:
  - formatting: same-year and cross-year ranges, single day, byte count, MP truncation, format badge mapping, `"F2.8"` → `"f/2.8"`, empty exif hides the camera block;
  - `InfoPanelModel`: empty selection → placeholder; one ordinal → single content; multiple → summary; viewer active with a nil item shows the single loading layout, not the browser summary; viewer item overrides browser selection and reverts when cleared; hidden model performs no page reads (assert against the mock transport call count); rapid successive selection updates resolve only once;
  - `CacheKey.page` and the item request both derive from `PhotosRequestFields.pageAdditional`; a small test asserts the constant contains `exif` and that the page key changes when a different field list is passed (add an internal `additional:` parameter to `CacheKey.page` for the test if needed).
- Bundling adds no transport method, so existing mock transports need no new stubs.

Manual (run `bash scripts/run.sh`):

- Cmd+I shows/hides the panel; the Library menu shows "Show Info"/"Hide Info" with the shortcut.
- Panel floats above the main window, moves without appearing in Mission Control/Exposé, and does not appear in Cmd+` cycling; title bar shows "Info" with only the close button enabled.
- No selection → placeholder; click, Shift-click, marquee, and Shift-marquee update count/date/size live.
- Single selection shows filename/date/camera; a PNG screenshot shows no camera block; a HEIC photo shows camera/lens/ISO/aperture/shutter; a video shows duration and size.
- Open the viewer (Space/double-click) and arrow through images: the panel follows; close the viewer and the panel returns to the browser selection.
- Close the info window with its close button; Cmd+I reopens it with current state.
- Close the main window while the panel is open: the app must terminate. If it does not, close the utility window from the shell's disappearance.
- Long filenames truncate in the middle; dark and light appearance both legible.

## Risks and notes

- `UtilityWindow`'s documented behavior does not mention Mission Control; the configurator is required and must be verified manually. Fallback is a manually-managed `NSPanel` hosted with `NSHostingView` (same content and configurator).
- Runtime content-height changes may not resize an unresizable utility window; verify and apply the `sizingOptions` fallback.
- Page payload growth and the one-time page cache invalidation are accepted; no migration is required (alpha policy discards and recreates cache data).
- Very large selections can exhaust the metadata prefetch queue; those sections report failure and the size shows "—" while count and date range stay exact. Acceptable for now.
- All main windows share one `LibraryModel`/`InfoPanelModel`, so with multiple main windows the panel reflects the most recently interacted browser (last push wins), not a per-window context. Acceptable for the current single-cache architecture.

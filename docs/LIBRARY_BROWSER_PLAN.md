# Library browser implementation

Work proceeds in four sequential steps. Each subsequent plan is written after reviewing the preceding implementation. Individual full-resolution viewing and location labels remain deferred.

## Step 1: justified rows in the section experiment

Status: implemented, unit-tested and reviewed. Visual verification remains user-led.

Preserve item aspect ratios using metadata before thumbnails arrive. Decode the optional EXIF orientation; orientations 5–8 exchange width and height. The HAR contains orientations 1, 3, 6 and 8. Keep compatibility with older cached records missing orientation.

Implement a pure, testable row layout using available width, a target height around 180 points and a small gap. Completed rows share a height adjusted to fill the width; the last row is left aligned without excessive enlargement. Extreme panoramas and missing/invalid dimensions must produce finite, contained geometry. Retain chronological item order. Group rows by UTC calendar day, matching the observed timeline date bounds, and give each day a date heading. Recalculate geometry when width changes, not when image bytes arrive.

Apply this first to section 207. Extract reusable row/image views for the later browser. Images should fit their correctly proportioned frames without the current uniform-tile cropping. Scope image work to visible rows; retain existing cache semantics. Guard cancelled image tasks against publishing stale results after decoding. Do not change navigation or create the whole library view yet.

Acceptance: tests cover row width, aspect ratios, final-row behavior, narrow widths, invalid dimensions and orientation. Build and tests pass. Update current architecture documentation to describe the implemented slice. Main agent reviews the result before writing step 2.

## Step 2: indexed, cancellable access to cached library pages

Status: implemented, reviewed and committed as `0fd7d78` with step 1. Full automated suite passes; later UI integration remains.

The full timeline already has a persistent cache. Build the missing connection from its descriptors to arbitrary library regions. Add a compact immutable library index with stable calendar-day identities, a fingerprint of the complete descriptor snapshot, and mappings between days and every contributing API section. Split days must map to all their pages; sections containing several days must retain each day's slice. Account for section offset and limit when deriving those slices. Preserve API item order and use UTC calendar days consistently.

Expose a bounded page-window coordinator for the later viewport. It accepts the current snapshot, whether network validation is allowed, and visible/prefetch section demands. It emits cached pages immediately, starts validation only with current descriptors, retains only a configurable small working set, and cancels work when demand changes. Guard publication with descriptor generation/request identity so obsolete responses never replace current content. A very large day must be representable without requesting every page in that day at once.

Strengthen repository jobs with subscriber-aware coalescing and cancellation. Dropping the last subscriber removes queued work and cancels an unnecessary active transfer; one cancelled subscriber must not disrupt another. Bound metadata requests (two), thumbnail requests (six), and pending queues. Visible demand outranks prefetch. A cancellation must not present an error or leave a limiter permit stranded. Cached reads must not wait for login or a network queue. Finish finite streams and release subscribers/tasks on completion. Keep successful network responses usable if a cache write fails. Maintain once-per-run validation on revisits.

Introduce a small injectable transport protocol or equivalent test seam. Verify cached-before-live delivery with a delayed mock login, offline cached reads, duplicate subscribers, cancellation before queue admission, page replacement with equal counts, day/section mapping including split days, and bounded retention. No infinite-scroll UI or login indicator in this step. Preserve current experiment behavior. Review before planning step 3.

## Step 3: bounded continuous library viewport

Status: implemented, reviewed and unit-tested. User-led visual verification remains.

Use a native AppKit scrolling surface hosted by SwiftUI for explicit viewport virtualization. An `NSScrollView` with a flipped document view and only nearby hosted row/header views is an acceptable small implementation; a reusable collection view is also acceptable if equally bounded. Do not create one view per library item or append every visited page to a growing SwiftUI stack.

Keep a compact geometry index of day/page slices from `LibraryIndex`. Estimate heights of unloaded slices from counts and a representative aspect ratio; replace them with justified-row measurements when pages arrive. Retain only compact measurements for distant slices, never their photo arrays or images. Use binary search over vertical offsets for viewport lookup. One very large day must remain split into demand-sized pages, with one date heading rather than repeated headings per API page. Rows may break at an API slice boundary in this prototype; document that compromise.

Create thumbnail views only for visible rows and a small overscan margin. Feed visible section indices and at most a small adjacent prefetch window to `LibraryPageWindow` (initial bound: eight pages). Reconcile its retained page snapshot on events rather than relying on every buffered removal hint being delivered. Avoid full-index hashing, requests, or expensive full photo layout on every scroll event. Drop obsolete page/thumbnail tasks on distant jumps and when the browser disappears. Separately bound image decoding (initially two concurrent jobs), preserve the existing decoded cache, and ensure cancelled decode results cannot publish to reused cells.

Keep the visual anchor stable as estimated geometry becomes measured, on resize, and on cached-to-live replacement: prefer the visible item ID and its local pixel offset, otherwise the same date/slice position. Direct date jumps must resolve the appropriate slice and request it without fetching preceding pages. Expose jump-to-day input and visible-day output for step 4; suppress programmatic-scroll feedback loops. If a date disappears in a new full index, choose the nearest remaining older date, then the last day.

Add a temporary Photos tab to exercise the viewport while retaining both existing experiments. This step does not yet integrate the sidebar or authentication indicator. Empty libraries, cache misses and page errors need finite, usable placeholder states. Cached provisional pages must display without waiting for timeline validation, while network demand still follows current verified descriptors.

Acceptance: pure geometry tests cover large synthetic libraries, split days, visible-range lookup, direct date jumps, anchor correction and width changes; window tests cover bounded retention/cancellation. Build and tests pass. Review row/host lifecycle, notification cleanup and SwiftUI-to-AppKit updates. Main agent commits the reviewed step before planning step 4.

## Remaining step 4

Integrate browser and proportional date navigator on one screen; add independent background-login status at lower right. Cached content must remain interactive during login and after failure. Native computer use is unavailable in this thread despite being enabled; the user has agreed to perform the final visual check. Build and automated verification remain required.

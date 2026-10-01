# Library browser implementation

Work proceeds in four sequential steps. Each subsequent plan is written after reviewing the preceding implementation. Individual full-resolution viewing and location labels remain deferred.

## Step 1: justified rows in the section experiment

Status: implemented, unit-tested and reviewed. Visual verification remains user-led.

Preserve item aspect ratios using metadata before thumbnails arrive. Decode the optional EXIF orientation; orientations 5–8 exchange width and height. The HAR contains orientations 1, 3, 6 and 8. Keep compatibility with older cached records missing orientation.

Implement a pure, testable row layout using available width, a target height around 180 points and a small gap. Completed rows share a height adjusted to fill the width; the last row is left aligned without excessive enlargement. Extreme panoramas and missing/invalid dimensions must produce finite, contained geometry. Retain chronological item order. Group rows by UTC calendar day, matching the observed timeline date bounds, and give each day a date heading. Recalculate geometry when width changes, not when image bytes arrive.

Apply this first to section 207. Extract reusable row/image views for the later browser. Images should fit their correctly proportioned frames without the current uniform-tile cropping. Scope image work to visible rows; retain existing cache semantics. Guard cancelled image tasks against publishing stale results after decoding. Do not change navigation or create the whole library view yet.

Acceptance: tests cover row width, aspect ratios, final-row behavior, narrow widths, invalid dimensions and orientation. Build and tests pass. Update current architecture documentation to describe the implemented slice. Main agent reviews the result before writing step 2.

## Step 2: indexed, cancellable access to cached library pages

Status: implemented and unit-tested; awaiting main-agent review and later UI integration.

The full timeline already has a persistent cache. Build the missing connection from its descriptors to arbitrary library regions. Add a compact immutable library index with stable calendar-day identities, a fingerprint of the complete descriptor snapshot, and mappings between days and every contributing API section. Split days must map to all their pages; sections containing several days must retain each day's slice. Account for section offset and limit when deriving those slices. Preserve API item order and use UTC calendar days consistently.

Expose a bounded page-window coordinator for the later viewport. It accepts the current snapshot, whether network validation is allowed, and visible/prefetch section demands. It emits cached pages immediately, starts validation only with current descriptors, retains only a configurable small working set, and cancels work when demand changes. Guard publication with descriptor generation/request identity so obsolete responses never replace current content. A very large day must be representable without requesting every page in that day at once.

Strengthen repository jobs with subscriber-aware coalescing and cancellation. Dropping the last subscriber removes queued work and cancels an unnecessary active transfer; one cancelled subscriber must not disrupt another. Bound metadata requests (two), thumbnail requests (six), and pending queues. Visible demand outranks prefetch. A cancellation must not present an error or leave a limiter permit stranded. Cached reads must not wait for login or a network queue. Finish finite streams and release subscribers/tasks on completion. Keep successful network responses usable if a cache write fails. Maintain once-per-run validation on revisits.

Introduce a small injectable transport protocol or equivalent test seam. Verify cached-before-live delivery with a delayed mock login, offline cached reads, duplicate subscribers, cancellation before queue admission, page replacement with equal counts, day/section mapping including split days, and bounded retention. No infinite-scroll UI or login indicator in this step. Preserve current experiment behavior. Review before planning step 3.

## Remaining sequence

3. Implement virtualized continuous scrolling with day groups, anchor preservation, and direct date jumps.
4. Integrate browser and proportional date navigator on one screen, add background-login status at lower right, and perform a brief UI check.

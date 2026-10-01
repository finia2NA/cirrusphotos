# Timeline prototype

## Current implementation

`TimelineCore` contains the platform-independent model. `TimelinePrototype` is the SwiftUI macOS executable. The application currently runs entirely from a bundled static fixture; it has no Swift authentication or networking layer yet.

The fixture `Sources/TimelinePrototype/Resources/days.json` contains rows of `[year, month, day, itemCount, firstSectionIndex]`. It was extracted from the Personal Space full timeline response in the local HAR. It includes dates/counts and zero-based section references, but no filenames, image content, account identifiers, or authentication tokens. The original HAR remains ignored by Git. The fixture is historical data for this prototype, not an API schema.

The model deduplicates calendar dates, retains the earliest section index for split days, and sorts newest first. It precomputes year/month boundaries once. The data is assumed static throughout an app session. Handling additions, deletions, or index reconciliation is explicitly deferred.

## Geometry and input

Each populated day owns the same fraction of the usable track. Empty days occupy no space. Item counts do not influence spacing.

For `N` dates, track origin `top`, track height `H`, and pointer `y`:

```text
fraction = clamp((y - top) / H, 0, 1)
dayIndex = min(N - 1, floor(fraction * N))
markerY = top + H * (dayIndex + 0.5) / N
```

This gives constant-time pointer lookup. A single `Canvas` paints the track, month marks, year labels, and selection indicator. One transparent rectangular view handles continuous hover and click/drag input. There are no per-day views or hit targets. Year labels are culled when less than 25 points apart, without changing the underlying date geometry.

More populated days than screen pixels necessarily means some days cannot be individually targeted with the pointer. Arrow keys and the accessibility adjustable action allow exact single-day stepping. Hover feedback includes both year/month and the exact selected calendar day.

## Selection contract

`TimelineNavigator` exposes a selected day index through a binding. The prototype reads the corresponding `LibraryDay` and displays the date/count/first section. A future parent can use that callback/binding to fetch the full section descriptor and scroll to the selected day. A section can contain several days, so merely fetching the section is not sufficient to align the eventual grid to the day.

The selected-date readout stands in for the future photo grid. Location labels, thumbnail loading, live NAS loading, and production cache management are outside this prototype.

## Verification

`TimelineCoreTests` checks split-day deduplication, descending chronology, equal weighting despite different photo counts, clamped hit mapping, empty data, and marker-to-index round trips. Manual UI checks cover hover, drag/click selection, keyboard navigation, and resizing.

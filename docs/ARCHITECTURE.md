# Timeline prototype

## Current implementation

`TimelineCore` contains the platform-independent model. `SynologyAPI` owns credentials, TOTP login, the authenticated URL session, and timeline requests. `TimelinePrototype` is the SwiftUI macOS executable.

At startup the app reads `USER`, `PW`, and the TOTP secret `OTP` from the ignored `.env`, authenticates to Cirrus, requests `get_init_timeline`, then requests the full `get` timeline. The initial response allows the navigator to appear while the full response is loading. The completed timeline is not refreshed during the session.

The model deduplicates calendar dates, retains the earliest section index for split days, and sorts newest first. It precomputes year/month boundaries once. Handling additions, deletions, or index reconciliation is deferred.

The current certificate mismatch is accepted only for the configured Cirrus host. The prototype app's transport-security exception and the URL session trust override are both scoped to that hostname. The URL session uses ephemeral cookie storage, and credentials, OTP values, session IDs, and tokens are never logged. `.env` is a development credential source; a distributable app should move credentials to Keychain.

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

The selected-date readout stands in for the future photo grid. Location labels, thumbnail loading, and production cache management are outside this prototype.

## Verification

`TimelineCoreTests` checks split-day deduplication, descending chronology, equal weighting despite different photo counts, clamped hit mapping, empty data, and marker-to-index round trips. Manual UI checks cover hover, drag/click selection, keyboard navigation, and resizing.

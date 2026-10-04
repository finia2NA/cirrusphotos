# Cirrus Photos

A macOS 27+ SwiftUI client for browsing Cirrus Synology Photos Personal Space.

Run from the repository root:

```sh
bash scripts/run.sh
```

This builds and opens a local `.app` inside the ignored `.build` directory. Pass `--build-only` to build, assemble, and sign the bundle without opening it. Alternatively, run directly from the terminal:

```sh
swift run SynoTimeline
```

Open `Package.swift` in Xcode to build and run there instead. Run model tests with `swift test`. Building requires the macOS 27 SDK.

The app reads `USER`, `PW`, and `OTP` from the ignored `.env`. On a warm launch it displays cached timeline, page, and thumbnail data while signing in and validating demanded resources. A cold launch shows Synology's initial timeline while fetching the full index. The toolbar status shows login progress, connection, or failure, with a Retry action when recovery is needed. Library data remains fixed after validation during that app run.

**Personal Library** browses the full library in day-grouped, aspect-preserving rows. The sidebar button hides or shows navigation. The toolbar slider changes the displayed thumbnail size while retaining your position in the library; it does not change the cached image rendition. The interface follows the macOS light or dark appearance and uses native translucent navigation and toolbar controls.

Move near the right edge to reveal the compact timeline. Click or drag to jump to a date, and use up/down arrows after focusing it to step one populated day at a time. Scrolling the photos updates the selected date. Each populated day has equal vertical weight; month marks and year labels follow that distribution. Labels that would overlap are omitted, but their dates remain selectable. Click a photo to expand it into the same window. Its thumbnail appears immediately while the original loads. The toolbar shows the filename, capture date, and loading status; its slider controls image zoom. Pinch or use the slider/mouse wheel to zoom, and drag or scroll the trackpad to pan. Use left/right arrows to change photos and Back or Escape to return to the library. Nearby originals load after the current image succeeds and are evicted from disk before thumbnails. Video playback remains deferred.

Use **Library → Download Thumbnails…** after the timeline is current to choose an inclusive date range with two slider handles. The window shows an upper-bound thumbnail count and downloads the rendition selected in Settings. Browsing can continue while the batch runs; Cancel or closing its window stops it. Normal cache-budget eviction still applies, so this is cache warming, not pinned offline storage.

Open Settings from the app menu or with Command-, to select the small, medium, or large cached thumbnail rendition; set the total cache limit from 200 MB to 100 GB; view current stored payload usage; or clear the cache. The app stores its persistent cache under `.cache/` in this repository; that directory is ignored by Git. Offline data remains visible until Cirrus validates it. Entries are scoped to the server and account.

See [architecture](docs/ARCHITECTURE.md), [cache plan and implementation status](docs/CACHING_PLAN.md), [cache-location decision](docs/decisions/001-development-cache-location.md), and [API research](docs/SYNOLOGY_PHOTOS_API.md).

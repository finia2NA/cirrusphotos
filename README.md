# Cirrus Photos

A macOS 27+ SwiftUI client for browsing a Synology Photos library (Personal and Shared Space, albums, People, Subjects, Tags, folders and a location Map) with cached-first loading.

Run from the repository root:

```sh
bash scripts/run.sh
```

This builds and opens a local `.app` inside the ignored `.build` directory. Pass `--build-only` to build, assemble, and sign the bundle without opening it. Alternatively, run directly from the terminal:

```sh
swift run SynoTimeline
```

To build the app bundle, open macOS Console, and run the app in the foreground, use:

```sh
make debug
```

In Console, use `s:local.cirrus.syno-timeline` as a subsystem search and save it for reuse. For video playback, the useful categories are `viewer.video`, `repository.video`, and `transport.video`: they show AVPlayer state, cache/range assembly, and NAS request status and timing respectively. The logs include item/unit IDs, effective quality, byte ranges, HTTP status, and sanitized error domain/code, but exclude filenames, cache keys, credentials, session data, authenticated URLs, and response bodies. Press Control-C in the terminal to stop the app. `make start` builds and opens the app normally without opening Console.

These commands build in debug mode. Use `make release` (or `scripts/run.sh --release`) to build and open an optimized bundle when judging performance. `make profile` builds that bundle, launches it under Instruments' Time Profiler for 40 seconds with a countdown, shows progress while the trace is written to `.build/profiles/`, and opens it; override with `PROFILE_SECONDS=…` or `PROFILE_TEMPLATE="Animation Hitches"`. One Control-C stops early and still saves. Animation Hitches traces are very large (about 20 GB for 60 seconds), so keep those recordings short. Browser signposts (subsystem `local.cirrus.syno-timeline`, category `performance.browser`) mark layout passes, row view creation, thumbnail cache reads and decodes; they appear in Instruments' os_signpost / Points of Interest lanes.

To remove build artifacts so the next `make` or `make debug` performs a clean build, use:

```sh
make clean
```

`make switch-user TARGET=real|test|none` switches the development account while the app is quit: `real` and `test` activate `.env.real` or `.env.test` with their own caches, and `none` removes `.env` so the app shows its own sign-in, with a fresh cache that is deleted when switching away from `none`. Accounts signed in from the app stay in the Keychain until signed out.

Run `make cloc` for line counts by language and directory (up to two directory levels). It counts Git-tracked files and excludes submodules. Install the dependency with `brew install cloc` if needed.

Open `Package.swift` in Xcode to build and run there instead. Run model tests with `swift test`. Building requires the macOS 27 SDK.

Without a `.env` file, the app opens a sign-in window (server, username, password, and a six-digit code when the account uses two-factor authentication) and keeps the account in the Keychain. For development, an ignored `.env` beside the project with `NAS_URL`, `USER`, `PW`, and optionally the TOTP secret `OTP` takes precedence. On a warm launch it displays cached timeline, page, and thumbnail data while signing in and validating demanded resources. A cold launch shows Synology's initial timeline while fetching the full index. The toolbar status shows login progress, connection, or failure, with a Retry action when recovery is needed. Library data remains fixed after validation during that app run.

**Personal Library**, **Favorites**, opened Personal Space albums, and location-filtered results use a day-grouped grid with 3–10 square slots per row. Photos keep their aspect ratio and are centered in each slot. The toolbar slider changes the number of items per row while retaining your position; it does not change the cached image rendition. The sidebar's Albums destination opens an overview of album covers, names, and item counts; albums are read-only. Map clusters the Personal Library's geotagged photos locally and opens a pin or cluster in the same browser. The sidebar button hides or shows navigation. The interface follows the macOS light or dark appearance and uses native translucent navigation and toolbar controls.

Move near the right edge to reveal the compact timeline. Click or drag to jump to a date, and use up/down arrows after focusing it to step one populated day at a time. Scrolling the photos updates the selected date. Each populated day has equal vertical weight; month marks and year labels follow that distribution. Labels that would overlap are omitted, but their dates remain selectable. In the photo grid, click to select, Shift-click to add, drag a rectangle to replace the selection, or Shift-drag to toggle the items inside it. Arrow keys move selection and Shift-arrow extends it. Press Space when one photo is selected, or double-click a photo, to open the viewer. Its thumbnail appears immediately while the original loads. The toolbar shows the filename, capture date, and loading status; its slider controls image zoom. Pinch or use the slider/mouse wheel to zoom, and drag or scroll the trackpad to pan. Use left/right arrows to change photos and Back, Escape, or Space to return to the collection. The toolbar heart or **Library → Toggle Favorite** updates the current selection or viewer photo. **Library → Show Info** opens a floating panel for selection summaries or photo metadata. Nearby originals load after the current image succeeds and are evicted from disk before thumbnails. Video playback remains deferred.

Use **Library → Download Thumbnails…** after the timeline is current to choose an inclusive date range with two slider handles. The window shows an upper-bound thumbnail count and downloads the rendition selected in Settings. Browsing can continue while the batch runs; Cancel or closing its window stops it. Normal cache-budget eviction still applies, so this is cache warming, not pinned offline storage.

Open Settings from the app menu or with Command-, to select the small, medium, or large cached thumbnail rendition; set the total cache limit from 200 MB to 100 GB; view current stored payload usage; or clear the cache. The app stores its persistent cache under `.cache/` in this repository; that directory is ignored by Git. Offline data remains visible until Cirrus validates it. Entries are scoped to the server and account.

See [product behavior and scope](docs/PROJECT.md), [architecture](docs/ARCHITECTURE.md), [cache follow-up work](https://github.com/finia2NA/syno/issues/28), [cache-location decision](docs/decisions/001-development-cache-location.md), and [API research](docs/SYNOLOGY_PHOTOS_API.md).

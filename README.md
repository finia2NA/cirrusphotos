# Cirrus timeline prototype

A macOS 14+ SwiftUI prototype of the right-hand Synology Photos timeline navigator.

Run from the repository root:

```sh
bash scripts/run-prototype.sh
```

This builds and opens a local `.app` inside the ignored `.build` directory. Alternatively, run directly from the terminal:

```sh
swift run SynoTimeline
```

Open `Package.swift` in Xcode to build and run there instead. Run model tests with `swift test`.

The prototype reads `USER`, `PW`, and `OTP` from the ignored `.env`. On a warm launch it displays the cached full Personal Space timeline immediately, then validates it against Cirrus once. On a cold launch it displays Synology's initial timeline while fetching the full index. Data remains fixed after validation during that app run.

Move over the right-hand timeline to see a date, click or drag to select it, and use up/down arrows after focusing the timeline to step one day at a time. The central readout shows the selected date, item count, and zero-based API section. This selection is the future integration point for the photo grid.

Each populated day has equal vertical weight. Month marks and year labels follow that distribution. Labels that would overlap are omitted, but their dates remain selectable. The pink line indicates the selection; the floating label indicates the hovered date. The window is resizable.

The **Section 207** tab loads one current Personal Space section (111 items in the captured HAR), displays its thumbnails, and demonstrates cached-first page and image loading. It does not scroll across sections or open full photos.

Open Settings from the app menu or with Command-, to select small, medium, or large thumbnails; set the total cache limit from 200 MB to 100 GB; view current stored payload usage; or clear the cache. The prototype stores its persistent cache under `.cache/` in this repository; that directory is ignored by Git. Offline data remains visible until Cirrus validates it. Entries are scoped to the server and account.

See [architecture](docs/ARCHITECTURE.md), [cache plan and implementation status](docs/CACHING_PLAN.md), [cache-location decision](docs/decisions/001-development-cache-location.md), and [API research](docs/SYNOLOGY_PHOTOS_API.md).

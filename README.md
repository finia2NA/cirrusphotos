# Cirrus timeline prototype

A macOS 14+ SwiftUI prototype for browsing Cirrus Synology Photos Personal Space.

Run from the repository root:

```sh
bash scripts/run-prototype.sh
```

This builds and opens a local `.app` inside the ignored `.build` directory. Alternatively, run directly from the terminal:

```sh
swift run SynoTimeline
```

Open `Package.swift` in Xcode to build and run there instead. Run model tests with `swift test`.

The prototype reads `USER`, `PW`, and `OTP` from the ignored `.env`. On a warm launch it displays cached timeline, page, and thumbnail data while signing in and validating demanded resources. A cold launch shows Synology's initial timeline while fetching the full index. The lower-right status shows login progress, connection, or failure; Retry is available after errors. Library data remains fixed after validation during that app run.

The default **Photos** tab scrolls through the full library in day-grouped, aspect-preserving rows. Move over the right-hand timeline to see a date, click or drag to jump to it, and use up/down arrows after focusing the timeline to step one day at a time. Scrolling the photos updates the selected date. The **Timeline** tab retains the date/count/section readout experiment.

Each populated day has equal vertical weight. Month marks and year labels follow that distribution. Labels that would overlap are omitted, but their dates remain selectable. The pink line indicates the selection; the floating label indicates the hovered date. The window is resizable.

The **Section 207** tab loads one current Personal Space section and demonstrates cached-first page and image loading. Full-photo viewing remains deferred.

Use **Library → Download Thumbnails…** after the timeline is current to choose an inclusive date range with two slider handles. The window shows an upper-bound thumbnail count and downloads the rendition selected in Settings. Browsing can continue while the batch runs; Cancel or closing its window stops it. Normal cache-budget eviction still applies, so this is cache warming, not pinned offline storage.

Open Settings from the app menu or with Command-, to select small, medium, or large thumbnails; set the total cache limit from 200 MB to 100 GB; view current stored payload usage; or clear the cache. The prototype stores its persistent cache under `.cache/` in this repository; that directory is ignored by Git. Offline data remains visible until Cirrus validates it. Entries are scoped to the server and account.

See [architecture](docs/ARCHITECTURE.md), [cache plan and implementation status](docs/CACHING_PLAN.md), [cache-location decision](docs/decisions/001-development-cache-location.md), and [API research](docs/SYNOLOGY_PHOTOS_API.md).

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

The prototype uses a bundled snapshot of 2,192 populated days from Personal Space. It does not require a NAS connection or credentials. Move over the right-hand timeline to see a date, click or drag to select it, and use up/down arrows after focusing the timeline to step one day at a time. The central readout shows the selected date, item count, and zero-based API section. This selection is the future integration point for the photo grid.

Each populated day has equal vertical weight. Month marks and year labels follow that distribution. Labels that would overlap are omitted, but their dates remain selectable. The pink line indicates the selection; the floating label indicates the hovered date. The window is resizable.

See [architecture](docs/ARCHITECTURE.md) and [API research](docs/SYNOLOGY_PHOTOS_API.md).

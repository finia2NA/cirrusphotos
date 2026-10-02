# Application UI

## Scope

Replace the experiment tabs with a Personal Library application shell while preserving the cached-first repository, bounded native viewport, day grouping, and aspect-preserving rows. Follow the macOS appearance. Keep navigation limited to Personal Library; full-photo viewing and additional library destinations remain deferred.

## Sequential implementation

1. **Shell and appearance** — Replace the tab shell with a retractable sidebar and native translucent toolbar. Include a thumbnail display-size slider and the existing authentication status and retry action. Use semantic colors in the library and thumbnail placeholders. Target macOS 27 and use native system glass. Review the build and changes before starting the next chunk.
2. **Display geometry and timeline** — Connect display size to measured and estimated row geometry, independently of the cached rendition preference. Preserve visible-item anchoring during size and width changes. Narrow the navigator, reveal it near the pointer and during focus/drag, and retain day selection, keyboard input, and accessibility. Keep a small stable trailing gutter so hover does not reflow the grid. Add focused geometry regression coverage.
3. **Integration review** — Review both chunks, run the test suite, and inspect the app in light and dark appearances, including sidebar collapse, size changes, and timeline interaction. Correct defects, update current documentation, and commit only this UI work, preserving unrelated local edits.

## Verification

Implemented and reviewed in sequential chunks. Build and geometry regressions pass, including shrink anchoring, combined width/size changes, unloaded estimates, and cross-page row carry. The full suite passed with three opt-in live tests skipped. Light appearance, sidebar collapse/reopen, and library scrolling were checked in the running shell. Native UI automation became unavailable before the final build; final glass appearance, dark appearance, and end-to-end slider/hover interaction still need a visual check.

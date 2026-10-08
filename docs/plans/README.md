# Plans

This directory contains implementation plans, completed design records, and current follow-up work. Current behavior is documented in [`../ARCHITECTURE.md`](../ARCHITECTURE.md) and the root `AGENTS.md`; completed plans may describe earlier states and are not implementation sources of truth.

- `DONE_LIBRARY_SELECTION_PLAN.md` — completed Step 1 fixed-slot grid, selection interactions, and viewer entry changes.
- `DONE_SELECTION_FAVORITES_PLAN.md` — implemented toolbar and menu favorite actions for selected timeline items, including bulk writes and confirmation.
- `WIP_CACHING_PLAN.md` — current cache status, constraints, and longer-term direction.
- `WIP_DIFF_CACHE_PLAN.md` — whole-app Diff validation plan: per-resource evidence gates and atomic proofs, conservative metadata fallbacks, location delta repair, and metadata-only reset preserving images; image-validation shortcuts and Shared Space are excluded. Not implemented.
- `WIP_MAP_DIFF_CACHE_PLAN.md` — alternative Map-only Diff plan: location-owned proof and bounded repair; other resources retain conventional cached-first, once-per-run validation. Includes the same metadata-only reset scope preserving images. Not implemented. These two Diff plans are alternatives; this index does not select either.
- `DONE_MAP_PLAN.md` — completed location map destination (client-side clustered Apple Maps over the Personal Library), filtered-location timeline browsing, and info-panel maps.
- `DONE_ALBUMS_PLAN.md` — completed read-only Albums destination, overview grid, day-grouped album browsing, and album caching integration.
- `DONE_INFO_PANEL_PLAN.md` — completed floating Cmd+I info panel for the browser selection and viewer, with a manual verification checklist.
- `DONE_PHOTO_VIEWER_PLAN.md` — completed viewer plan with a still-useful manual verification checklist.
- `DONE_CORRECTNESS_CLEANUP_PLAN.md` — completed browser, sidebar, Favorites, and timestamp correctness work.
- `TODO_REMAINING_CLEANUP.md` — remaining repository-structure cleanup.

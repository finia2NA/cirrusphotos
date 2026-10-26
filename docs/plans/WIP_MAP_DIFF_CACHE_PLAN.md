# Map integration in the unified metadata engine

Status: superseded as a standalone implementation plan on 2026-10-27. The user
prioritizes a clean shared architecture and explicitly accepts delaying Map.
Implement the [unified metadata engine plan](WIP_DIFF_CACHE_PLAN.md), not the
previous Map-only cursor/coordinator design. Current production behavior remains
in [ARCHITECTURE](../ARCHITECTURE.md#locations-and-map).

## Map's role

- Map is a located-item projection of the engine's all-Personal-item inventory.
  Retain IDs/capture times for items without GPS too; they are necessary for old-
  date/deletion invalidation elsewhere in the engine.
- The metadata engine owns the v7 item source cursor, authoritative lookups,
  bounded reconciliation, baseline/fence, fallback and transaction. Map has no
  independent persisted cursor, Diff call, freshness proof or scan coordinator.
- Cold Map demand may trigger one shared lightweight full Personal inventory
  baseline. Cold ordinary browsing must remain useful without waiting for it.
  Keep the current 1,000-item scan request and 2,048-page bounds unless the unified
  planner provides an equivalent bounded baseline.
- A terminal small item delta updates canonical/compact item state, collection
  day invalidation and the located projection atomically. Missing GPS removes a
  pin when authoritative metadata establishes that absence; do not infer it
  from changed EXIF original bytes or lookup omission.
- Partial, excessive, unknown or unusable intervals invalidate engine coverage.
  Cached pins stay usable/unverified while the engine performs one applicable
  baseline recovery or exposes retry. No experimental modification pagination.
- Preserve `PhotoLocationRecord`, Map clustering/camera behavior and an opaque
  content revision for stale selection checks. An empty source cursor advance
  does not change the content revision. `MapBrowserModel` must honor verification.
- A selected pin/cluster registers an engine-derived ID collection and resolves
  full detail rows through the shared item store/ID lookup, rather than forcing
  whole covering Personal pages to be fetched. Required-ID omission remains an
  incomplete/unavailable result, never an inferred tombstone.

## Evidence retained

The [2026-10-26 analysis](../captures/MAP_DIFF_RESULTS_2026-10-26.md) establishes
12 v7 additions, eight same-ID edits and 12 deletions with successful replay/fence
checks. GPS removal remained unready because the NAS retained coordinates.
The 5,000-photo modification interval was explicitly partial at 2,000 entries.
A later [Android follow-up](../captures/ANDROID_MAP_DIFF_CAPTURE_2026-10-26.md#bounded-follow-up-after-the-third-run)
returned all 5,012 known tombstones in one terminal response, matched on replay,
and fenced empty. Complete modification pagination was not observed.

These results justify the engine's bounded item path with conservative recovery;
they do not establish Favorites/album membership or every metadata field. The
unified plan includes authoritative providers in the same engine for unproven
sources and at most two short membership experiments if their Diff eligibility
is desired. Do not restart broad evidence gathering or ship the superseded
Map-only engine while centralization is under way.

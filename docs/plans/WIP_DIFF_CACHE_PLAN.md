# Diff-Based Cache Validation Plan (SYNO.Foto.Browse.Diff)

Status: WIP ticket, not implemented. This plan records a server capability found by probe and the cache improvements it enables. The current cache and the map feature work without it; implementation is a separate cache-focused change and should not start before the remaining probes listed at the end.

## Background

The cache validates demanded resources once per app run because the NAS may change between runs:

- Every demanded timeline page is revalidated with a network request, even on a run where nothing changed.
- The Personal Library timeline index and the Personal Space album list are refetched every run.
- The map's location index is validated with the Personal Library timeline fingerprint. On any mismatch it is rebuilt with a full positional walk (`Browse.Item` list, no date bounds, 1000-item pages). On the current ~58,760-item library that is roughly 59 requests and minutes of wall time.
- Positional scan pages cannot be cached across runs: `list` returns no total or cursor, and any addition or removal shifts every later offset, so "page N" is a different slice after any change. Only content-anchored pages (date bounds plus an intra-range offset) are stable enough to cache and revalidate.

## Findings: `SYNO.Foto.Browse.Diff`

Read-only probe against `cirrus` on 2026-10-06 (details recorded in [`../SYNOLOGY_PHOTOS_API.md`](../SYNOLOGY_PHOTOS_API.md)):

- The API is advertised (`minVersion` 1, `maxVersion` 7), for both `SYNO.Foto.Browse.Diff` and `SYNO.FotoTeam.Browse.Diff`.
- `get_version` returns an opaque cursor pair, `diff_version` plus `version_time` (epoch milliseconds).
- `get` requires both cursor fields exactly as issued: a missing field returns error 120, a mismatched pair returns error 700.
- `get` with the current pair returns the next cursor plus change lists for two domains:

```json
{
  "diff_version": 1780603,
  "version_time": 1791277292636,
  "item":  { "modify": [], "delete": [] },
  "album": { "modify": [], "delete": [] }
}
```

So it is a global "what changed since this cursor" feed for the whole library — not a per-section or per-date query. Still unverified: the entry shape inside `modify`/`delete` (IDs or full records, and whether added items are reported as modified), how old a cursor remains valid, and whether Shared Space behaves identically.

## What it can improve

### Timeline page validation

Today a demanded page is always refetched once per run. With the feed, the app can hold the last cursor and, when a page is demanded, treat it as verified when none of the item IDs it contains appears in the modified or deleted sets — no request. Only pages touched by the change set are refetched. Metadata-only edits (a GPS or EXIF change) map to exactly the pages containing those items. On a run with no changes, browsing could serve everything from cache after one small feed call.

### Timeline index and album list

The timeline index and album list are cheap per-run requests, but the feed can tell us when they cannot have changed, letting launch stay entirely on cached data. The album change lists extend the same idea to the album overview and opened album snapshots.

### Location index and the map (primary near-term motivation)

Today, any library change forces the full scan again, even one new photo. With the feed:

- The map stores its cursor with the location payload. On open, if the cursor is accepted and the delta is small, it fetches metadata only for the modified item IDs, upserts their records, drops the deleted IDs, and stores the new cursor. No positional walk.
- A typical "photos imported" run becomes one cursor call plus a small metadata fetch, and the map and timeline consume the same change set.
- When the delta is large or the cursor is rejected, validation degrades in steps: the timeline day counts identify added, removed, and count-changed days; only those days are refetched through the normal bounded page pipeline (which caches them as ordinary timeline pages); a full positional walk remains the last resort.
- An intermediate option exists even if the feed proves unusable: day-level rescan anchored on day counts needs no new endpoint and replaces a library-wide walk with changed-day requests. Its known gap is edits that do not change a day's count, such as an in-place GPS change or a same-day delete-plus-add.
- A manual and/or periodic full rebuild stays available for anything the feed does not report.

The map feature itself is complete; this only changes how its index is kept current.

## Safety and fallbacks

- The feed is an optimization layered over existing behavior, never a replacement. A pruned or rejected cursor falls back to today's per-run validation, fingerprint validation, and full scan.
- "Verified because unchanged since the cursor" is a new freshness category. It must be reconciled with existing validity rules: mutation epochs, local favorite writes (which themselves advance the feed), and cache clearing must all invalidate it correctly.
- Cursor rejection and very large deltas must be expected, cheap, and invisible except for the normal progress UI.

## Open probes before implementation

1. After one real library change: the entry shape in `item.modify`/`item.delete` (IDs versus records), whether additions appear as modified, and whether in-place metadata edits are reported.
2. Cursor retention: how old a `(diff_version, version_time)` pair the server still accepts.
3. Whether `album.modify`/`album.delete` covers normal and condition albums (and Shared Space through `SYNO.FotoTeam.Browse.Diff`).
4. Typical delta sizes for a single import and a bulk import, to choose degradation thresholds.

## Out of scope

- Polling during a session. The session remains non-polling; the feed is consulted at run start or first demand.
- The map's UI, clustering, and filtered browsing, which are implemented and work as documented in [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

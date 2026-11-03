# Timeline paging (offline analysis, 2026-10-27)

Based on existing HARs and source; no NAS requests. Counts are examples from one library.

## Wire topology

| Source | NAS sections | Unique days | Section limits |
| --- | ---: | ---: | --- |
| Personal full timeline v6 `get` | 494 | 2,192 | 5–228 |
| Personal `get_init_timeline` | 4 | 14 | 109–163 |
| Favorites v6 `get` (`favorite_only=true`) | 3 | 69 | 102–139 |

- Sections pack several small days (for example nine days in one 163-item section) and split large days (a 228-item day became two 114-item sections). The largest observed day held 5,683 photos.
- 31 days repeat across sections with consistent whole-day counts.
- Initial and full endpoints do not share packet boundaries.
- Items are fetched with `start_time`/`end_time` from the section's day bounds, then `offset`/`limit`, where the offset is relative to that date-range query, not the whole collection.

## Findings

- Section indices and packet boundaries are not stable identities. Synology's repacking when a new day appears was not established.
- Logical day slots keyed by `(collection, day, dayOffset, capacity 250, order policy)` stay stable: a new day adds slots; older days keep their keys. Growing a day invalidates all slots of that day only; a date move invalidates both days; an unknown old date invalidates the collection scope.
- One request per logical slot would be worse than the NAS sections (2,245 slots versus 494). An offline greedy grouping (at most 1,000 items and 32 days per batch) gave 92 Personal and 3 Favorites batches. This is illustrative, not a benchmark.
- Responses must be demultiplexed by day and server order, validated against expected counts before membership is marked current, and never silently drop unexpected days.
- Albums currently synthesize one day per section from an ID/time scan; Library and Favorites retain NAS sections.

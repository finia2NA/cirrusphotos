# Timeline paging investigation — 2026-10-27

This is an offline inspection of existing captures and current source. No NAS
requests, file mutations or authenticated probes were performed. Capture counts
are historical examples, not measurements of the current account/library.

## Observed wire topology

| Capture | Source | NAS sections | Unique days | Sum of section limits / unique day counts | NAS section limits |
| --- | --- | ---: | ---: | ---: | --- |
| `firstone.har` | Personal full timeline v6 `get` | 494 | 2,192 | 58,712 / 58,712 | 5–228 |
| `firstone.har` | Personal `get_init_timeline` | 4 | 14 | 500 / 500 | 109–163 |
| `favoritesAlbum.har` | Favorites v6 `get`, `favorite_only=true` | 3 | 69 | 344 / 344 | 102–139 |

The Personal full capture repeats 31 days across multiple sections. Repeated
entries have consistent whole-day counts. The largest day contains 5,683 photos.

Examples without private dates:

- One Personal section has `offset=0`, `limit=163` and nine day counts
  `[40,15,10,5,25,29,26,5,8]`: several complete small days packed together.
- The next day has 228 items and is split into sections `(offset=0,limit=114)`
  and `(offset=114,limit=114)`, both describing that same day/count.
- A later initial-timeline packet has four day counts `[9,12,34,54]` and limit 109;
  the corresponding full-timeline section has `[9,12,34]` and limit 55. Initial
  and full endpoint packet boundaries therefore need not be identical.

`SynologyClient.items(in:collection:)` sends the section's oldest/newest day
bounds as `start_time` / `end_time`, then its `offset` and `limit`. The offset is
relative to **that date-range query**, not the entire collection. Favorites uses
the same request shape with `favorite_only=true`; normal albums use `album_id`
and explicit capture-time-descending sorting.

`LibraryIndex` already maps these wire sections into day slices, with section,
page-local, day-local and collection-ordinal positions. The browser's section
index/ordinal is a navigation position, not durable cache identity.

Albums currently differ at catalog acquisition: `albumTimeline` scans item
IDs/times and `DayGroupedTimelineBuilder` synthesizes one day per section,
splitting days at 1,000 entries. Library/Favorites currently retain the NAS's
packed sections. They can share a **normalized** day-page model without sharing
an identical catalog endpoint.

## What can be concluded about new days

The capture does not establish Synology's exact before/after repacking algorithm
for a newly added day. Do not claim every new day shifts every old wire section,
or that old wire section numbers stay stable. The source and captures establish
that server packet boundaries and section array indices are unsuitable as stable
item/page identities.

The proposed normalization removes this dependency:

- Deduplicate a full catalog into capture-local day counts; build logical slots
  keyed by `(collection, day, dayOffset, capacity=250, order-policy)`.
- A new newest/oldest/middle day adds its own slots. Older days retain their slot
  keys, although collection ordinals, navigator positions and section indices move.
- A 1,500-item day has six slots at offsets 0,250,500,750,1000,1250. Growing to 1,501
  adds offset 1500. All slots **of that changed day** become unverified, since an
  insertion can shift membership across every within-day boundary. Other days'
  data need not be invalidated.
- A date move invalidates both days; an unknown old date requires conservative
  collection-scope invalidation. The shared all-item ID/time inventory supplies
  old dates even for deleted photos without GPS or full details cached.

These logical-key invariants were checked with a small offline model. Actual NAS
membership/order remains authoritative, especially among equal capture times.

## Logical pages must not mean individual network requests

At capacity 250, the captured Personal catalog would have 2,245 logical day pages,
and Favorites 69. Naively issuing one request per logical page would be worse
than the captured 494 and 3 NAS sections.

A bounded greedy offline transport grouping (adjacent populated days, at most
1,000 items and 32 days per batch, splitting larger days) produces 92 Personal
batches and 3 Favorites batches for these counts. This is an illustration, **not a
latency benchmark or promised request count**: actual demand, cached rows,
annotation validation, fences and missing-detail fetches affect work.

The architecture must separate:

1. stable day-local storage/navigation slots;
2. transient bounded network batches that can cover several days or adjacent
   offsets of a large day;
3. canonical item detail rows reused across collections.

A batch response is demultiplexed by capture day and server order into logical
slots. Validate complete expected counts/positions before marking membership
current. Never silently drop unexpected days or compact missing item details.

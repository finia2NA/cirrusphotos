# Map/Diff experiments on Diff v1 (2026-10-25 to 2026-10-26)

Goal: decide whether Diff can prove cached Map/Library metadata unchanged. Filesystem fixtures were written to the `phototest` mount, and the NAS indexed them. Diff v1 `get` with a saved cursor was compared against whole-library, folder and direct-ID reads.

## Bulk run (first runner)

Run took about 5 h 42 min and made 2,433 requests (870 MB received). Result counts (16 pass, 12 fail, 12 inconclusive, 6 skipped) include setup and cleanup stages and are not a feature pass rate.

| Experiment | Result |
| --- | --- |
| Single addition, GPS gain, capture-time edit | Metadata became visible, but Diff intervals and replays held no modifications. |
| 5,000-photo addition | Final inventory complete and correct; Diff reported zero modifications (142-byte response), so all 5,000 events were missing. |
| Single deletion | Tombstone reported; replay and fence passed. |
| 5,000-photo deletion | All 5,000 tombstones returned (35 KB), identical replay, empty fence. The first-recorded "3,872 missing" gap was an artifact: those files had not yet been unlinked when the non-atomic page walk ran. |
| Cursor aged 3,603 s | Still accepted and replayed identically, but did not report the sentinel addition. |
| GPS removal | The API kept returning the old coordinates until the deadline. Inconclusive. |

Runner defects exposed: 152 duplicate-ID scan failures during indexing ended stages that should have retried, so the 1,200-photo and 2,500/10,000/20,000 stages never produced stable inventories and the quiet pagination tests were skipped. No addition response approached 4 MiB, so truncation behavior was not exercised.

## Focused run (second runner)

About 1 h 55 min. Identical results for January 2020 and current-date cohorts.

| Operation | Expected events seen |
| --- | --- |
| Additions | 0/6 per cohort |
| GPS gain/change, capture-time, pixel edits (completed) | 0/4 per cohort |
| Deletions | 6/6 per cohort |
| GPS removal | Old coordinates retained for about 601 s; inconclusive |

Every completed comparison had consistent reads, stable metadata, identical replay and an empty fence, so the missing modifications are not scan artifacts. All edits kept item identity and advanced the thumbnail revision. Old capture dates are not the explanation. The earlier main-account probes did return modifications, which pointed to a different request contract (see the v7 findings).

## Conclusions

- Diff v1 `get` modifications cannot authorize cache reuse in the tested path; deletions work.
- Do not assume every mutation path behaves like the filesystem path, or that Diff is universally broken.
- GPS removal is slow or does not clear coordinates; treat it separately from feed correctness.
- Unverified: permission changes, service reset, large-response truncation, long cursor retention.

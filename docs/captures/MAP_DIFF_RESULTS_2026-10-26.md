# Map/Diff overnight run — 2026-10-26

Run: `map-diff-run-20261025T221724Z-be8cb50a` (private, ignored artifacts beside
this document). Reviewed `report.json`, stage checkpoints, `events.jsonl`, and
compressed comparison/first-gap evidence. No additional NAS writes or probes
were performed during this review.

The runner completed from 2026-10-25 23:17 to 2026-10-26 04:59 Europe/Berlin
(22:17–03:59 UTC), approximately 5 h 42 min. It recorded 16 pass, 12 fail,
12 inconclusive and 6 skipped results. These counts include setup, identity and
cleanup stages and must not be interpreted as a feature pass rate. It made
2,433 requests and received 869,613,358 response bytes. Two expired-session
responses were recovered; no transport failures were logged. Final cleanup
reported one remaining library item, matching the original baseline digest,
and zero manifest-owned files.

## Reliable findings

| Experiment | Observed result | Interpretation |
| --- | --- | --- |
| Single additions and GPS gain/capture-time edit | Expected item metadata became visible, but saved-cursor Diff v1 intervals/replays contained no modifications. | The tested account/request/filesystem path cannot authorize cache reuse from an empty Diff. This does not identify the missing server contract or imply every mutation path behaves identically. |
| 5,000-photo addition | Complete final inventory contained the original item plus all 5,000 generated photos, with expected timestamp/GPS. Original and replayed Diff intervals both contained zero modifications; all 5,000 expected events were missing. Response was only 142 bytes. | This is strong negative coverage evidence despite interrupted sampling during copying. Final-state coverage failure is independent of those sampling interruptions. |
| Single deletion | One expected deletion appeared; replay and final fence checks passed. | Deletion works in this observed case. |
| 5,000-photo deletion | Final comparison received all 5,000 unique tombstones, no final missing deletions, identical replay and an empty fence. Response was 35,141 bytes. | Eventual deletion coverage succeeded. The overall failure label also contains transient observations that need qualification below. |
| Cursor aging | A cursor retained for 3,603 seconds was accepted and replayed identically, but did not report the generated sentinel, which was present in the item inventory. | Observed one-hour acceptance, not successful retained change coverage or evidence about resets/expiry. |
| GPS removal | Local fixture no longer requested GPS; the API still exposed coordinates when the small-test deadline elapsed. | Removal remained inconclusive; this is consistent with the first run's retained-coordinate behavior. |

The addition/modification results differ from the earlier main-account probes.
All generated fixture capture dates are in January 2020. That difference provides
a testable hypothesis about date/query scope; it is not evidence of a date filter.
Account and operation-path differences also remain possible. Do not assume a
universal Diff failure or enable another API version without validating its
request and cursor contract.

## Runner limitations exposed by the run

There were 152 duplicate-ID scan failures while indexing/deletion was in progress.
The runner caught these during writes and finished each batch, but a duplicate
on the first subsequent scan ended that stage instead of retrying until its
indexing deadline. The 1,200 equal-timestamp setup and 2,500/10,000/20,000 addition
stages were affected. All requested files in those batches were written, but
complete stabilized inventories were not established before cleanup. Consequently,
the dedicated quiet-library pagination and concurrent scan/lookup tests were
skipped. Duplicates during changing positional pagination do not establish that
quiet equal-time ordering is unstable.

The 5,000-deletion stage's first recorded gap reported 3,872 apparent missing
deletions. Correlating the saved inventory with the ordered filesystem deletion
and remaining-file count shows **all 3,872 files had not yet been unlinked** at
that observation. They were omitted by the non-atomic page walk, not established
as deleted photos missing from Diff. One additional transient GPS modification
was also recorded. Thus the overall failure label does not prove 3,872 delayed
or omitted tombstones; eventual tombstone coverage was complete.

GPS change and same-path replacement had reached their expected metadata by the
last sample but timed out before the full quiet window. Later inventory changes
reset the stability timer; at the hard final deadline only about 56–57 stable
seconds remained accumulated. These are stability/time-budget inconclusives,
not proof that the requested metadata never appeared.

No addition response crossed 4 MiB. The largest completed addition Diff was
142 bytes because modifications were absent. Large-response/truncation coverage,
quiet enumeration, permission changes and service-reset evidence remain open.

## Next useful work

1. Make inconsistent observation scans retryable within the indexing budget,
   while retaining their diagnostic evidence. Keep strict quiet-scan comparisons
   as a separate test. Establish readiness using known fixture identity and
   independent folder/ID reads where possible.
2. Corroborate apparent deletions before labeling a Diff visibility gap. A hole in
   an offset walk during concurrent mutation is not authoritative absence.
3. Preserve the 90-second quiet requirement while giving small tests enough
   bounded settling time after the expected state first appears.
4. Run a small fresh-baseline comparison of historical versus current capture
   dates and confirm the Diff request/account contract before another bulk run.
   A HAR of `phototest` opening/reloading Photos after a controlled addition may
   help compare request parameters. If the web client does not issue Diff, it
   cannot resolve that contract by itself.

These results do not support enabling production Diff freshness. They also do
not rule out improving provisional cache reuse independently of Diff. No runner
or application behavior was changed as part of this results review.

## Focused second run — completed 2026-10-26

Run `map-diff-run-20261026T140929Z-474664a5` completed at 17:04 Europe/Berlin,
after approximately 1 h 55 min (14:09–16:04 UTC). The historical/current cohorts
produced identical coverage outcomes:

| Operation | January 2020 fixtures | Current-date fixtures |
| --- | --- | --- |
| Additions | 0/6 expected modification events | 0/6 expected modification events |
| Completed GPS gain/change, capture-time and pixel edits | 0/4 expected modification events | 0/4 expected modification events |
| Deletions | 6/6 expected tombstones; all checks passed | 6/6 expected tombstones; all checks passed |
| GPS removal | Previous coordinates retained through approximately 601 seconds | Previous coordinates retained through approximately 601 seconds |

Every completed addition/edit comparison had consistent whole-library, folder
and direct-ID reads, the expected metadata, stable observations, identical Diff
replay and an empty final fence. The absent modification events therefore cannot
be explained by the previous bulk runner's non-atomic page-walk artifacts. There
were no observation retries, network failures or unsuccessful API responses.
The current-date additions chose their EXIF timestamp after baseline acquisition;
old capture dates alone do not explain the missing modification events.

All eight completed edits preserved item identity and advanced the thumbnail
revision. GPS gain/change and capture-time edits reached the requested metadata;
pixel edits advanced the descriptor as expected. Both GPS-removal tests also
advanced thumbnail revision, but retained their previous nonzero coordinates,
so they remained inconclusive rather than being counted as isolated GPS changes.

The run recorded 26 passes (12 deletion checks, 12 per-case cleanups, startup and
final cleanup), 20 modification-coverage failures, two GPS-removal inconclusives,
and no skipped stages. All 12 known fixture IDs were absent after final cleanup,
and the ownership manifest is empty. Detailed evidence is in the run's
`report.json`, `cohort-summary.json`, `events.jsonl` and compressed stage artifacts.

The tested v1 Diff request/account/filesystem path still cannot validate Map
freshness. The date comparison rejects historical dates as a sufficient
explanation; it does not establish that capture time never affects other query
variants. Next investigate actual Synology-client request shape and account/path
coverage, including why the earlier main-account probes returned modifications.
A `phototest` web HAR spanning a controlled addition and refresh can help compare
requests; if the web client does not issue Diff, the capture cannot establish
Diff semantics by itself. No new NAS probes, file mutations, runner changes or
production-policy changes were performed during this review.

## Subsequent official Android capture

The [mobile capture and controlled comparison](ANDROID_MAP_DIFF_CAPTURE_2026-10-26.md) identified Diff v7 `list` as the app’s item feed. It returned an indexed addition omitted by both v1 and v7 `get` from the same cursor. This does not invalidate the earlier v1 observations; it establishes a different request to validate before another broad run. Production Diff remains disabled.

## Third runner: mobile v7 item feed — completed 2026-10-26

Reviewed the completed private run `map-diff-run-20261026T193951Z-2f69ccf8`:
`report.json`, checkpoint/journal, cohort summary, detailed events, compressed
stage evidence and raw mobile response data. This review made no NAS requests
or photo mutations. Total elapsed time was about 2h 33m (19:39:51–22:12:31 UTC).
There were **48 passes, four inconclusive outcomes, no failures and no skipped
stages**; passes include cleanup checks and must not be mistaken for 48 mutation
comparisons.

| Observation | Result | Interpretation |
| --- | --- | --- |
| Historical/current-date additions | 12/12 passed, zero missing events | Positive coverage for v7 `list`, unlike the earlier v1 `get` results. |
| GPS gain/change, capture-time and pixel edits | 8/8 passed, all preserved item identity; zero missing events | Both cohorts passed replay equality, quiet returned-cursor fences, metadata persistence and continuous sampling checks. No direct metadata/feed visibility gaps were observed. Overwrite/reindex coverage does not prove an isolated GPS-only editor contract. |
| Focused deletions | 12/12 passed | Exact known-ID tombstones, repeatable replays, empty fences and corroborated absence. |
| GPS removal | Both inconclusive | The desired no-GPS state never appeared before the deadline. Whole-library, folder and direct-ID reads still agreed on the previous coordinates. Diff did report a modification; this is not evidence of a missing feed event. |
| 5,000-photo addition | Inconclusive | All 5,000 generated photos eventually appeared with expected GPS/time, but inventory content revisions kept changing. No 90-second stable window was achieved before the separate 10-minute settling deadline. |
| Bulk Diff completeness | Unproven, explicitly partial | All 30 bulk observation responses had `has_next=true` and 2,000 modified items. Largest captured response was 2,485,858 bytes, below 4 MiB. These are partial intervals, not 3,000 missing-event verdicts or complete-response passes. Raw data was saved before rejection. |
| Bulk deletion comparison | Inconclusive | A nonempty baseline fence prevented the measured deletion test from starting. Journal-scoped cleanup subsequently removed the files; cleanup is not a substitute for a measured deletion Diff comparison. |

The final bulk inventory had 5,001 items (the original item plus 5,000 generated
items), all generated metadata matching expectations. The candidate `list_all`
walk encountered no scan retry errors, but the independent folder comparison and
full interval/replay/fence evaluation were not reached. This is not completion
proof for pagination or bulk Diff coverage. Settling signatures changed even
when item count and requested GPS/time were correct; increasing the initial
indexing allowance alone would not fix the separate settling deadline.

Cleanup **did complete**. The journal has zero owned files; the mounted run
folder has zero generated JPEGs. Final cleanup evidence contains one original
library item and zero direct lookup results for all **5,012 known test IDs**
after the 90-second absence window. No credentials or raw session headers were
needed for this review.

### Next steps supported by this run

1. Capture how the official Android client continues an actual `has_next=true`
   interval, including exact request parameters/cursor changes, termination,
   ordering, repeated pages and replays. Do not guess continuation or treat the
   first 2,000 items as complete. The existing emulator's retained cursor may
   already span enough test changes; inspect that before creating another batch.
2. Give bulk metadata settling a budget proportional to the batch, while keeping
   an absolute bound and the 90-second stable window. Separate inventory readiness,
   metadata revision settling, and Diff continuation outcomes in the report.
   Then rerun the bulk comparison with demonstrated continuation and an independent
   inventory check; wait for a quiet baseline before its measured deletion.
3. Keep GPS-removal indexing behavior separate from feed correctness. Access,
   reset and retention gates remain unresolved. This run does not enable production
   Map Diff freshness, but it provides strong positive evidence for ordinary v7
   additions, same-ID overwrites and deletions.

### Follow-up and stopping decision

The user requested reasonable confidence without days of additional evidence.
A bounded Android/read-only follow-up returned all 5,012 known test tombstones
in one terminal response, matched on replay, with an empty fence and the original
single-item inventory. It did not expose modification pagination because no
modifications remained. No new photos were added. See the [capture follow-up](ANDROID_MAP_DIFF_CAPTURE_2026-10-26.md#bounded-follow-up-after-the-third-run).

The earlier next-step list is superseded for the first product slice: stop broad
probing and implement empty/small complete v7 intervals with an explicit full-scan
fallback on `has_next=true`, excessive changes or unsupported activity. The
[revised implementation plan](https://github.com/finia2NA/syno/issues/20#issuecomment-6478636002) details the
bounded algorithm, tests and short acceptance check. Modification continuation,
service-reset/access experiments and another overnight bulk run are deferred;
they are not claimed as verified or required to exercise a fallback that declines
incremental handling. Production remains unchanged by this investigation.

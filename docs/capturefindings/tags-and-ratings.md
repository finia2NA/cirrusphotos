# Tags and ratings (2026-11-04)

Evidence: `docs/captures/tagsandratings.har` (Synology Photos web client: create a tag, add it to one photo and to several, set and clear ratings, view tagged and rated photos, repeated in Shared Space; 270 requests) and write probes on the disposable `phototest` account. No IDs or names from the main account are recorded here.

## Capture

- Personal Space creates tags with `Browse.GeneralTag create` v2 and applies them with `Browse.Item add_tag` v7, followed by `GeneralTag get` for the new `item_count` and `Item get_tag` for the selection. `GeneralTag suggest` fills the typing popup (empty keyword returns the most used tags).
- Shared Space uses the same calls under `SYNO.FotoTeam`, plus `remove_tag`. The Personal removal was not captured; `phototest` confirmed that it behaves identically.
- Ratings use `Browse.Item set` v7 with `rating`; one request covers several photos. Rating 0 clears.
- Opening a tag issues `Browse.Item list` v7 with `general_tag_id`. The detail view requests `additional` with `tag` and `rating`; list views do not.
- `get_tag` for several items reports `intersection` (tags on all) and `union` (tags on any).

## Probes on `phototest`

- `Browse.Item list` with `additional=["tag","rating"]` returned both fields in Personal Space. A read-only call on the main account returned them in Shared Space too.
- After `create`, `add_tag` and `set rating`, a Diff v7 `list` from a fresh cursor returned both items in `item.modify` with `additional.tag` and `additional.rating` (alongside thumbnail), so the existing Diff reconciliation covers these edits.
- Duplicate `create` is idempotent; an empty name is error 120; `rating` 6 and -1 are error 120; unknown tag IDs report the items in `error_list`; unknown items are ignored; a tag with no items disappears; `GeneralTag delete` does not exist.

## Consequences for the app

- Ratings and tags are cached with each item (`additional.rating`, `additional.tag`) and indexed as filter facets, so tag and rating filtering needs no server request. Synology's tag album (`general_tag_id`) is only used by the Tags destination.
- After each write the app reads the affected items back and replaces their cached rating and tags, rather than predicting the result.

## Not covered

- Renaming or deleting tags (a tag disappears when its last item loses it), tag limits, and whether the other space rejects or ignores IDs from the wrong space.
- Tags and ratings on Shared Space items were captured from the web client only; the app's writes there are unverified on a disposable fixture.

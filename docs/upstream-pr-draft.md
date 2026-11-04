# Draft PR (not opened) — delete after filing

Fork branch: https://github.com/finia2NA/SynologyPhotosAPI/tree/document-observed-photos-1.9-behavior
Target: zeichensatz/SynologyPhotosAPI `master`

## Title

Document behavior observed with Synology Photos 1.9.1

## Body

I've been building a client against Synology Photos 1.9.1 (web) and used web-app HAR captures and read-only probes to check this repo's pages. The examples here look like they come from an older Photos version, so some differences may be version drift; where that is likely, the page now names the version it describes. Everything in this PR is something I observed. Where I could not verify upstream text, I left it alone.

How this was established: web-app HAR captures of Photos 1.9.1 and read-only requests against one NAS. The pages themselves state the behavior without version or sample references; the evidence is here.

Changes:

- **Thumbnails** (`README.md`): the `id` is `additional.thumbnail.unit_id`. It equals the item `id` in the examples here, but differed for 739 of 1,055 items in one capture. The `/synofoto/api/v2/{p|t}/Thumbnail/get` path is the one the 1.9.1 web client uses.
- **`Browse.Item.list`**: fills in the `???` rows for `video_convert` (qualities seen: `high`, `orig_h264`, `medium`), `video_meta.duration` (milliseconds), `orientation`/`orientation_original`, and adds `folder`, `favorite`, `album_id` and `start_time`/`end_time`. `exif` values are display strings (empty for items without EXIF). `resolution` is already in display orientation. `time` is the photo's local wall-clock time encoded like a Unix timestamp. `limit=5000` was accepted; there is no `total`. `method=get` accepts an `id` array (up to 1000 tried).
- **`Browse.Album.list` / `Browse.Folder.list`**: the `sort_by` rows list File Station's sort fields (`name`, `size`, `mtime`, ...). Photos sends `sort_by="album_name"` for albums (version 4, together with `category="normal"`) and `sort_by="filename"` for folders (version 2), so these rows and examples now show those requests.
- **Shared albums** (`README.md`): a signed-in recipient reads another user's album with the normal session plus `passphrase`, without `Core.Sharing.Login` or `x-syno-sharing`. Observed with one recipient account.
- **Login** (`README.md`): `session=SynologyPhotos` was rejected with error 402 for a non-admin account while `session=webui` worked. One account only, so the cause is not established and the page says "appears".

Not included, for separate PRs if you want them: album write calls (`NormalAlbum` `create`/`add_item`/`delete_item`, which confirm the shapes discussed in #16), Timeline, Diff, Download/Streaming and Sharing.

## Commands to open it later

```bash
gh pr create --repo zeichensatz/SynologyPhotosAPI --base master \
  --head finia2NA:document-observed-photos-1.9-behavior --draft \
  --title "Document behavior observed with Synology Photos 1.9.1" --body-file <body.md>
```

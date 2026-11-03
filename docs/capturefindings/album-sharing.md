# Album membership and sharing (captured 2026-11-01 onward)

Based on web-app HARs of an owner, an anonymous public visitor and a signed-in recipient, plus bounded read-only probes with the disposable recipient account. Passwords, sharing references, links and item IDs are omitted. All writes are POST `application/x-www-form-urlencoded` to `/webapi/entry.cgi/<API>`; strings and arrays use JSON serialization inside the form values.

## Identity

- Sharing is an attribute of an owned normal album. Album ID, `type: "normal"` and owner stay constant while `shared` goes false → true → false. The album stays in `Browse.Album` v4 `list` with `category: "normal"`. There was no copy or conversion; no second metadata engine is needed.
- Membership requests use item IDs, which differ from `additional.thumbnail.unit_id`.

## Membership (`NormalAlbum` v1)

| Operation | Parameters | Response |
| --- | --- | --- |
| `create` | `name`, `item: [ids]` (empty array creates an empty album; thumbnail is `{}`) | `data.album`, `data.error_list: []` |
| `add_item` | `id`, `item` (also works while shared) | `data.error_list: []` |
| `delete_item` | `id`, `item` | `{"success":true}`, no data |
| `Album` v1 `delete` | array of album IDs | data-less success |

Chooser: `NormalAlbum` v2 `list` with `category: "addable"`. Album reads: `Album` v4 `get`/`list` with `additional: ["sharing_info","flex_section","provider_count","thumbnail"]`. Items: `Item` v7 `list` with `album_id`. Partial-error shapes and batch limits are unknown; never ignore `error_list`. Removal while shared is inferred, not captured.

## Owner sharing

1. `Sharing.Passphrase` v1 `set_shared` (`policy: "album"`, `album_id`, `enabled`) returns a sharing reference and link even when `enabled: false`.
2. `Sharing.Misc` v1 `list_user_group` lists principals (`team_space_sharable_list: false`).
3. `Sharing.Passphrase` v1 `update` with `passphrase`, `expiration` (epoch seconds, 0 for none), optional `password` and a `permission` array of `{action: update|delete, role, member: {type: user|public, id}}`.

Findings:
- Enabling and permission assignment are separate requests; intermediate state and recovery after a failed second call are untested.
- Permission updates are incremental. Omitting a grant does not remove it, and an empty array cannot be assumed to revoke access.
- Roles written: `download`, `view`, `upload` (Provider), public `view` and public `download`. Public access appears as `privacy_type` (`private`, `public-view`, `public-download`), not in the named-user list.
- Clearing a password sends the JSON empty string `""`.
- Readback after changes is authoritative. One expiry was end-of-day in Europe/Berlin; how the web app chooses boundaries in general is unknown.
- `set_shared` with `enabled: false` sets `shared: false`, empties `permission`, and clears the top-level `passphrase` and `sharing_link`, but nested `sharing_info.passphrase` stays nonempty. Use `shared` and effective permissions, not reference existence. Re-enabling must not be assumed to restore grants.
- Two ID namespaces: permission writes use the DSM UID; `UserInfo.me.id`, permission `user_id` and the grant `db_id` use the internal Photos ID. They are not interchangeable.

## Public link visitor

Under `/mo/sharing/webapi/entry.cgi/<API>`: `Setting.Guest` `get`, `Core.Sharing.Login` `login` (sharing ID and password, returns `sharing_sid`), `Sharing.Passphrase` `get_permission` (view only, `user_id: -1`), `Album` v4 `get` and `Item` v7 `list` with `passphrase`, and `/synofoto/api/v2/p/Thumbnail/get` with `passphrase` and `_sharing_id`. Calls after login carry `x-syno-sharing` equal to the sharing reference. The capture does not show how `sharing_sid` is propagated (no cookie or header), so guest-session handling is unresolved. Items keep original IDs and ownership.

## Signed-in recipient

Normal `/webapi/entry.cgi` session. `Album` v4 `get`, `Item` v7 `list`, `get_permission` (view and download true for a Downloader) and thumbnails all select content by `passphrase`; no login call or sharing header. The reference is what selects other-owned content: `Album` get by album ID returned nothing, but by reference it did.

- **Discovery**: `Sharing.Misc` `list_shared_with_me_album` (v1 probed; v2 in the web client with `additional` including `access_permission`, `sharing_info`, `thumbnail`). The recipient's own normal and addable lists were empty. Pagination, revocation and caching lifetimes are unverified.
- **Provider**: owner grants role `upload`; the recipient's `access_permission.upload` is true for Provider and false for Viewer. A Provider adds a personal photo with `NormalAlbum` v1 `add_item` carrying the sharing reference and an item-ID array; a reference-scoped read confirms it.
- **Download**: `SYNO.Foto.Download` v2 `download` as POST with `force_download`, an `item_id` array, JSON-string `passphrase` and `download_type: "source"`; the response is an attachment. The app transport downloaded a nonempty original this way. Compressed and multi-item downloads are unverified.

## Open points

Recipient denial after revocation or expiry, re-enable behavior, password replacement, role changes other than those above, and guest session propagation were not captured. Handle uncertain outcomes conservatively and confirm writes by readback.

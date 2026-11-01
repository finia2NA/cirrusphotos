# Album membership and sharing: captured NAS contract

Analyzed locally on 2026-11-01. No requests were replayed and no NAS writes were performed. This records observed server behavior and implementation implications, not implemented application features or a UI design.

## Evidence

- `albums.har`: 168 entries covering creation of `testalbum`, addition/removal of photos, owner-side browsing, private sharing, and a downloader grant to `phototest`.
- `publicalbum.har`: 28 entries covering a subsequent change of that same album to public viewing with a password and expiry.
- `pulicperspectivealbum.har`: 37 entries opening the protected public link as an anonymous view-only principal. This is the original guest capture, renamed by the user (filename spelling preserved).
- `phototestperspectivealbum.har`: 84 entries opening the same album in the main Photos application as authenticated `phototest`, with view/download permission.
- `modifyingsharedalbum.har`: 44 entries adding photos while shared, clearing password/expiry, removing public access and `phototest`, adding a different Viewer, then disabling sharing.
- Vendored unofficial reference: `../SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.Browse.Album.list.md`, `../SynologyPhotosAPI/README.md` (shared-album access), and `../SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.PublicSharing.get_ui_string.md` (permission labels).
- Current implementation: `Sources/SynologyAPI/AlbumModels.swift`, `SynologyClient.swift`, `PhotosTransport.swift`, and `Sources/PhotoCache/CachedPhotosRepository+Albums.swift`.

Entry numbers below are zero-based indexes into each HAR's `log.entries`. Actual passwords, session credentials, sharing references, and links are omitted. Parameter examples show decoded form values; strings and arrays must use the endpoint's observed JSON serialization inside the URL-encoded body.

## Finding: sharing is an attribute of an owned normal album

The created album has ID 69 and stays ID 69 with `type: "normal"` and owner ID 1 throughout private sharing, public sharing, access changes, and disabling sharing. It has two photos after the initial removal and four after two more are added while shared. Its `shared` field changes false → true → false. It remains in `Browse.Album.list` v4 with `category: "normal"`.

The normal list contains 42 albums before and after sharing, with 18 shared before and 19 shared after. The add-to-album chooser also uses a normal-album list containing both shared and unshared albums. There is no captured conversion to another album type, copy of the album, or move of its photos to Shared Space.

This supports implementing one album membership capability and layering sharing settings onto the same album identity. Owner-side addition while shared is now directly captured using the same `NormalAlbum.add_item` endpoint; removal is captured only before sharing, so shared-state removal remains an inference. Signed-in invitee reads use the same album/item models and IDs but select the album by sharing reference. No captured behavior requires a second metadata engine.

## Membership and owner reads

All listed writes are POST requests to `/webapi/entry.cgi/<API>` with `application/x-www-form-urlencoded` bodies.

| Entry in `albums.har` | API / version / method | Decoded parameters | Observed response |
| --- | --- | --- | --- |
| 1, 19, 34 | `SYNO.Foto.Browse.NormalAlbum` v2 `list` | `category: "addable"`, `offset`, `limit: 100`, `sort_by: "album_name"`, `sort_direction: "asc"`, `additional: ["sharing_info","thumbnail"]` | Mixed shared/unshared normal albums for the chooser; an exhausted page returns an empty list. |
| 17 | `SYNO.Foto.Browse.NormalAlbum` v1 `create` | `name: "testalbum"`, `item: [284353]` | `data.album` with ID 69 and count 1; `data.error_list: []`. |
| 48 | Same API v1 `add_item` | `id: 69`, `item: [284359,284358]` | `data.error_list: []`; subsequent get reports count 3. |
| 49, 107, 131 | `SYNO.Foto.Browse.Album` v4 `get` | `id: [69]`, `additional: ["sharing_info","flex_section","provider_count","thumbnail"]` | `data.list` with count, cover, sharing state, and version. |
| 116 | `SYNO.Foto.Browse.Item` v7 `list` | `album_id: 69`, `offset: 0`, `limit: 3`, `sort_by: "takentime"`, `sort_direction: "asc"`, `additional: ["thumbnail","resolution","orientation","video_convert","video_meta","provider_user_id"]` | Three original item IDs: 284358, 284359, 284353. |
| 129 | `SYNO.Foto.Browse.NormalAlbum` v1 `delete_item` | `id: 69`, `item: [284353]` | `{"success":true}` with no data required; subsequent get reports count 2 and a different cover. |
| 66, 152 | `SYNO.Foto.Browse.Album` v4 `list` | `category: "normal"`, paging, album-name ordering, `additional: ["sharing_info","thumbnail"]` | The same album before and after sharing. |

Membership requests use item IDs, not `additional.thumbnail.unit_id`; those identifiers differ in this capture. Removal is an album-membership operation, distinct from deleting a library item. The HAR does not independently re-read the removed item from Library afterward.

The empty `error_list` on create/add must not be ignored in a future write implementation. Nonempty partial-error shapes and batch limits are not established here. `delete_item` demonstrates that successful responses need not carry `data`.

## Private sharing

These calls use the owner's existing authenticated session:

1. Entry 135 reads album 69 with `additional: ["sharing_info"]`.
2. Entry 136 calls `SYNO.Foto.Sharing.Passphrase` v1 `set_shared` with `policy: "album"`, `album_id: 69`, `enabled: false`. It returns a nonempty `data.passphrase` and `data.sharing_link` even while disabled. This is consistent with preparing a sharing reference for the dialog; do not treat reference existence as proof sharing is enabled.
3. Entry 137 calls `SYNO.Foto.Sharing.Misc` v1 `list_user_group` with `team_space_sharable_list: false`. It returns principals in `data.list`, including `{id:1036,name:"phototest",type:"user"}`. Do not confuse that principal ID with the permission record's later `db_id`.
4. Entry 149 calls `set_shared` with `album_id: 69`, `policy: "album"`, `enabled: true`. It returns the same sharing reference and link.
5. Entry 150 calls `Sharing.Passphrase` v1 `update` with the returned `passphrase`, `expiration: 0`, and the permission change below.

```json
{
  "permission": [
    {
      "role": "download",
      "action": "update",
      "member": {"type": "user", "id": 1036}
    }
  ]
}
```

The final list at entry 152 reads back `shared: true`, `privacy_type: "private"`, `enable_password: false`, `expiration: 0`, and a permission record for `phototest` with role `download`. A private album can have a sharing link; possessing a link alone does not mean it is publicly accessible.

Sharing activation and permission assignment are separate successful requests, not a captured atomic transaction. Their intermediate access state and recovery after a failed second request are untested. Before implementing this workflow, establish or conservatively verify its actual state after uncertain outcomes. Do not invent a configure-before-enable order without evidence that updates to a disabled share are supported.

## Public viewing, password, and expiry

Entry 0 of `publicalbum.har` first reads back that private shared state. Entry 9 then sends one `SYNO.Foto.Sharing.Passphrase` v1 `update`:

```json
{
  "passphrase": "<existing sharing reference>",
  "password": "<chosen password>",
  "expiration": 1794956399,
  "permission": [
    {
      "action": "update",
      "role": "view",
      "member": {"type": "public"}
    }
  ]
}
```

It returns `{"success":true}`. The album list at entry 13 confirms:

- Same album ID, type, owner, membership count, sharing reference, and link.
- `shared: true`, `privacy_type: "public-view"`, `enable_password: true`, and the exact submitted expiration.
- Existing named-user `phototest` permission still present with role `download`.

This proves permission changes are incremental: omitting an existing grant does not remove it. Public access is represented as a principal in the write request but appears as `privacy_type` in the read model, outside the named-user permission list. In particular, sending an empty permission array cannot be assumed to revoke access or restore private mode.

The expiry is epoch seconds: `2026-11-17T22:59:59Z`, which is 23:59:59 on November 17 in Europe/Berlin. This is consistent with an inclusive end-of-day selection in that timezone. One capture does not establish how the web app chooses timezone boundaries generally, or whether invitees bypass a public-link expiry or password. Zero was used for no expiry in the private save.

Password submission and the readback flag are established, and `pulicperspectivealbum.har` demonstrates a successful visitor password login. Password removal is established below; replacing one nonempty password with another is not separately captured. Treat passwords as write-only inputs; the sharing reference called `passphrase` is a separate value, not the user-chosen password.

## Protected public-link browsing

`pulicperspectivealbum.har` starts with direct navigation to the sharing link, rather than a signed-in Photos album list. Its relevant calls are:

| Entry | API / version / method | Parameters / response |
| --- | --- | --- |
| 11 | `SYNO.Foto.Setting.Guest` v1 `get` | Guest display/service settings. |
| 24 | `SYNO.Core.Sharing.Login` v1 `login` | `sharing_id` and the chosen `password`; success returns `data.sharing_sid`. |
| 25 | `SYNO.Foto.Sharing.Passphrase` v1 `get_permission` | `passphrase`, `exclude_public: false`; returns view true and download/manage/own/upload false, with `user_id: -1` and empty username. |
| 26 | `SYNO.Foto.Browse.Album` v4 `get` | `passphrase` instead of owner-side `id`, with the same additional fields as the owner get. Returns normal album 69, count 2, password enabled, public-view privacy, and the configured expiry. |
| 33 | `SYNO.Foto.Browse.Item` v7 `list` | `passphrase` instead of `album_id`, paging and capture-time ordering. Returns IDs 284358 and 284359, owner ID 1, provider ID 1. |
| 35, 36 | `/synofoto/api/v2/p/Thumbnail/get` | Thumbnail reads include `id`, `cache_key`, `type`, `size`, `passphrase`, and `_sharing_id`. |

The JSON APIs use `/mo/sharing/webapi/entry.cgi/<API>`. The sharing API requests after login carry `x-syno-sharing` equal to the sharing reference. Although login returns `sharing_sid`, the HAR does not expose a subsequent cookie/header carrying that value: request cookie arrays are empty, no Cookie header is present on the examined API calls, and login has no recorded Set-Cookie header. Therefore session propagation cannot be implemented confidently just from this capture; the older README's cookie recipe is a hypothesis, not a captured current wire fact.

The server's explicit anonymous identity and view-only capabilities are decisive: this capture exercises public access, not `phototest`'s named-user downloader permission. It does establish that the public-link view retains original item IDs and ownership rather than creating recipient copies. It contains no signed-in invitation discovery, photo download, or post-expiry rejection.

## Authenticated invitee browsing

The replacement `phototestperspectivealbum.har` establishes regular authenticated Photos access:

| Entry | API / version / method | Observed contract |
| --- | --- | --- |
| 65 | `SYNO.Foto.UserInfo` v1 `me` | `name: "phototest"`, internal Photos `id: 11`, DSM `uid: 1036`, `is_admin: false`. |
| 69 | `SYNO.Foto.Browse.Album` v4 `get` | Uses `passphrase` and the usual album additional fields. Returns album 69, owned by user 1, with its existing password/expiry and public-view settings. |
| 70 | `SYNO.Foto.Sharing.Passphrase` v1 `get_permission` | `passphrase`, `exclude_public: false`; returns `user_id: 11`, `username: "phototest"`, view/download true and manage/own/upload false. |
| 77 | `SYNO.Foto.Browse.Item` v7 `list` | Uses `passphrase`, offset/limit, capture-time ordering, and the same additional fields as the other album reads. Returns original IDs 284358 and 284359, with owner/provider ID 1. |
| 82, 83 | `/synofoto/api/v2/p/Thumbnail/get` | Uses thumbnail ID/cache key/type/size, `passphrase`, and `SynoToken`. |

Album, item, and permission calls use `/webapi/entry.cgi/<API>`, not the public visitor's `/mo/sharing/webapi` prefix. No `x-syno-sharing` header or `Core.Sharing.Login` call occurs in this authenticated trace. It demonstrates access through a regular signed-in session; it does not establish how to enumerate incoming invitations, since no album-list request is present. The album is still public-view at this point, but the named account receives download authority beyond the guest's view-only authority. A download button asset is loaded; no actual download request is captured.

Keep the identity namespaces separate: permission writes address `member.id: 1036` (DSM UID), while `UserInfo.me.id`, permission `user_id`, and the grant record's `db_id` are 11 (Photos internal identity). They cannot be substituted for one another.

## Editing and disabling sharing

In `modifyingsharedalbum.har`, entry 11 calls `Browse.NormalAlbum` v1 `add_item` with `id: 69`, `item: [279335,279333]`. It returns an empty `error_list`; entry 12 reads back `shared: true` and `item_count: 4`. Sharing therefore does not require a different owner-side add operation.

Entry 23 makes one `Sharing.Passphrase` v1 `update`, combining the user's settings changes:

```json
{
  "passphrase": "<existing sharing reference>",
  "password": "",
  "expiration": 0,
  "permission": [
    {"action": "delete", "member": {"type": "public"}},
    {"action": "delete", "member": {"type": "user", "id": 1036}},
    {
      "role": "view",
      "action": "update",
      "member": {"type": "user", "id": 1035}
    }
  ]
}
```

The password form value is the serialized JSON empty string (`""`), not an omitted parameter or an unquoted empty form value. The response is `{"success":true}`. Album-list readback at entry 25 and get at entry 38 confirm `enable_password: false`, `expiration: 0`, `privacy_type: "private"`, and exactly one named-user grant: the new user 1035 with role `view`. `phototest` is absent. `shared` is still true and the link remains nonempty. This establishes removal of password, expiry, public access, and a named invitee, together with addition of a Viewer.

Entry 41 separately calls `Sharing.Passphrase` v1 `set_shared` with `policy: "album"`, `album_id: 69`, `enabled: false`. It succeeds. Readback at entry 43 confirms:

- Album 69 remains normal, owned by the same user, with four photos.
- `shared: false`, `privacy_type: "private"`, and `permission: []`.
- The top-level album `passphrase` and `sharing_info.sharing_link` are empty.
- Nested `sharing_info.passphrase` remains nonempty despite sharing being disabled.

Therefore the nested reference is not an enabled-sharing flag. Use authoritative `shared` and effective permissions. Disabling sharing clears the named grant list in this observation; re-enabling must not be assumed to restore previous grants. Actual recipient denial after revocation/disable is not captured, but settings removal and its authoritative readback are established.

## Role evidence and unofficial documentation

The owner captures directly establish named-user `download` and `view` writes, public `view`, and explicit deletion of user/public grants. Existing other album responses also contain `public-download` privacy and named-user/group `upload` roles, but these are not captured role-change requests. Mapping the current UI's Provider label to `upload` is plausible and needs a focused capture if Provider is in scope.

The unofficial album-list page corroborates stable album IDs, `owner_user_id`, `type`, `shared`, and `passphrase`. Its example is v1 and parts of its parameter prose describe shared folders, so use the observed v4 list and v1 mutations rather than copying its sorting contract. It does not document the write payloads above.

The README describes a separate link-consumer flow using `SYNO.Core.Sharing.Login`, a `sharing_sid` cookie, `x-syno-sharing`, and passphrase-scoped item reads. The public visitor capture corroborates the login, sharing header, and scoped reads, but not cookie propagation. The authenticated invitee capture separately establishes normal-session passphrase-scoped reads. Do not adopt the README's suggestion that thumbnail cache keys provide authorization; use the appropriate authenticated context.

The vendored UI strings distinguish private, public view, public download, and view/download/upload permissions. They supplement terminology but do not establish the current server's write semantics or Provider capabilities.

## Implications for this repository

- Begin with normal-album creation and membership operations, then add sharing to that same domain object. There is no evidence requiring a second membership engine for owned shared albums.
- `SynologyClient.albums()` already requests the captured v4 normal list including `sharing_info`. `AlbumSummary` currently discards sharing metadata and does not retain `owner_user_id` or `shared`, so these albums appear without their sharing state. Extend typed models when implementing this capability.
- Keep membership changes and access changes distinct at the repository boundary. Membership mutations must invalidate/reconcile affected album catalogs, pages, list counts/covers, and dependent filtered collections through the existing engine. Access-only changes need refreshed album/sharing metadata; do not invalidate unrelated Personal Library item metadata as if photos were edited.
- Retain typed sharing settings separate from the lightweight album summary where useful; preserve unknown roles conservatively and never infer write authority solely from `shared` or possession of a link.
- Authenticated recipient reads should carry a typed sharing-reference access context and effective server capabilities while reusing the repository engine and shared browser. The observed references select other-owned content through `Browse.Item.list`; Personal-only item-detail lookups and media assumptions must not silently replace this context. Contribution semantics are not captured.
- The API supports presenting owned shared albums alongside ordinary albums with an indicator or filter. It does not dictate a sidebar structure. Defer UI decisions until recipient discovery is understood.

## Focused follow-up captures

The captures now provide sufficient evidence for the initial owner workflow: create an album, change membership, invite a NAS user as Viewer/Downloader, manage observed sharing settings, copy a link, and disable sharing. Further captures need not block that slice. Settings writes should be followed by authoritative readback; ambiguous failures must not be presented as confirmed success.

Only request additional captures when their feature enters scope:

- **Incoming-album navigation in our app:** in a signed-in recipient's Photos session, navigate from the main sharing/album overview into an invitation. The current recipient capture establishes opening a known sharing reference, but contains no invitation enumeration request. This matters before deciding whether incoming albums need a separate sidebar destination.
- **Recipient downloads:** trigger an actual photo download as an invited Downloader. The current capture establishes the capability and thumbnail reads, not the download request's addressing/context.
- **Provider contribution or public downloading:** capture assignment plus the corresponding action if included in the first release. Existing readback values are insufficient to promise all write/upload behavior.

Shared-state removal can be checked as part of membership implementation if needed; the common endpoint is a reasonable bounded inference from ordinary removal plus captured shared-state addition. Guest-link browsing implementation would need to resolve sharing-session propagation. No exhaustive probing of failures, expiration timing, or re-enable behavior is required for the owner-first slice; handle uncertain outcomes conservatively.

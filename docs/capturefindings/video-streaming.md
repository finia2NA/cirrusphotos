# Video streaming and playback

## Read-only probe against the NAS (2026-10-09)

- `SYNO.API.Info`: `SYNO.Foto.Streaming` versions 1–2, `entry.cgi`, JSON request format.
- `Browse.Item` v7 `list` with `additional=["thumbnail","resolution","orientation","video_convert","video_meta"]` returns advertised conversions in `video_convert[].quality`. An empty array means no conversion is advertised, not an absent field.
- Advertised quality sets across the newest 1,000 videos: `high` 765, `orig_h264` 170, none 32, `high`+`orig_h264` 17, `medium`+`orig_h264` 16. No `low` or `mobile` appeared; decode them anyway but never assume them.
- Streaming request: GET `SYNO.Foto.Streaming` v2 `streaming` with `id=<thumbnail.unit_id>`, `type="unit"`, `quality`, `cache_key`, session token. A `Range: bytes=0-1023` request returned 206 `video/mp4` with `Content-Range`, `ETag` and `Last-Modified`, and no `Accept-Ranges`. The 206 and `Content-Range` are authoritative.
- A quality the item does not advertise returns 404. `quality="original"` returns HTTP 200 with error 120 (`quality`, `condition`).
- The stored original comes from `SYNO.Foto.Download` v2 with the same `unit_id` array and `cache_key`; ranges at offset 0 and 1 MiB both returned 206. Arbitrary seeking works for both endpoints.

Consequences: pick only advertised qualities (no automatic fallback); treat `orig_h264` as a streaming rendition distinct from the stored original; use `Download` for the original; check range support per response.

Not tested: `medium` and `orig_h264` range checks (same contract, not blocking).

## Android client playback (2026-11-02)

Metadata-only proxy capture of the official app opening two videos and seeking (no credentials, URLs or bodies; early-ended responses are logged as proxy errors without cause).

- A 19 MB High rendition: an unbounded request ended early, then a tail read (`bytes=<near end>-`, 18 KB), then `bytes=36-` returning the rest in 7.9 s.
- A 142 MB original via `Download`: unbounded request ended early, tail read of about 99 KB, `bytes=36-` advertising the full remainder but ending after 6.8 s, then a seek-like request at about 81 MB that also ended early after 34 s.
- Open-ended Range headers and large `Content-Length` values do not mean the client consumes the whole response. The client does not split into small ranges. Tail reads came first in both cases, possibly due to container layout (not established).
- Not measured: first-frame time, bytes consumed, player events.

Implication: the macOS client can deliver available cache segments to AVFoundation without assembling a 4 MiB response, and a transport change could stream larger responses incrementally while keeping bounded caching and seek cancellation. Optimal segment size is not established.

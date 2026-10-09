# Video streaming probe — 2026-10-09

Read-only authenticated probe against `cirrus`. Credentials, session IDs, tokens, item IDs, cache keys, filenames, and validator values are omitted. Requests read at most 2 KiB of media data.

## API availability

`SYNO.API.Info` reports:

```json
{
  "SYNO.Foto.Streaming": {
    "maxVersion": 2,
    "minVersion": 1,
    "path": "entry.cgi",
    "requestFormat": "JSON"
  }
}
```

## Item response

`SYNO.Foto.Browse.Item` v7 was called with:

```text
method=list
type="video"
additional=["thumbnail","resolution","orientation","video_convert","video_meta"]
```

One observed HEVC original with an advertised High conversion had this sanitized shape:

```json
{
  "additional": {
    "video_convert": [
      {
        "metadata": {
          "audio_bitrate": 93325,
          "audio_channel": 2,
          "audio_codec": "aac_lc",
          "audio_frequency": 44100,
          "container_type": "mp4",
          "duration": 5000,
          "frame_bitrate": 5544784,
          "framerate": 30.0,
          "orientation": 1,
          "resolution_x": 720,
          "resolution_y": 1280,
          "video_bitrate": 5443944,
          "video_codec": "h264",
          "video_level": -99,
          "video_profile": 0
        },
        "quality": "high"
      }
    ],
    "video_meta": {
      "audio_bitrate": 97782,
      "audio_channel": 1,
      "audio_codec": "aac_lc",
      "audio_frequency": 44100,
      "container_type": "mp4",
      "duration": 5000,
      "frame_bitrate": 6519893,
      "framerate": 30.0,
      "orientation": 8,
      "resolution_x": 1280,
      "resolution_y": 720,
      "video_bitrate": 6382537,
      "video_codec": "hevc",
      "video_level": 0,
      "video_profile": 0
    }
  },
  "type": "video"
}
```

Another observed 4096×2160 HEVC/PCM video returned an empty `video_convert` array. An empty array therefore means no converted rendition is advertised, not that the field is absent.

The first 1,000 newest video results had these exact advertised quality sets:

| Advertised `video_convert[].quality` values | Items |
| --- | ---: |
| `high` | 765 |
| `orig_h264` | 170 |
| none | 32 |
| `high`, `orig_h264` | 17 |
| `medium`, `orig_h264` | 16 |

No `low` or `mobile` conversion was advertised in this sample. The client must still decode known lower labels if a future item advertises them, but must never assume they exist.

## Streaming request and response

The working converted-video request is a GET to `/webapi/entry.cgi/SYNO.Foto.Streaming` with:

```text
api=SYNO.Foto.Streaming
version=2
method=streaming
id=<thumbnail.unit_id>
type="unit"
quality="high"
cache_key=<thumbnail.cache_key>
_sid=<redacted>
SynoToken=<redacted>
Range: bytes=0-1023
```

The response was:

```text
HTTP 206
Content-Type: video/mp4
Content-Length: 1024
Content-Range: bytes 0-1023/3835567
ETag: present
Last-Modified: present
```

The returned bytes began with an MP4 `ftyp` box. The endpoint therefore supports progressive MP4 byte ranges for this converted rendition even though it did not emit an `Accept-Ranges` header.

Requesting a quality not present in the item's `video_convert` array (`mobile`, `low`, or `medium` on this High-only item) returned HTTP 404. Requesting `quality="original"` from `SYNO.Foto.Streaming` returned HTTP 200 with:

```json
{
  "error": {
    "code": 120,
    "errors": {
      "name": "quality",
      "reason": "condition"
    }
  },
  "success": false
}
```

Consequences:

- Select only qualities advertised by the current item; the endpoint does not provide automatic fallback.
- Treat `orig_h264` as an advertised streaming rendition, distinct from the stored original.
- Retrieve the stored original through `SYNO.Foto.Download`, not by inventing an `original` streaming quality.
- Range support and validators must be checked per resource response rather than inferred from `Accept-Ranges` alone.

## Remaining bounded probes

Before completing the transport, repeat the 1 KiB range check for `medium` and `orig_h264` items and confirm nonzero-range seeking. Confirm whether `SYNO.Foto.Download` honors Range for stored videos. These checks do not block decoding the item contract or implementing advertised-quality resolution.

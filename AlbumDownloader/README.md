# Album Downloader

A small command-line tool that downloads a shared Synology Photos album, from a public link or
shared with your account, one original at a time. A slow or unreliable connection doesn't make it fail: it
waits through outages, resumes files where they broke off, and continues after you stop it.

Runs on macOS 12 or later, on Apple silicon and Intel. It doesn't depend on the Cirrus Photos app.

## Build

```sh
make          # universal binary at build/album-downloader
make test     # unit tests
make project  # regenerate AlbumDownloader.xcodeproj from project.yml (needs XcodeGen)
```

The binary is ad-hoc signed. If you send it to someone over the web, macOS quarantines it and
refuses to run it. The recipient clears that once:

```sh
xattr -d com.apple.quarantine album-downloader
```

## Use

Run `./album-downloader` and answer the prompts:

1. The album link, for example `https://nas.example.com:5001/mo/sharing/AbCd1234`.
2. Only if needed: the link's password, or, for an album shared with accounts only, a Synology
   username and password (and a two-factor code if the account has one). A public link without
   a password needs nothing else.
3. The download location (default `~/Downloads`). The tool creates a folder named after the album there.

It then checks that the album exists and that downloading is allowed (a public link must allow
downloads; an account needs the Downloader role), shows how many items there are and roughly how
big they are, and starts downloading.

If the server's certificate isn't trusted by macOS (for example a self-signed DSM certificate),
the tool shows its SHA-256 fingerprint and asks before using it. Plain `http://` links work too.

## How it handles bad connections

- **Outages:** when a download fails and the server can't be reached, the tool waits and checks
  again (every 5 s, backing off to every minute) for as long as the outage lasts. This doesn't
  count as a failed attempt.
- **Dropped transfers:** the bytes received so far are kept in `.partial/` and the next request
  asks for the rest only.
- **Failing files:** a file that fails 10 times while the server is reachable moves to the end of
  the queue, and the others continue. After three such rounds it's skipped and listed at the end.
- **Expired sessions:** the tool signs in again by itself. It asks for input only when DSM requires
  a new two-factor code or a password has changed.
- **Stopping:** press Ctrl-C at any time. Running the tool again with the same location skips
  finished files (recorded in `.album-downloader.json`) and continues the interrupted one.

The tool keeps the Mac from going to sleep while it's downloading.

## Notes

- Files keep the names the server gives them. If two items have the same name, the second
  one becomes `name (2).ext`.
- The size shown before downloading is the sum of the originals' sizes on the server.
- Tested against the NAS with an account-shared album (including dropped connections, a
  75-second outage, and stopping and resuming) and with a public link (a video resumed
  across three runs). Password-protected public links and Live Photos haven't been tested.
  For a Live Photo, Synology may send a ZIP with the still and the motion video, and the tool
  saves it as is.
- QuickConnect links are not supported.

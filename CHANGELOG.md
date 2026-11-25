# Changelog

Version sections supply the website changelog, cumulative updater notes and individual GitHub release notes.

## 0.1.11a

- Photos opened in the viewer no longer stay at their preview, and videos play again, after the library metadata was cleared or rebuilt while the app was running.

## 0.1.11

- Drag pinned albums in the sidebar to reorder them; the drop lands above or below the row you're over. With no pins, drop an album on the placeholder row to pin it.
- Photo ▸ Add to Sidebar Album (⌘1–⌘9) adds the viewer photo or the selection to one of the first nine pinned albums. Holding Command shows each pin's number, or a check when the album already holds the selection.
- Pinned albums show a spinner while photos are being added to them, then a check or a red cross.
- The filmstrip, histogram, highlight peaking and focus edges stay on or off across launches. Hiding their toolbar buttons turns them all off.
- The viewer lists all of a photo's problems together, such as an empty file on the NAS, previews the NAS couldn't create, or an original that failed to load or can't be decoded. Videos show the NAS problems too.
- Thumbnails and originals keep loading after the NAS session expires while the app sits idle. Videos, downloads, uploads and profile photos also recover from an expired session.
- Photos that failed to load while the NAS was unreachable reload once it answers again.
- WebP thumbnails load.
- When the NAS couldn't make a thumbnail at the chosen size (as with some HEVC videos), the nearest smaller size shows, or else a larger one.

Fixes #114, #127, #128, #129 and #130.

## 0.1.10

- The Group by Day toggle in the toolbar is available in albums, filtered Map results and every other photo collection, not only the main timeline.

## 0.1.9a

- Folder cards use Synology’s single-image, composite and custom covers in Personal and Shared Space. Folders without a supplied cover keep Cirrus’s derived thumbnails.
- Refresh from NAS picks up changed folder covers while cached covers remain available offline.
- Custom folder covers no longer produce unreadable-details warnings. Genuine warnings identify the affected detail.
- Failed entries in Activity and History have a Copy Details icon, also available in the right-click menu.

Fixes #120 and #121, following the original folder report in #116. Thanks to @timvdsm for reporting the problems, testing the fixes and providing detailed follow-up.

The first launch after this update automatically rebuilds cached library metadata from the NAS. Cached photo and video files are retained. A connection to the NAS is needed to reload the library metadata.

## 0.1.9

- Folder cards use Synology’s single-image, composite and custom covers in Personal and Shared Space. Folders without a supplied cover keep Cirrus’s derived thumbnails.
- Refresh from NAS picks up changed folder covers while cached covers remain available offline.
- Custom folder covers no longer produce unreadable-details warnings. Genuine warnings identify the affected detail.
- Failed entries in Activity and History have a Copy Details icon, also available in the right-click menu.

Fixes #120 and #121, following the original folder report in #116. Thanks to @timvdsm for reporting the problems, testing the fixes and providing detailed follow-up.

The first launch after this update automatically rebuilds cached library metadata from the NAS. Cached photo and video files are retained. A connection to the NAS is needed to reload the library metadata.

## 0.1.8a

- Shared Space folders are listed even when the NAS reports a folder's cover or permissions in an unexpected form; such folders are noted in History.
- A folder loading error is no longer hidden under the toolbar.

## 0.1.8

- Live Photo motion and videos play in albums shared with you.
- Videos in your own albums play again.
- Photo quality in Settings chooses what the viewer loads: Large, Large then Original, or Original.
- Thumbnail, photo and video quality are together under Settings ▸ Viewing ▸ Quality, and several viewing settings explain their options with a help button.
- When a video can't play, the viewer says why.
- The viewer says Original instead of Full.

## 0.1.7a

- Photos in Shared Space folders load for accounts that are allowed only some Shared Space folders.
- When the original of a photo isn't available, such as in a folder or shared album you may only view, the viewer shows the large preview and says it's the highest resolution you're permitted, with the reason on hover.

## 0.1.7

- Photos in Shared Space folders load for accounts that are allowed only some Shared Space folders.
- When the original of a photo isn't available, such as in a folder or shared album you may only view, the viewer shows the large preview and says it's the highest resolution you're permitted, with the reason on hover.

## 0.1.6a

- Shared Space folder view works for accounts that are allowed only some Shared Space folders.
- For such accounts, the Shared Space library offers to browse folders instead of showing an error.
- Add to Favorites or Remove from Favorites is available in the right-click menu of photos in the grid and viewer.

## 0.1.6

- Shared Space folder view works for accounts that are allowed only some Shared Space folders.
- For such accounts, the Shared Space library offers to browse folders instead of showing an error.
- Favorite or Unfavorite is available in the right-click menu of photos in the grid and viewer.

## 0.1.5

- The library window opens on first launch even while the automatic update question is shown.
- With automatic update checks on, the app checks for updates at every launch.

## 0.1.4

- Scrolling the photo grid and dragging the timeline scrubber are smoother.

## 0.1.3

- Settings shows storage as one bar against a cache maximum shared by all accounts; the least recently opened accounts are trimmed when it is exceeded.
- Thumbnail downloads pause near the cache maximum, and a larger size can be chosen.
- Clearing the cache in Settings removes only images.
- Focus rings appear only after pressing Tab.
- The thumbnail quality and cache size setup page is skipped once it has been completed.

## 0.1.2

- Dragging several photos shows a single count badge.
- A photo open in the viewer can be dragged onto an album.
- View ▸ Group by Day, also a toolbar button, shows photos in one continuous grid without day headings.
- Viewer tool buttons show on and off with filled symbols instead of a blue tint.

## 0.1.1

- Setup pages have Back buttons.
- The thumbnail setting is labeled "Thumbnail quality".
- The sign-in progress spinner sits next to the Sign In button.

## 0.1

First public alpha.

- Browse Personal Space and Shared Space as a day-grouped timeline, with a photo and video viewer.
- Browse Favorites, Recently Added, People, Subjects, Tags, folders, albums and a map.
- Filter cached photos by filename, camera, tags, rating and other criteria, also offline.
- Create and share albums; favorite, rate, tag, rotate, delete, download and upload photos.
- Thumbnails, metadata and originals are cached on disk with a size limit you set.
- Updates arrive through the built-in updater.

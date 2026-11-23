The first public release of **Doddy**, a download manager for macOS with a companion Chrome extension.

## What's inside

- **Segmented downloads** over up to 8 connections, with pause, resume and crash recovery. Dropped connections and timeouts keep what was already downloaded.
- **Refresh link**: when a download link expires, Doddy reopens the page and continues with the new link.
- **HLS streams** (including AES-128) joined into a single MP4, and pages from sites that yt-dlp supports, with a quality picker.
- **Polite to servers**: when a site answers "too many requests" (HTTP 429), Doddy pauses and slows down instead of retrying hard.
- **Chrome extension**: takes over chosen Chrome downloads, adds a Download button to media players, lists what a page plays, and grabs links in bulk.
- Queue, scheduler, speed limit, file name templates, per-site folders, conversion after download, subtitles, live speed graph, menu bar list and Dock progress.

## Install

1. Download **Doddy-0.2.0.dmg**, open it and drag **Doddy** into **Applications**.
2. Doddy is not notarised by Apple, so macOS blocks it the first time. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   `xattr -dr com.apple.quarantine /Applications/Doddy.app`
3. Download **Doddy-extension-0.2.0.zip**, unzip it, then in Chrome open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose the **Doddy extension** folder.

Requires macOS 13 or newer. On first launch Doddy downloads yt-dlp, ffmpeg and Deno into its own folder.

## Known limits

- Not signed with an Apple Developer ID, and the extension is not on the Chrome Web Store yet (so Chrome shows a developer-mode notice).
- Copy-protected (DRM) streams are refused.

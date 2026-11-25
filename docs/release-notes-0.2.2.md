Faster downloads, safer downloads, and a quieter Mac.

## What's new

- **Dynamic part splitting:** when one connection finishes early, it takes the second half of whichever piece has the most left, so slow or uneven servers no longer leave connections idle at the end. It switches itself off when a server is rate-limiting you.
- **SHA-256 checksum:** in Details, paste the published checksum and Doddy tells you whether the file matches.
- **Extension takes over more:** `.dd`, `.bin`, `.img`, `.tgz`, `.xz`, `.apk`, `.deb`, `.rpm`, `.epub` and more, plus any large download Chrome treats as a plain binary file. Older saved settings pick these up too.
- **Tidier "Grab links on this page…" button** in the extension popup.

## Fixes and safety

- **Changed file check:** resuming stops if the server's file changed (ETag, size or date) instead of stitching two versions together.
- **Disk space check:** a download that won't fit fails straight away with a clear message.
- **Idle CPU:** Doddy no longer burns CPU in the menu bar while idle; animations pause when the app isn't frontmost, and history is saved only when something changed.
- A test suite (`./tools/test.sh`, 35 checks) now covers completeness, resume checks, disk space, splitting and checksums.

## Install

Open **Doddy-0.2.2.dmg**, drag **Doddy** into **Applications**, then reload the extension (unzip **Doddy-extension-0.2.2.zip**, or press reload on `chrome://extensions`). Not notarised: if macOS blocks it, run `xattr -dr com.apple.quarantine /Applications/Doddy.app`.

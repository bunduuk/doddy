Fixes and a new Details view.

## What's new

- **Download details (like IDM):** the ⓘ button on a download, or right-click → *Details*, shows the address, referrer and page with copy buttons. Addresses are shortened unless you switch on *Full addresses*, because links can carry sign-in tokens. Setup → Files → History → *Remember addresses* controls whether finished downloads keep them.
- **Size and dates in Details:** size on disk next to the size the server announced, when it was added, when it finished and how long it took.
- **Download again** and **Copy address / referrer / Open page** in the right-click menu; search also matches addresses and pages.

## Fixes

- **Incomplete files no longer show as finished.** If a connection dropped quietly (laptop lid closed, a streaming server hanging up), the short file could be marked complete. Doddy now compares the file with the size the server announced; a short file fails with "arrived X of Y", goes to the Bin, and retry starts it again.
- **Leftover pieces:** cancelled Chrome-fetched downloads could leave gigabytes in the `parts` folder. They are no longer recreated, and leftovers are cleaned up when Doddy starts.

## Install

Same as 0.2.0: open **Doddy-0.2.1.dmg**, drag **Doddy** into **Applications**, then reload the extension (unzip **Doddy-extension-0.2.1.zip**, or press reload on `chrome://extensions`). Not notarised: if macOS blocks it, run `xattr -dr com.apple.quarantine /Applications/Doddy.app`.

# Edge Add-ons listing text (for Partner Center)

**Name:** Doddy Download Manager
**Category:** Productivity
**Short description (≤132 chars):** Send downloads, video streams and links from your browser to the Doddy download manager for Mac.

**Description:**
Doddy Download Manager sends files, video streams and links from your browser to Doddy, a fast download manager for Mac.

Requires the free Doddy app for macOS (https://github.com/bunduuk/doddy/releases/latest). The extension does nothing on its own: it hands downloads to the app.

- Takes over big downloads (and .torrent files) automatically, or on request. You choose the file types, minimum size and sites to leave alone.
- Finds video streams on the page and offers them to Doddy ("Best quality").
- "Grab links on this page" lists every link, file and picture so you can pick which to download.
- Downloads use your browser's sign-in, so files behind a login still work.
- No accounts, no tracking, no ads. Open source.

**Privacy policy URL:** https://github.com/bunduuk/doddy/blob/main/docs/PRIVACY.md
**Website / support:** https://github.com/bunduuk/doddy

## Single purpose
Send downloads, video streams and links from the browser to the Doddy download manager app on the user's Mac.

## Permission justifications
- **nativeMessaging:** the only way the extension hands a download to the Doddy app on the same computer.
- **downloads:** to notice a file the browser has started downloading and, if the user turned on takeover, cancel it and give it to Doddy.
- **webRequest:** to see the addresses of video and file requests a page makes so the right stream can be offered to Doddy.
- **declarativeNetRequest:** to set the referrer and language headers that some sites require for a download to work.
- **cookies:** to pass the sign-in cookies for the site being downloaded to Doddy, so files behind a login can be fetched.
- **tabs:** to read the address and title of the current page for the popup and the file name.
- **storage:** to save the user's settings.
- **alarms:** to keep the extension's background worker and the connection to the app alive while downloads are running.
- **Access to all websites / content scripts on all pages:** downloads and video streams can come from any site; the scripts look for streams and links on the page the user is viewing. Nothing is sent anywhere except to the Doddy app on the user's own computer.

## Testing notes for the reviewer
The extension needs the Doddy app (macOS) to complete a download. Without it the popup still opens and shows the page, but "Best quality" and takeover will report that the Doddy app was not found. Download: https://github.com/bunduuk/doddy/releases/latest

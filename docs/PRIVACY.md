# Doddy privacy policy

Doddy is a download manager for Mac. It has two parts: the Doddy app on your Mac, and the Doddy browser extension.

**We do not collect your data.** Doddy has no accounts, no analytics, no advertising and no servers of its own. Nothing the extension sees is sent to the developer or to any third party.

## What the extension handles

- **Page and download addresses, and the page you were on (referrer):** passed to the Doddy app running on your own Mac so it can fetch the file.
- **Cookies for the site you are downloading from:** passed to the Doddy app on your Mac so that downloads which need you to be signed in still work. They are used only for that download and are not sent anywhere else. The app removes cookies and private links from any report you choose to copy.
- **Network requests the page makes (for example video stream addresses):** read by the extension to find the file to download. They stay on your computer.
- **Settings:** your choices (for example which file types to take over, and sites to exclude) are stored with the browser's own storage. If you are signed in to your browser with sync turned on, the browser may sync these settings between your devices; that is done by the browser, not by Doddy.

## Where data goes

The extension talks only to the Doddy app on the same computer (through the browser's "native messaging" feature) and to the website you are downloading from, as the download itself. It does not contact any other server. The Doddy app checks GitHub for new versions (a request to `api.github.com`, which contains no personal information) and can be switched off in Setup → Updates.

## Permissions

The extension asks for access to all websites because a download can come from any site. Why each permission is needed is listed in `docs/edge-store-listing.md`.

## Open source

Doddy is open source, so you can read exactly what it does: https://github.com/bunduuk/doddy

## Contact

Questions: https://github.com/bunduuk/doddy/issues

Last updated: 25 November 2026

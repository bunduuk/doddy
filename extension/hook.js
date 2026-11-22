// Runs inside the page itself (not the extension's sandbox) so it can see what the video player downloads.
// When the player reads an HLS playlist, a copy of the text is passed on. Some servers give a playlist link
// out only once, to the page's own player; this copy is how Doddy gets it without asking the server again.
(() => {
  if (window.__doddyHook) return;
  window.__doddyHook = true;
  const isPlaylist = (u) => /\.m3u8(\?|#|$)/i.test(String(u));
  // Decryption keys named in the playlists the player reads. Keys are often single-use too, so the
  // copy the player received is passed on as well.
  const keyUrls = new Set();
  const base = (u) => { try { return new URL(String(u), location.href).href.split("?")[0]; } catch (e) { return ""; } };
  const b64 = (buf) => {
    const b = new Uint8Array(buf);
    if (!b.length || b.length > 4096) return "";
    let s = "";
    for (const x of b) s += String.fromCharCode(x);
    return btoa(s);
  };
  const passKey = (url, buf) => {
    try {
      const data = b64(buf);
      if (data) window.postMessage({ __doddy: "key", url: new URL(String(url), location.href).href, data }, "*");
    } catch (e) { /* ignore */ }
  };
  const pass = (url, text) => {
    try {
      if (typeof text !== "string" || !text.includes("#EXTM3U") || text.length > 400000) return;
      const abs = new URL(String(url), location.href).href;
      for (const m of text.matchAll(/#EXT-X-KEY:[^\n]*URI="([^"]+)"/g)) {
        try { keyUrls.add(new URL(m[1], abs).href.split("?")[0]); } catch (e) { /* ignore */ }
      }
      window.postMessage({ __doddy: "playlist", url: abs, text }, "*");
    } catch (e) { /* ignore */ }
  };

  const realFetch = window.fetch;
  window.fetch = function (...args) {
    const p = realFetch.apply(this, args);
    try {
      const a0 = args[0];
      const u = typeof a0 === "string" ? a0 : (a0 && a0.url) || String(a0);
      if (isPlaylist(u)) p.then((r) => r.clone().text().then((t) => pass(u, t)).catch(() => {})).catch(() => {});
      else if (keyUrls.has(base(u))) p.then((r) => r.clone().arrayBuffer().then((b) => passKey(u, b)).catch(() => {})).catch(() => {});
    } catch (e) { /* ignore */ }
    return p;
  };

  const realOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__doddyUrl = url;
    return realOpen.apply(this, arguments);
  };
  const realSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener("load", () => {
      try {
        if (!this.__doddyUrl) return;
        if (isPlaylist(this.__doddyUrl) && (this.responseType === "" || this.responseType === "text")) {
          pass(this.__doddyUrl, this.responseText);
        } else if (keyUrls.has(base(this.__doddyUrl)) && this.responseType === "arraybuffer") {
          passKey(this.__doddyUrl, this.response);
        }
      } catch (e) { /* ignore */ }
    });
    return realSend.apply(this, arguments);
  };
})();

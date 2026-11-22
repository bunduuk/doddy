// Doddy background service worker.
// Watches network requests for media, remembers them per tab, and hands
// download jobs to the native helper app.

const HOST = "io.github.bunduuk.doddy.host";
const MEDIA_EXT = /\.(mp4|webm|m4v|mov|mkv|m3u8|mpd|mp3|m4a|ts)(\?|#|$)/i;
const MEDIA_TYPE = /^(video\/|audio\/|application\/(vnd\.apple\.mpegurl|x-mpegurl|dash\+xml))/i;
const MIN_BYTES = 150 * 1024; // ignore tiny segments/ads

// tabId -> Map(url -> item)
const found = new Map();
const SEGMENT_URL = /([?&](bytestart|byteend|range|bytes)=|\.m4s(\?|#|$)|\/seg(ment)?[-_]?\d|[-_/]chunk|[-_/]frag)/i;
// Sites yt-dlp understands. Their small .mp4 files are streaming pieces, so keep them out of the lists.
const KNOWN_SITE = /(^|\.)(youtube\.com|youtu\.be|vimeo\.com|tiktok\.com|instagram\.com|twitter\.com|x\.com|facebook\.com|fb\.watch|reddit\.com|twitch\.tv|dailymotion\.com)$/i;
const SMALL_PIECE = 20 * 1024 * 1024;
// pageUrl -> last successful quality list
const formatsCache = new Map();
const formatsPending = new Map();
// requestId -> request headers
const reqHeaders = new Map();

function remember(tabId, item) {
  if (tabId < 0) return;
  if (!found.has(tabId)) found.set(tabId, new Map());
  const m = found.get(tabId);
  // Same file seen again (different token/query): keep only the newest.
  m.set(item.url.split("?")[0], item);
  chrome.action?.setBadgeText?.({ tabId, text: String(m.size) });
}

// Headers that make up how the browser introduces itself. Sites may tie video links to them,
// so Doddy sends the same ones. Cookies and logins are left out on purpose; those travel separately.
const IDENTITY_HEADERS = ["user-agent", "accept-language", "origin", "referer", "accept", "dnt",
  "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform"];
function identityOf(h) {
  const out = {};
  for (const k of IDENTITY_HEADERS) if (h[k]) out[k] = h[k];
  return out;
}

chrome.webRequest.onSendHeaders.addListener(
  (d) => {
    const h = {};
    for (const x of d.requestHeaders || []) {
      const n = x.name.toLowerCase();
      if (IDENTITY_HEADERS.includes(n)) h[n] = x.value;   // nothing else (cookies, logins) is kept in memory
    }
    reqHeaders.set(d.requestId, h);
    if (reqHeaders.size > 1500) {   // requests that never got an answer would pile up
      for (const k of reqHeaders.keys()) { reqHeaders.delete(k); if (reqHeaders.size <= 1000) break; }
    }
  },
  { urls: ["<all_urls>"] },
  ["requestHeaders", "extraHeaders"]
);

chrome.webRequest.onHeadersReceived.addListener(
  (d) => {
    try {
      const get = (n) =>
        (d.responseHeaders || []).find((x) => x.name.toLowerCase() === n)?.value || "";
      const type = get("content-type");
      const len = parseInt(get("content-length") || "0", 10);
      const isPlaylist = /m3u8|mpd/i.test(d.url.split("?")[0]) || /mpegurl|dash\+xml/i.test(type);
      const looksMedia = MEDIA_TYPE.test(type) || MEDIA_EXT.test(d.url);
      // skip HLS/DASH segments (.ts/.m4s) and tiny range chunks
      if (!looksMedia) return;
      if (!isPlaylist && len && len < MIN_BYTES) return;
      // MPEG-TS: usually tiny HLS segments. Keep only whole .ts files:
      // skip when this tab already has a playlist, and require a decent size.
      const isTs = /mp2t/i.test(type) || /\.ts(\?|#|$)/i.test(d.url);
      if (isTs) {
        const has = [...(found.get(d.tabId)?.values() || [])].some((x) => x.kind === "stream");
        const sz = (get("content-range") ? parseInt(get("content-range").split("/")[1] || "0", 10) : len);
        if (has || sz < 40 * 1024 * 1024) return;
      }
      // Range requests return only a slice; use the total from content-range
      const cr = get("content-range");
      const total = cr ? parseInt(cr.split("/")[1] || "0", 10) : len;
      const h = reqHeaders.get(d.requestId) || {};
      // Slices of a video (ranges, .m4s, chunk/segment names) are not videos you can play alone.
      if (!isPlaylist && SEGMENT_URL.test(d.url)) return;
      const entry = {
        url: d.url,
        type,
        size: total || len || 0,
        kind: isPlaylist ? "stream" : "file",
        referer: h["referer"] || "",
        userAgent: h["user-agent"] || "",
        acceptLanguage: h["accept-language"] || "",   // the sites can tie their video links to it
        browserHeaders: identityOf(h),
        time: Date.now(),
      };
      remember(d.tabId, entry);
      if (isPlaylist) enrichPlaylist(d.tabId, entry);
    } finally {
      reqHeaders.delete(d.requestId);
    }
  },
  { urls: ["<all_urls>"] },
  ["responseHeaders", "extraHeaders"]
);

chrome.tabs.onRemoved.addListener((id) => found.delete(id));
chrome.tabs.onUpdated.addListener((id, info) => {
  if (info.status === "loading" && info.url) {
    found.delete(id);
    chrome.action?.setBadgeText?.({ tabId: id, text: "" });
  }
});

// Items found by the browser hooks plus video addresses read from the page itself.
function itemsFor(tabId, dom, pageUrl) {
  const raw = [...(found.get(tabId)?.values() || [])];
  const hasStream = raw.some((i) => i.kind === "stream");
  const biggest = raw.reduce((m, i) => (i.kind === "file" && i.size > m ? i.size : m), 0);
  // Hide previews, ads and clip pieces: small files next to a stream or a much bigger file.
  const all = raw.filter((i) => {
    if (i.kind !== "file" || !(i.size > 0)) return true;
    if (i.size >= SMALL_PIECE) return true;
    if (hasStream) return false;
    return !(biggest >= SMALL_PIECE);
  });
  const seen = new Set(all.map((i) => i.url.split("?")[0]));
  for (const u of dom || []) {
    const key = String(u).split("?")[0];
    if (seen.has(key)) continue;
    if (!MEDIA_EXT.test(u)) continue; // unknown/blob-like links are not offered as "FILE file"
    seen.add(key);
    const isPlaylist = /\.(m3u8|mpd)(\?|#|$)/i.test(u);
    all.push({
      url: u, kind: isPlaylist ? "stream" : "file", type: "", size: 0,
      referer: pageUrl || "", userAgent: navigator.userAgent, time: Date.now(),
    });
  }
  return all;
}


// Reads an HLS playlist so the menu can show real qualities (like NDM does) instead of
// several identical "stream" lines.
function fmtDur(sec) {
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m ${String(s).padStart(2, "0")}s`;
}

// A fetch from the extension carries no Referer or Origin, and many video servers refuse that (403).
// For the length of one job, a temporary rule makes requests to those servers look like they come from
// the page that played the video, as the browser's own player did.
let ruleSeq = 0;
async function withReferer(referer, urls, fn, mode = "full", priority = 1, lang = "") {
  try {
    if (!referer || !chrome.declarativeNetRequest) return await fn();
    const origin = new URL(referer).origin;
    const hosts = [...new Set((urls || []).map((u) => { try { return new URL(u).hostname; } catch (e) { return ""; } }).filter(Boolean))];
    if (!hosts.length) return await fn();
    const id = 5000 + (++ruleSeq % 100000);
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: [id],
      addRules: [{
        id, priority,
        action: { type: "modifyHeaders", requestHeaders: (
          mode === "origin" ? [
            { header: "Referer", operation: "set", value: origin + "/" },
            { header: "Origin", operation: "set", value: origin },
          ] : mode === "noorigin" ? [
            { header: "Referer", operation: "set", value: referer },
            { header: "Origin", operation: "remove" },
          ] : mode === "none" ? [
            { header: "Referer", operation: "remove" },
            { header: "Origin", operation: "remove" },
          ] : [
            { header: "Referer", operation: "set", value: referer },
            { header: "Origin", operation: "set", value: origin },
          ] ).concat(lang ? [{ header: "Accept-Language", operation: "set", value: lang }] : []) },
        condition: { requestDomains: hosts, resourceTypes: ["xmlhttprequest"], initiatorDomains: [chrome.runtime.id] },
      }],
    });
    try { return await fn(); }
    finally { try { await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [id] }); } catch (e) { /* ignore */ } }
  } catch (e) {
    return await fn();
  }
}

async function enrichPlaylist(tabId, item) {
  try {
    if (/\.mpd(\?|#|$)/i.test(item.url)) return;
    const r = await withReferer(item.referer, [item.url], () => fetch(item.url, { credentials: "include" }), "full", 1, item.acceptLanguage || "");
    if (!r.ok) return;
    const text = await r.text();
    if (!text.includes("#EXTM3U")) return;
    if (text.length < 400000) item.text = text;
    const lines = text.split(/\r?\n/).map((l) => l.trim());
    const drm = /METHOD=SAMPLE-AES|com\.apple\.streamingkeydelivery|widevine|playready/i.test(text);
    if (text.includes("#EXT-X-STREAM-INF")) {
      item.master = true;
      item.label = "Best quality (auto)";
      item.drm = drm;
      for (let i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith("#EXT-X-STREAM-INF:")) continue;
        const bw = parseInt((/BANDWIDTH=(\d+)/.exec(lines[i]) || [])[1] || "0", 10);
        const res = /RESOLUTION=(\d+)x(\d+)/.exec(lines[i]);
        const uri = lines.slice(i + 1).find((l) => l && !l.startsWith("#"));
        if (!uri) continue;
        const h = res ? parseInt(res[2], 10) : 0;
        remember(tabId, {
          url: new URL(uri, item.url).href,
          type: item.type, size: 0, kind: "stream",
          referer: item.referer, userAgent: item.userAgent, acceptLanguage: item.acceptLanguage || "", browserHeaders: item.browserHeaders || {}, time: Date.now(),
          height: h, bandwidth: bw, drm,
          label: (h ? `${h}p` : "Stream") + (bw ? ` · ${(bw / 1e6).toFixed(1)} Mbps` : ""),
        });
      }
    } else {
      let dur = 0;
      for (const l of lines) {
        const m = /^#EXTINF:([\d.]+)/.exec(l);
        if (m) dur += parseFloat(m[1]);
      }
      if (!item.label && dur > 0) item.label = "Stream · " + fmtDur(dur);
      item.drm = drm;
    }
  } catch (e) { /* the item stays as it was */ }
}

function byQuality(a, b) {
  return (b.kind === "stream") - (a.kind === "stream") ||
    (b.master ? 1 : 0) - (a.master ? 1 : 0) ||
    (b.height || 0) - (a.height || 0) ||
    (b.bandwidth || 0) - (a.bandwidth || 0) ||
    (b.size || 0) - (a.size || 0);
}

// Some servers give a playlist link out once, to the page itself. Chrome can read it; a second
// client cannot. So the extension passes the playlist text along and the app never asks for it.
async function fetchText(url, referer) {
  try {
    const r = await withReferer(referer, [url], () => fetch(url, { credentials: "include" }));
    if (!r.ok) return "";
    const t = await r.text();
    return t.length < 400000 ? t : "";
  } catch (e) { return ""; }
}

// Copies of playlists as the page's own player read them (see hook.js). Kept in session storage,
// because the background worker may be stopped and started again between detection and download.
async function savePlaylist(url, text) {
  try { await chrome.storage.session.set({ ["pl:" + String(url).split("?")[0]]: { text, t: Date.now() } }); } catch (e) { /* ignore */ }
}
async function savedPlaylist(url) {
  try {
    const k = "pl:" + String(url).split("?")[0];
    const r = await chrome.storage.session.get(k);
    return (r[k] && r[k].text) || "";
  } catch (e) { return ""; }
}

// Which tab and frame the player lives in, per video server, so parts can be fetched from inside that page.
async function saveFrame(url, tabId, frameId) {
  try {
    if (tabId == null || tabId < 0) return;
    await chrome.storage.session.set({ ["frame:" + new URL(url).hostname]: { tabId, frameId: frameId || 0 } });
  } catch (e) { /* ignore */ }
}
async function savedFrame(url) {
  try {
    const k = "frame:" + new URL(url).hostname;
    const r = await chrome.storage.session.get(k);
    return r[k] || null;
  } catch (e) { return null; }
}

async function saveKey(url, data) {
  try { await chrome.storage.session.set({ ["key:" + String(url).split("?")[0]]: data }); } catch (e) { /* ignore */ }
}
async function savedKey(url) {
  try {
    const k = "key:" + String(url).split("?")[0];
    const r = await chrome.storage.session.get(k);
    return r[k] || "";
  } catch (e) { return ""; }
}

async function playlistPayload(tabId, url, height, referer) {
  try {
    if (/\.mpd(\?|#|$)/i.test(url)) return {};
    const known = found.get(tabId)?.get(url.split("?")[0]);
    const ref = referer || known?.referer || "";
    const text = (await savedPlaylist(url)) || known?.text || await fetchText(url, ref);
    if (!text.includes("#EXTM3U")) return {};
    const out = { playlistText: text };
    if (text.includes("#EXT-X-STREAM-INF")) {
      const lines = text.split(/\r?\n/).map((l) => l.trim());
      const vs = [];
      for (let i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith("#EXT-X-STREAM-INF:")) continue;
        const bw = parseInt((/BANDWIDTH=(\d+)/.exec(lines[i]) || [])[1] || "0", 10);
        const res = /RESOLUTION=(\d+)x(\d+)/.exec(lines[i]);
        const uri = lines.slice(i + 1).find((l) => l && !l.startsWith("#"));
        if (uri) vs.push({ uri, bw, h: res ? parseInt(res[2], 10) : 0 });
      }
      let pick = null;
      if (height) pick = vs.filter((v) => v.h > 0 && v.h <= height).sort((a, b) => b.bw - a.bw)[0] || null;
      if (!pick) pick = vs.sort((a, b) => b.bw - a.bw)[0] || null;
      if (pick) {
        const vurl = new URL(pick.uri, url).href;
        const vt = (await savedPlaylist(vurl)) || await fetchText(vurl, ref);
        if (vt.includes("#EXTM3U")) { out.variantUrl = vurl; out.variantText = vt; }
      }
    }
    // AES-128 keys are often guarded the same way: Chrome reads them and hands them over.
    const mediaText = out.variantText || (out.playlistText.includes("#EXT-X-STREAM-INF") ? "" : out.playlistText);
    const mediaBase = out.variantUrl || url;
    if (mediaText) {
      const keyData = {};
      for (const m of mediaText.matchAll(/#EXT-X-KEY:[^\n]*URI="([^"]+)"/g)) {
        try {
          const ku = new URL(m[1], mediaBase).href;
          if (keyData[ku]) continue;
          const fromPage = await savedKey(ku);   // the copy the player itself received
          if (fromPage) { keyData[ku] = fromPage; continue; }
          const r = await withReferer(ref, [ku], () => fetch(ku, { credentials: "include" }));
          if (!r.ok) continue;
          const bytes = new Uint8Array(await r.arrayBuffer());
          if (bytes.length > 4096) continue;
          let bin = "";
          for (const b of bytes) bin += String.fromCharCode(b);
          keyData[ku] = btoa(bin);
        } catch (e) { /* the app will try itself */ }
      }
      if (Object.keys(keyData).length) out.keyData = keyData;
    }
    return out;
  } catch (e) { return {}; }
}

async function buildCandidates(tabId, dom, pageUrl) {
  const all = itemsFor(tabId, dom, pageUrl);
  all.sort(byQuality);
  return Promise.all(all.slice(0, 3).map(async (c) => ({
    url: c.url, kind: c.kind, referer: c.referer, userAgent: c.userAgent, acceptLanguage: c.acceptLanguage || "", browserHeaders: c.browserHeaders || {},
    size: c.size, type: c.type, label: c.label, cookies: await cookieHeader(c.url),
    ...(c.kind === "stream" ? await playlistPayload(tabId, c.url, 0, c.referer) : {}),
  })));
}

async function cookieHeader(url) {
  try {
    const cs = await chrome.cookies.getAll({ url });
    return cs.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (e) {
    return "";
  }
}

function sendToHost(msg) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, msg, (resp) => {
      if (chrome.runtime.lastError) {
        resolve({ ok: false, error: chrome.runtime.lastError.message });
      } else {
        resolve(resp || { ok: false, error: "no response" });
      }
    });
  });
}

// The video may live in an embedded player (an iframe such as player.vimeo.com). Then the
// player's own address is what yt-dlp understands, with the outer page as the Referer.
function frameInfo(sender, msg) {
  const tabUrl = sender.tab?.url || msg.pageUrl || "";
  const frameUrl = sender.url || "";
  const isFrame = (sender.frameId || 0) > 0 && /^https?:/i.test(frameUrl) && frameUrl !== tabUrl;
  return { tabUrl, embedUrl: isFrame ? frameUrl : "" };
}


// ---- Taking over Chrome's own file downloads (off by default; see the options page) ----
const TAKEOVER_DEFAULTS = {
  takeover: false,
  takeoverMinMB: 5,
  takeoverExts: "torrent,zip,rar,7z,tar,gz,iso,dmg,pkg,exe,msi,mp4,mkv,avi,mov,wmv,flv,webm,mp3,flac,wav,m4a,pdf",
  takeoverExclude: "",
};
let lastOption = 0;   // last time the user clicked something with Option held, on any page
const ALWAYS_CHROME = [];   // sites Chrome should always keep (none: Doddy fetches signed-in files through Chrome)
const ownUrls = new Map();   // links Chrome should keep (Option-click, or when the app is not available)
function markOwn(url) {
  ownUrls.set(url, Date.now());
  setTimeout(() => ownUrls.delete(url), 60000);
}

chrome.downloads.onCreated.addListener(async (it) => {
  try {
    const cfg = await chrome.storage.sync.get(TAKEOVER_DEFAULTS);
    if (!cfg.takeover) return;
    const url = it.finalUrl || it.url || "";
    if (!/^https?:/i.test(url)) return;                 // blob:, data:, file: stay with Chrome
    if (ownUrls.has(it.url) || ownUrls.has(url) || it.byExtensionId) return;
    if (Date.now() - lastOption < 4000) return;        // Option-click: the user wants Chrome's own download
    let u;
    try { u = new URL(url); } catch (e) { return; }
    const hosts = [u.hostname, (() => { try { return new URL(it.referrer || "").hostname; } catch (e) { return ""; } })()];
    if (hosts.some((h) => h && ALWAYS_CHROME.some((d) => h === d || h.endsWith("." + d)))) return;
    const excluded = String(cfg.takeoverExclude).toLowerCase().split(/[\s,]+/).filter(Boolean);
    if (excluded.some((h) => u.hostname === h || u.hostname.endsWith("." + h))) return;
    const exts = String(cfg.takeoverExts).toLowerCase().split(/[\s,]+/).filter(Boolean);
    let nameFromUrl = "";
    try { nameFromUrl = decodeURIComponent(u.pathname.split("/").pop() || ""); } catch (e) { nameFromUrl = u.pathname.split("/").pop() || ""; }
    let known = it.filename || "";
    for (let t = 0; t < 4 && !known; t++) {          // Chrome fills in the real name a moment later
      await new Promise((r) => setTimeout(r, 150));
      const cur = await new Promise((r) => chrome.downloads.search({ id: it.id }, (a) => r((a && a[0]) || null)));
      known = (cur && cur.filename) || "";
    }
    const fileName = (known ? known.split(/[\\/]/).pop() : "") || nameFromUrl;
    const ext = fileName.includes(".") ? fileName.split(".").pop().toLowerCase() : "";
    const isTorrent = ext === "torrent" || /bittorrent/i.test(it.mime || "") || /\.torrent(\?|$)/i.test(url);
    if (!isTorrent && !exts.includes(ext)) return;
    const size = it.fileSize > 0 ? it.fileSize : (it.totalBytes > 0 ? it.totalBytes : 0);
    if (!isTorrent && size && size < cfg.takeoverMinMB * 1024 * 1024) return;

    // Chrome's own copy is stopped and removed; the app downloads it faster, in pieces.
    await new Promise((r) => chrome.downloads.cancel(it.id, () => { void chrome.runtime.lastError; r(); }));
    chrome.downloads.erase({ id: it.id });
    const r = await sendToHost({
      action: "download", url, kind: "file",
      pageUrl: it.referrer || "", referer: it.referrer || "",
      title: fileName.replace(/\.[^.]+$/, "") || "download",
      userAgent: navigator.userAgent, cookies: await cookieHeader(url),
      sizeHint: size || null, candidates: [],
    });
    if (!r || !r.ok) { markOwn(url); chrome.downloads.download({ url }); }   // the app is not there: let Chrome do it
    else {
      // The app may need Chrome to fetch the file (signed-in sites): check often for a while.
      let n = 0;
      const iv = setInterval(async () => {
        if (++n > 80) return clearInterval(iv);
        try {
          const w = await sendToHost({ action: "wanted" });
          if (w && w.ok && w.wanted && w.wanted.length) for (const rq of w.wanted) serveParts(rq);
        } catch (e) {}
      }, 1500);
    }
  } catch (e) { /* leave the download alone */ }
});

// The app asked Chrome to fetch video parts the server will only give to the browser.
let servingParts = 0;
async function serveFile(req) {
  // A whole file behind the user's login (Google Drive and similar): fetched here, with the browser's own
  // cookies, in 8 MB pieces that the app puts back together. If it fails, Chrome downloads it itself.
  const url = req.file.url;
  const put = (index, extra) => sendToHost({ action: "part", id: req.id, index, ...extra });
  const b64 = (buf) => {
    const bytes = new Uint8Array(buf);
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(bin);
  };
  const nameOf = (r) => {
    const cd = r.headers.get("content-disposition") || "";
    const m = /filename\*=(?:UTF-8'')?([^;]+)/i.exec(cd) || /filename="?([^";]+)"?/i.exec(cd);
    try { return m ? decodeURIComponent(m[1].trim()) : ""; } catch (e) { return m ? m[1] : ""; }
  };
  try {
    const CH = 8 * 1024 * 1024;
    const r0 = await fetch(url, { credentials: "include", headers: { Range: "bytes=0-0" } });
    if (!r0.ok) throw new Error("HTTP " + r0.status);
    const type = r0.headers.get("content-type") || "";
    if (/^text\/html/i.test(type)) throw new Error("the site sent a web page, not the file");
    const cr = /\/(\d+)$/.exec(r0.headers.get("content-range") || "");
    const name = nameOf(r0);
    try { r0.body && r0.body.cancel(); } catch (e) {}
    if (r0.status === 206 && cr) {
      const total = Number(cr[1]);
      const count = Math.max(1, Math.ceil(total / CH));
      await put(-1, { data: btoa(JSON.stringify({ total, chunk: CH, count, name, type })) });
      const queue = Array.from({ length: count }, (_, i) => i);
      const worker = async () => {
        while (queue.length) {
          const i = queue.shift();
          const a = i * CH, z = Math.min(total - 1, a + CH - 1);
          let ok = false, err = "";
          for (let t = 0; t < 3 && !ok; t++) {
            try {
              const r = await fetch(url, { credentials: "include", headers: { Range: `bytes=${a}-${z}` } });
              if (r.status !== 206) { err = "HTTP " + r.status; continue; }
              const resp = await put(i, { data: b64(await r.arrayBuffer()) });
              if (resp && resp.ok) ok = true; else err = (resp && resp.error) || "helper error";
            } catch (e) { err = String(e); }
          }
          if (!ok) throw new Error(err || "part failed");
        }
      };
      await Promise.all(Array.from({ length: 4 }, worker));
    } else {
      // The server ignores ranges: one piece.
      const r = await fetch(url, { credentials: "include" });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const t2 = r.headers.get("content-type") || "";
      if (/^text\/html/i.test(t2)) throw new Error("the site sent a web page, not the file");
      const buf = await r.arrayBuffer();
      await put(-1, { data: btoa(JSON.stringify({ total: buf.byteLength, chunk: Math.max(1, buf.byteLength), count: 1, name: nameOf(r) || name, type: t2 })) });
      await put(0, { data: b64(buf) });
    }
  } catch (e) {
    await put(0, { error: "Chrome could not fetch it: " + String(e && e.message || e) + ". Chrome is downloading it instead." });
    markOwn(url);
    chrome.downloads.download({ url });
  }
}

async function serveParts(req) {
  if (req.file) { servingParts++; try { await serveFile(req); } finally { servingParts--; } return; }
  servingParts++;
  try {
    const queue = [...(req.parts || [])];
    // The server that hands out these parts may only answer the page that plays the video.
    // Fetching from inside that page makes the request exactly what the player's own would be.
    const player = queue.length ? await savedFrame(queue[0].url) : null;
    const viaPage = async (url) => {
      if (!player) return null;
      try {
        const rr = await chrome.tabs.sendMessage(player.tabId, { type: "pageFetch", url }, { frameId: player.frameId });
        return rr && rr.data ? rr : { error: (rr && rr.error) || "no answer from the page" };
      } catch (e) { return { error: String(e && e.message || e) }; }
    };
    // If the server refuses the usual headers, try other styles and remember the one that works.
    let mode = "full";
    const fetchPart = async (url) => {
      const order = [mode, ...["full", "origin", "noorigin", "none"].filter((m) => m !== mode)];
      let last = null;
      for (const m of order) {
        const r = m === "full" ? await fetch(url, { credentials: "include" })
          : await withReferer(req.referer, [url], () => fetch(url, { credentials: "include" }), m, 2, req.acceptLanguage || "");
        if (r.ok) { mode = m; return r; }
        last = r;
        if (r.status !== 403 && r.status !== 401) break;
      }
      return last;
    };
    let limited = false;   // the server said "too many requests": stop asking
    const worker = async () => {
      while (queue.length && !limited) {
        const p = queue.shift();
        let sent = false, err = "";
        for (let t = 0; t < 3 && !sent && !limited; t++) {
          try {
            let data = "";
            const pg = await viaPage(p.url);
            if (pg && pg.data) data = pg.data;
            else {
              if (pg && pg.error) err = pg.error;
              const r = await fetchPart(p.url);
              if (!r.ok) {
                err = "HTTP " + r.status;
                if (r.status === 429) { limited = true; queue.length = 0; }
                continue;
              }
              const bytes = new Uint8Array(await r.arrayBuffer());
              let bin = "";
              for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
              data = btoa(bin);
            }
            const resp = await sendToHost({ action: "part", id: req.id, index: p.i, data });
            if (resp && resp.ok) sent = true; else err = (resp && resp.error) || "helper error";
          } catch (e) { err = String(e); }
        }
        if (!sent) await sendToHost({ action: "part", id: req.id, index: p.i, error: err });
      }
    };
    await withReferer(req.referer, queue.map((p) => p.url).slice(0, 50), () => Promise.all(Array.from({ length: 6 }, worker)), "full", 1, req.acceptLanguage || "");
  } finally { servingParts--; }
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const tabId = sender.tab?.id ?? msg.tabId ?? -1;

  if (msg.type === "playlistText") {
    savePlaylist(msg.url, msg.text);
    saveFrame(msg.url, sender.tab?.id, sender.frameId);
    return false;
  }
  if (msg.type === "keyData") {
    saveKey(msg.url, msg.data);
    saveFrame(msg.url, sender.tab?.id, sender.frameId);
    return false;
  }

  if (msg.type === "list") {
    const fi = frameInfo(sender, msg);
    const items = itemsFor(tabId, msg.dom, fi.embedUrl || fi.tabUrl).sort(byQuality);
    reply({ items });
    return false;
  }

  if (msg.type === "native") {
    // Option-click: hand the link to Chrome's own downloader.
    markOwn(msg.url);
    chrome.downloads.download({ url: msg.url }, () => {
      if (chrome.runtime.lastError) reply({ ok: false, error: chrome.runtime.lastError.message });
      else reply({ ok: true });
    });
    return true;
  }

  if (msg.type === "formats") {
    (async () => {
      const fi = frameInfo(sender, msg);
      const pageUrl = fi.embedUrl || fi.tabUrl;
      const outerUrl = fi.tabUrl;
      const hit = formatsCache.get(pageUrl);
      if (hit && Date.now() - hit.time < 10 * 60 * 1000) { reply(hit.reply); return; }
      // One lookup per page at a time: a prefetch and a menu click share it.
      let pending = formatsPending.get(pageUrl);
      if (!pending) {
        pending = (async () => {
          const r = await sendToHost({
            action: "formats", url: pageUrl, pageUrl, referer: outerUrl,
            userAgent: navigator.userAgent, cookies: await cookieHeader(pageUrl),
            candidates: await buildCandidates(tabId, msg.dom, pageUrl),
          });
          if (r && r.ok) formatsCache.set(pageUrl, { time: Date.now(), reply: r });
          return r;
        })().finally(() => formatsPending.delete(pageUrl));
        formatsPending.set(pageUrl, pending);
      }
      const r = await pending;
      reply(r);
    })();
    return true;
  }

  if (msg.type === "optionClick") { lastOption = Date.now(); reply({ ok: true }); return; }

  if (msg.type === "download") {
    (async () => {
      const item = msg.item || null;
      const choice = msg.choice || null;
      const fi = frameInfo(sender, msg);
      let pageUrl = fi.embedUrl || fi.tabUrl;
      // Instagram feed: use the post or reel link of the video on screen, not the feed address.
      if (!item && /^https?:\/\/([^/]*\.)?instagram\.com\//i.test(pageUrl) && !/instagram\.com\/([^/]+\/)?(reel|reels|p|tv)\/[\w-]+/i.test(pageUrl)) {
        const pl = await new Promise((r) => chrome.tabs.sendMessage(tabId, { type: "permalink" }, (res) => { void chrome.runtime.lastError; r(res && res.url); }));
        if (!pl) {
          reply({ ok: false, error: "Open the reel or post you want, press play, then try again." });
          return;
        }
        pageUrl = pl;
      }
      const target = item?.url || pageUrl;
      const job = {
        action: "download",
        url: target,
        kind: item?.kind || "page", // file | stream | page
        pageUrl,
        title: (fi.embedUrl ? sender.tab?.title : msg.title) || msg.title || sender.tab?.title || "video",
        referer: item?.referer || fi.tabUrl,
        userAgent: item?.userAgent || navigator.userAgent,
        acceptLanguage: item?.acceptLanguage || "",
        browserHeaders: item?.browserHeaders || {},
        cookies: await cookieHeader(target),
        playlist: !!msg.playlist,
        candidates: (item || msg.playlist) ? [] : await buildCandidates(tabId, msg.dom, pageUrl),
        sizeHint: item?.size || null,
        qualityLabel: choice?.label || null,
      };
      if (choice) {
        job.formatHeight = choice.height || null;
        job.audioOnly = !!choice.audio;
        const src = choice.source;
        if (src && src.url && src.url !== pageUrl) {
          job.sourceUrl = src.url;
          job.referer = src.referer || fi.tabUrl;
          job.cookies = await cookieHeader(src.url);
        }
      }
      const streamUrl = job.sourceUrl
        ? (choice?.source?.kind === "stream" ? job.sourceUrl : null)
        : (job.kind === "stream" ? job.url : null);
      if (streamUrl) Object.assign(job, await playlistPayload(tabId, streamUrl, job.formatHeight || 0));
      reply(await sendToHost(job));
    })();
    return true; // async reply
  }

  if (msg.type === "grabDownload") {
    (async () => {
      let sent = 0, failed = 0;
      for (const it of msg.items || []) {
        try {
          const isStream = /\.(m3u8)(\?|#|$)/i.test(it.url);
          const job = {
            action: "download", url: it.url, kind: isStream ? "stream" : "file",
            pageUrl: msg.pageUrl || "", title: (it.name || "").replace(/\.[^.]+$/, "") || msg.title || "download",
            referer: msg.pageUrl || "", userAgent: navigator.userAgent,
            cookies: await cookieHeader(it.url), candidates: [], quiet: true,
          };
          if (isStream) Object.assign(job, await playlistPayload(-1, it.url, 0));
          const r = await sendToHost(job);
          if (r && r.ok) sent++; else failed++;
        } catch (e) { failed++; }
      }
      reply({ ok: sent > 0 || failed === 0, sent, failed, error: failed && !sent ? "helper not installed?" : "" });
    })();
    return true;
  }

  if (msg.type === "pollWanted") {
    (async () => {
      const r = await sendToHost({ action: "wanted" });
      if (r && r.ok && r.wanted && r.wanted.length) for (const req of r.wanted) serveParts(req);
      reply({ ok: true, busy: servingParts > 0 });
    })();
    return true;
  }

  if (msg.type === "ping") {
    sendToHost({ action: "ping" }).then(reply);
    return true;
  }
  return false;
});


// The app may be resuming a download after a restart: look for video parts it wants Chrome to fetch.
try {
  chrome.alarms.create("doddy-wanted", { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener(async (a) => {
    if (a.name !== "doddy-wanted") return;
    try {
      const r = await sendToHost({ action: "wanted" });
      if (r && r.ok && r.wanted && r.wanted.length) for (const req of r.wanted) serveParts(req);
    } catch (e) { /* the app is not running */ }
  });
} catch (e) { /* alarms permission missing */ }


// ---- Refresh link: the app has a download whose link expired and waits for a new one from the page ----
const refreshTimers = new Map();
const refreshDone = new Map();
// Asking the app starts a helper process; when it has nothing waiting, do not ask again for a minute
// (a newly loaded page, which is how "Refresh link" begins, asks straight away).
let refreshIdleUntil = 0;
chrome.tabs.onUpdated.addListener((id, info) => { if (info.status === "loading") refreshIdleUntil = 0; });

function scheduleRefreshCheck(tabId) {
  if (tabId < 0) return;
  clearTimeout(refreshTimers.get(tabId));
  refreshTimers.set(tabId, setTimeout(() => tryRefresh(tabId), 2500));
}

function sameSite(a, b) {
  const h = (u) => { try { return new URL(u).hostname.replace(/^www\./, ""); } catch (e) { return ""; } };
  const x = h(a), y = h(b);
  return !!x && !!y && (x === y || x.endsWith("." + y) || y.endsWith("." + x));
}

async function tryRefresh(tabId) {
  try {
    if (Date.now() < refreshIdleUntil) return;
    const r = await sendToHost({ action: "refreshWanted" });
    const wants = (r && r.ok && r.refresh) || [];
    if (!wants.length) { refreshIdleUntil = Date.now() + 60000; return; }
    const tab = await chrome.tabs.get(tabId);
    for (const req of wants) {
      if (refreshDone.has(req.id) && Date.now() - refreshDone.get(req.id) < 60000) continue;
      if (!sameSite(req.pageUrl, tab.url || "")) continue;
      const cands = itemsFor(tabId, [], tab.url).filter((i) => i.kind === req.kind);
      let pick = null;
      if (req.kind === "file" && req.size > 0) {
        pick = cands.find((i) => i.size > 0 && Math.abs(i.size - req.size) <= req.size * 0.01) || null;
      } else {
        pick = cands.sort(byQuality)[0] || null;
      }
      if (!pick) continue;
      refreshDone.set(req.id, Date.now());
      const job = {
        action: "download", url: pick.url, kind: pick.kind, pageUrl: tab.url,
        title: tab.title || "video", referer: pick.referer || tab.url,
        userAgent: pick.userAgent || navigator.userAgent, acceptLanguage: pick.acceptLanguage || "", browserHeaders: pick.browserHeaders || {}, cookies: await cookieHeader(pick.url),
        candidates: [], sizeHint: pick.size || null, refreshId: req.id,
      };
      if (pick.kind === "stream") Object.assign(job, await playlistPayload(tabId, pick.url, 0));
      await sendToHost(job);
    }
  } catch (e) { /* the app is not running, or the tab is gone */ }
}

// Hook into the place where media is noticed.
const _remember = remember;
remember = function (tabId, item) { _remember(tabId, item); scheduleRefreshCheck(tabId); };

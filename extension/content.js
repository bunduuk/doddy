// Doddy content script: puts a small "Download" button on top of every
// sizeable <video>, inside a shadow DOM so the page's CSS can't touch it.

(() => {
  if (window.__doddy) return;
  window.__doddy = true;

  const MIN_W = 200, MIN_H = 120;


  // Video addresses written straight into the page (video src / <source>). Needed when the
  // player has not requested anything yet, or the request was invisible to the browser hooks.
  // On feed-style pages (Instagram home, stories...) the address of the page is not the address of the
  // video. The post or reel link next to the video on screen is what yt-dlp understands.
  const POST = /^\/(?:[^/]+\/)?(reel|reels|p|tv)\/[\w-]+/;
  function permalink() {
    try {
      if (!/(^|\.)instagram\.com$/.test(location.hostname)) return "";
      if (POST.test(location.pathname)) return location.href;
      let best = null, bestArea = 0;
      document.querySelectorAll("video").forEach((v) => {
        const r = v.getBoundingClientRect();
        const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
        const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
        if (w * h > bestArea) { bestArea = w * h; best = v; }
      });
      if (!best) return "";
      const box = best.closest("article") || best.parentElement;
      const a = box && box.querySelector('a[href*="/reel/"], a[href*="/p/"], a[href*="/tv/"]');
      return a ? new URL(a.getAttribute("href"), location.href).href : "";
    } catch (e) { return ""; }
  }
  try {
    chrome.runtime.onMessage.addListener((m, s, reply) => {
      if (m && m.type === "permalink") { reply({ url: permalink() }); }
    });
  } catch (e) {}

  // Option-click anywhere: tell the extension, so Chrome's own downloader keeps that download.
  addEventListener("mousedown", (e) => { if (e.altKey) safeSend({ type: "optionClick" }); }, true);
  addEventListener("click", (e) => { if (e.altKey) safeSend({ type: "optionClick" }); }, true);

  // After the extension is reloaded, old pages lose their connection. Fail quietly instead of throwing.
  function safeSend(msg, cb) {
    try {
      // The extension was updated or reloaded while this page was open: this copy can no longer reach it.
      if (!chrome.runtime || !chrome.runtime.id) {
        if (cb) cb({ ok: false, error: "Doddy was updated: reload this page" });
        return;
      }
      chrome.runtime.sendMessage(msg, (r) => {
        if (chrome.runtime.lastError) { if (cb) cb(undefined); return; }
        if (cb) cb(r);
      });
    } catch (e) { /* extension was reloaded: refresh the page */ }
  }

  function domMedia() {
    const out = new Set();
    const add = (u) => {
      if (!u) return;
      try {
        const a = new URL(u, location.href);
        if (a.protocol === "http:" || a.protocol === "https:") out.add(a.href);
      } catch (e) {}
    };
    document.querySelectorAll("video").forEach((v) => {
      add(v.currentSrc); add(v.getAttribute("src")); add(v.getAttribute("data-src"));
      v.querySelectorAll("source").forEach((x) => { add(x.getAttribute("src")); add(x.getAttribute("data-src")); });
    });
    return [...out].slice(0, 6);
  }
  const tracked = new Map(); // video -> {host, btn}

  const css = `
    :host { all: initial; }
    .wrap { position: fixed; z-index: 2147483647; pointer-events: none; }
    .row { display: flex; gap: 6px; pointer-events: none; align-items: center; }
    button.dl {
      pointer-events: auto; cursor: pointer; display: flex; align-items: center; gap: 7px;
      font: 600 13px -apple-system, system-ui, sans-serif; letter-spacing: .1px; color: #fff;
      background: linear-gradient(135deg, #f5894c, #db5c8f 55%, #a843bd); border: 1px solid rgba(255,255,255,.28);
      border-radius: 999px; padding: 7px 14px 7px 11px; box-shadow: 0 4px 14px rgba(0,0,0,.35);
      opacity: 0; transform: translateY(-3px); transition: opacity .16s, transform .16s, filter .12s;
    }
    button.dl svg { width: 15px; height: 15px; flex: none; }
    button.more {
      padding: 7px 10px; background: rgba(18,21,46,.86); border: 1px solid rgba(255,255,255,.2);
      -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px);
    }
    .wrap.show button.dl, button.dl:focus { opacity: 1; transform: none; }
    button.dl:hover { filter: brightness(1.12); }
    .menu {
      pointer-events: auto; margin-top: 8px; min-width: 250px; max-width: 340px;
      background: rgba(18,21,46,.97); color: #ececf0; border-radius: 14px; padding: 6px;
      border: 1px solid rgba(255,255,255,.1);
      -webkit-backdrop-filter: blur(16px); backdrop-filter: blur(16px);
      font: 13px -apple-system, system-ui, sans-serif; box-shadow: 0 12px 34px rgba(0,0,0,.55);
      max-height: 60vh; overflow-y: auto;
    }
    .menu .sec { padding: 0; cursor: default; }
    .menu .sec > div {
      display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-radius: 9px;
      cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .menu .sec > div:hover { background: rgba(219,92,143,.22); }
    .menu .sec > div.hint, .menu .sec > div.head, .menu .sec > div.busy { cursor: default; color: #9a9aa6; }
    .menu .sec > div.hint:hover, .menu .sec > div.head:hover, .menu .sec > div.busy:hover { background: none; }
    .menu .sec > div.head {
      font-size: 11px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase;
      padding: 10px 10px 4px; border-top: 1px solid rgba(255,255,255,.08); margin-top: 4px; border-radius: 0;
    }
    .menu small {
      margin-left: auto; font-size: 11px; padding: 1px 8px; border-radius: 999px;
      background: rgba(255,255,255,.09); color: #b9b9c4;
    }
    .busy::before {
      content: ""; width: 11px; height: 11px; border-radius: 50%; flex: none;
      border: 2px solid rgba(255,255,255,.2); border-top-color: #f5894c; animation: spin .8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .toast {
      pointer-events: none; margin-top: 8px; background: rgba(18,21,46,.95); color: #fff; padding: 9px 13px;
      border-radius: 11px; border: 1px solid rgba(255,255,255,.12); box-shadow: 0 8px 24px rgba(0,0,0,.45);
      font: 13px -apple-system, system-ui, sans-serif; max-width: 320px; line-height: 1.35;
    }
  `;


  function fmtSize(n) {
    if (!n) return "";
    const u = ["B", "KB", "MB", "GB"]; let i = 0;
    while (n >= 1024 && i < 3) { n /= 1024; i++; }
    return n.toFixed(i ? 1 : 0) + " " + u[i];
  }
  // Text from websites (content types, playlist labels, error messages) is shown as text, never as HTML.
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  function label(it) {
    if (it.kind === "stream") {
      const t = /\.mpd(\?|#|$)/i.test(it.url) ? "DASH" : "HLS";
      if (it.label) return `${esc(it.label)}<small>${it.drm ? "protected" : t}</small>`;
      return `Video stream (${t})<small>best quality</small>`;
    }
    const t = (it.type || "").split(";")[0].replace(/^(video|audio)\//, "").toUpperCase() || "FILE";
    return `${esc(t)} file<small>${esc(fmtSize(it.size))}</small>`;
  }

  function make(video) {
    const host = document.createElement("div");
    host.style.cssText = "all:initial;position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;";
    const root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = css;
    const wrap = document.createElement("div");
    wrap.className = "wrap";
    const btn = document.createElement("button");
    btn.className = "dl";
    btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11"/><path d="M7 11l5 5 5-5"/><path d="M5 20h14"/></svg><span>Download video</span>';
    btn.title = "Download with Doddy (Option-click: use Chrome\u2019s own downloader)";
    const more = document.createElement("button");
    more.className = "dl more";
    more.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
    more.title = "Choose what to download (Option-click: use Chrome\u2019s downloader)";
    const row = document.createElement("div");
    row.className = "row";
    row.append(btn, more);
    const extra = document.createElement("div");
    wrap.append(row, extra);
    root.append(style, wrap);
    document.documentElement.appendChild(host);

    const toast = (t, ms = 3500) => {
      extra.innerHTML = "";
      const d = document.createElement("div");
      d.className = "toast"; d.textContent = t;
      extra.appendChild(d);
      setTimeout(() => { if (extra.contains(d)) extra.innerHTML = ""; }, ms);
    };

    // Option-click: let Chrome's own downloader take a plain file (not streams or page-only sites).
    const nativeDownload = (item) => {
      const go = (it) => safeSend({ type: "native", url: it.url }, (r) => {
        if (chrome.runtime.lastError) return toast("Extension error: " + chrome.runtime.lastError.message, 6000);
        if (r && r.ok) toast("Sent to Chrome's downloader", 3500);
        else toast("Chrome could not download it: " + ((r && r.error) || "unknown error"), 6000);
      });
      if (item) {
        if (item.kind === "file") go(item);
        else toast("This is a stream. Chrome can only download plain files; click normally to use Doddy.", 6000);
        return;
      }
      safeSend({ type: "list", dom: domMedia() }, (lr) => {
        const files = ((lr && lr.items) || []).filter((i) => i.kind === "file").sort((a, b) => (b.size || 0) - (a.size || 0));
        if (files.length) go(files[0]);
        else toast("No plain file found on this page for Chrome to download. Click normally to use Doddy.", 6000);
      });
    };

    // Optional (extension options): when nothing has been detected yet, look for the video address for a
    // moment so the player requests it, then put it back as it was.
    const wake = (done) => {
      try {
        chrome.storage.sync.get({ autoPlay: false }, (cfg) => {
          if (chrome.runtime.lastError || !cfg || !cfg.autoPlay) return done();
          safeSend({ type: "list", dom: domMedia() }, (lr) => {
            if (lr && lr.items && lr.items.length) return done();
            const wasMuted = video.muted, wasPaused = video.paused, t = video.currentTime;
            toast("Muted for a moment while Doddy finds the video.", 8000);
            video.muted = true;
            try { const pr = video.play(); if (pr && pr.catch) pr.catch(() => {}); } catch (e) {}
            let tries = 0;
            const restore = () => {
              if (wasPaused) { try { video.pause(); } catch (e) {} }
              video.muted = wasMuted;
              try { if (wasPaused) video.currentTime = t; } catch (e) {}
              done();
            };
            const iv = setInterval(() => {
              tries++;
              safeSend({ type: "list", dom: domMedia() }, (r2) => {
                if ((r2 && r2.items && r2.items.length) || tries >= 12) { clearInterval(iv); restore(); }
              });
            }, 400);
          });
        });
      } catch (e) { done(); }
    };

    const start = (item, choice, alt) => {
      if (alt) { extra.innerHTML = ""; return nativeDownload(item); }
      if (item) return send(item, choice);
      wake(() => send(item, choice));
    };

    const send = (item, choice) => {
      extra.innerHTML = "";
      toast("Sending to Doddy…");
      safeSend(
        { type: "download", item, choice, title: document.title, pageUrl: permalink() || location.href, dom: domMedia() },
        (r) => {
          if (chrome.runtime.lastError) return toast("Extension error: " + chrome.runtime.lastError.message, 6000);
          if (r && r.ok) {
            toast("Downloading → " + (r.message || "~/Downloads/Doddy"), 5000);
            // Some servers only answer the browser: stay available to fetch parts for the app.
            let n = 0;
            const iv = setInterval(() => {
              if (++n > 150) return clearInterval(iv);
              try { safeSend({ type: "pollWanted" }, () => { void chrome.runtime.lastError; }); }
              catch (e) { clearInterval(iv); }
            }, 2000);
          }
          else toast("Failed: " + ((r && r.error) || "helper not installed?"), 7000);
        }
      );
    };

    // Main button: automatic (yt-dlp first, then any detected stream/file).
    btn.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation();
      try { start(null, null, e.altKey); } catch (err) { toast("Extension was reloaded: refresh this page (⌘R) and try again.", 6000); }
    });

    // Chevron: the menu opens instantly with what the browser already saw;
    // yt-dlp's quality list is added at the top when it arrives.
    more.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation();
      if (extra.querySelector(".menu")) { extra.innerHTML = ""; return; }
      extra.innerHTML = "";
      const menu = document.createElement("div");
      menu.className = "menu";
      const top = document.createElement("div");
      const bottom = document.createElement("div");
      top.className = "sec"; bottom.className = "sec";
      menu.append(top, bottom);
      const add = (box, html, fn, dim) => {
        const el = document.createElement("div");
        el.innerHTML = html;
        if (dim) el.className = dim === "head" ? "head" : dim === "busy" ? "busy" : "hint";
        if (fn) el.addEventListener("click", (ev) => { ev.stopPropagation(); try { fn(ev.altKey); } catch (e) { toast("Extension was reloaded: refresh this page (⌘R) and try again.", 6000); } });
        box.appendChild(el);
      };
      add(top, "Best available<small>automatic</small>", (alt) => start(null, null, alt));
      add(top, "Finding more qualities…", null, "busy");
      extra.appendChild(menu);

      // Detected files: instant.
      safeSend({ type: "list", dom: domMedia() }, (lr) => {
        const items = ((lr && lr.items) || []).slice(0, 12);
        if (!items.length) return;
        add(bottom, "Detected on this page", null, "head");
        for (const it of items) add(bottom, label(it), (alt) => start(it, null, alt));
      });

      // Quality list: arrives later.
      safeSend({ type: "formats", dom: domMedia() }, (r) => {
        top.innerHTML = "";
        add(top, "Best available<small>automatic</small>", (alt) => start(null, null, alt));
        if (chrome.runtime.lastError) {
          add(top, "Extension error: " + esc(chrome.runtime.lastError.message), null, true);
        } else if (r && r.ok && r.formats && r.formats.length) {
          for (const f of r.formats) {
            add(top, esc(f.label), (alt) => start(null, { height: f.height, label: f.label, source: r.source }, alt));
          }
          add(top, "Audio only<small>MP3</small>", (alt) => start(null, { audio: true, source: r.source }, alt));
        } else if (r && r.skipped) {
          // the qualities are in the "Detected on this page" list below
        } else {
          add(top, "No quality list: " + esc((r && r.error) || "no reply from helper"), null, true);
        }
      });
    });

    tracked.set(video, { host, wrap });
  }

  let prefetched = "";
  const pointer = { x: -1, y: -1 };
  let lastMove = 0;
  addEventListener("mousemove", (e) => { pointer.x = e.clientX; pointer.y = e.clientY; lastMove = Date.now(); }, true);
  function mainVideo() {
    let best = null, bestArea = 0;
    document.querySelectorAll("video").forEach((v) => {
      const r = v.getBoundingClientRect();
      const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
      const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
      if (w * h > bestArea) { bestArea = w * h; best = v; }
    });
    return best;
  }
  function position(video, o) {
    const r = video.getBoundingClientRect();
    const vis = r.width >= MIN_W && r.height >= MIN_H && r.bottom > 0 && r.right > 0 &&
      r.top < innerHeight && r.left < innerWidth && getComputedStyle(video).visibility !== "hidden";
    // Instagram home and other feeds: no button. It appears once a reel or post is opened on its own.
    const onIG = /(^|\.)instagram\.com$/.test(location.hostname);
    const feedPage = onIG && !POST.test(location.pathname);
    // Instagram keeps other videos alive behind an opened reel: only the one you are watching gets the button.
    const notMain = onIG && video !== mainVideo();
    const show = vis && !feedPage && !notMain;
    o.host.style.display = show ? "block" : "none";
    if (!show) return;
    o.wrap.style.left = Math.max(0, r.left + 8) + "px";
    o.wrap.style.top = Math.max(0, r.top + 8) + "px";
    // Only while the pointer is over the video (or the button/menu); lingers briefly after leaving.
    const inside = pointer.x >= r.left && pointer.x <= r.right && pointer.y >= r.top && pointer.y <= r.bottom;
    // Over the video AND the mouse moved recently: a still pointer (full screen) lets it fade away.
    const moving = Date.now() - lastMove < 2000;
    if ((inside && moving) || o.wrap.matches(":hover") || o.wrap.querySelector(".menu")) o.last = Date.now();
    const shown = Date.now() - (o.last || 0) < 700;
    o.wrap.classList.toggle("show", shown);
    // Start the quality lookup as soon as the button first appears, so the list is ready by the click.
    if (shown && prefetched !== location.href) {
      prefetched = location.href;
      try { safeSend({ type: "formats", dom: domMedia() }, () => void chrome.runtime.lastError); } catch (e) {}
    }
  }

  function scan() {
    document.querySelectorAll("video").forEach((v) => { if (!tracked.has(v)) make(v); });
    for (const [v, o] of tracked) {
      if (!v.isConnected) { o.host.remove(); tracked.delete(v); continue; }
      position(v, o);
    }
  }

  // Busy pages change their DOM and scroll constantly: look at most every 60 ms, and not at all in a hidden tab.
  let scanTimer = 0, lastScan = 0;
  function scanSoon() {
    if (scanTimer || document.hidden) return;
    scanTimer = setTimeout(() => { scanTimer = 0; lastScan = Date.now(); scan(); }, Math.max(0, 60 - (Date.now() - lastScan)));
  }
  new MutationObserver(scanSoon).observe(document.documentElement, { childList: true, subtree: true });
  addEventListener("scroll", scanSoon, true);
  addEventListener("resize", scanSoon);
  document.addEventListener("fullscreenchange", scanSoon);
  setInterval(() => { if (!document.hidden) scan(); }, 400); // keeps the button glued to the player while it moves
  scan();
})();

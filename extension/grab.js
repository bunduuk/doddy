// Doddy link grabber: lists the links, files, media and pictures on this page when the grabber asks.
(() => {
  if (window.__doddyGrab) return;
  window.__doddyGrab = true;
  const TYPES = {
    video: "mp4 webm m4v mov mkv avi flv wmv m3u8 mpd ts mpg mpeg 3gp",
    audio: "mp3 m4a aac wav flac ogg opus wma",
    image: "jpg jpeg png gif webp svg bmp avif tif tiff heic",
    archive: "zip rar 7z tar gz tgz bz2 xz iso dmg pkg exe msi apk",
    document: "pdf doc docx xls xlsx ppt pptx txt epub mobi csv rtf",
  };
  const byExt = {};
  for (const [t, list] of Object.entries(TYPES)) for (const e of list.split(" ")) byExt[e] = t;

  function classify(name, hint) {
    const ext = (name.split("?")[0].split(".").pop() || "").toLowerCase();
    return byExt[ext] || hint || "other";
  }

  function grab() {
    const out = new Map();
    const add = (raw, text, hint) => {
      try {
        const a = new URL(raw, location.href);
        if (!/^https?:$/.test(a.protocol)) return;
        const url = a.href;
        if (out.has(url)) return;
        let name = "";
        try { name = decodeURIComponent(a.pathname.split("/").pop() || ""); } catch (e) { name = a.pathname.split("/").pop() || ""; }
        const type = classify(name, hint && !byExt[(name.split(".").pop() || "").toLowerCase()] ? hint : "");
        out.set(url, { url, name: name || a.host, text: (text || "").trim().replace(/\s+/g, " ").slice(0, 120), type });
      } catch (e) { /* skip */ }
    };
    document.querySelectorAll("a[href]").forEach((a) => add(a.href, a.textContent, ""));
    document.querySelectorAll("video[src],audio[src],source[src]").forEach((e) => add(e.src, "", e.closest("audio") || e.tagName === "AUDIO" ? "audio" : "video"));
    document.querySelectorAll("img[src]").forEach((i) => add(i.currentSrc || i.src, i.alt, "image"));
    return [...out.values()];
  }

  chrome.runtime.onMessage.addListener((msg, sender, reply) => {
    if (msg && msg.type === "grab") {
      reply({ ok: true, links: grab(), title: document.title, url: location.href });
    }
    return false;
  });
})();

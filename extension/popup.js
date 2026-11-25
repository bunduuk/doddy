const list = document.getElementById("list");
const msg = document.getElementById("msg");
const pageEl = document.getElementById("page");

function size(n) {
  if (!n) return "";
  const u = ["B", "KB", "MB", "GB"]; let i = 0;
  while (n >= 1024 && i < 3) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
}
function name(it) {
  if (it.kind === "stream") {
    if (it.label) return it.label + (it.drm ? "  (protected)" : "");
    return /mpd/i.test(it.url.split("?")[0]) ? "Video stream (DASH)" : "Video stream (HLS)";
  }
  const t = (it.type || "").split(";")[0].split("/").pop().toUpperCase();
  return (t && t !== "OCTET-STREAM" ? t : "Video") + " file";
}
function host(u) { try { return new URL(u).host; } catch (e) { return u; } }
function say(t) { msg.textContent = t; setTimeout(() => { msg.textContent = ""; }, 3500); }

chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
  if (!tab) return;
  pageEl.textContent = tab.title || tab.url;
  const webPage = /^https?:/i.test(tab.url || "");
  const videoSite = /^https?:\/\/([^/]*\.)?(youtube\.com|youtu\.be)\//i.test(tab.url || "");
  const hideDownloadPart = () => {
    document.querySelector(".page").style.display = "none";
    document.getElementById("extras").style.display = "none";
    list.style.display = "none";
  };
  if (!webPage) hideDownloadPart();
  const base = { tabId: tab.id, pageUrl: tab.url, title: tab.title };

  document.getElementById("grab").onclick = () => {
    chrome.tabs.create({ url: chrome.runtime.getURL("grabber.html?tab=" + tab.id) });
    window.close();
  };

  document.getElementById("best").onclick = () => {
    chrome.runtime.sendMessage({ type: "download", item: null, choice: null, ...base }, (r) => {
      say(r && r.ok ? "Sent to Doddy" : "Failed: " + ((r && r.error) || "helper not installed?"));
    });
  };

  const extras = document.getElementById("extras");
  const sendMsg = (extra, okText) => chrome.runtime.sendMessage({ type: "download", item: null, choice: null, ...base, ...extra }, (r) => {
    say(r && r.ok ? okText : "Failed: " + ((r && r.error) || "helper not installed?"));
  });
  if (/^https?:\/\/([^/]*\.)?(youtube\.com|youtu\.be)\/.*([?&]list=|\/playlist)/i.test(tab.url || "")) {
    const pl = document.createElement("button");
    pl.className = "alt";
    pl.textContent = "Whole playlist";
    pl.title = "Download every video in this playlist into its own folder";
    pl.onclick = () => sendMsg({ playlist: true }, "Playlist sent to Doddy");
    extras.appendChild(pl);
  }

  chrome.runtime.sendMessage({ type: "list", ...base }, (lr) => {
    const items = (lr && lr.items) || [];
    const videos = items.filter((i) => !i.height && !(i.kind === "file" && i.size > 0 && i.size < 1024 * 1024));
    if (videos.length > 1) {
      const all = document.createElement("button");
      all.className = "alt";
      all.textContent = "Download all " + videos.length;
      all.onclick = () => {
        for (const v of videos) chrome.runtime.sendMessage({ type: "download", item: v, choice: null, ...base });
        say("Sent " + videos.length + " to Doddy");
      };
      extras.appendChild(all);
    }
    if (!items.length) {
      if (!videoSite) { hideDownloadPart(); return; }
      list.innerHTML = '<div class="empty">Nothing detected on this page yet.<br>Press play on the video, then open this again.</div>';
      return;
    }
    for (const it of items) {
      const row = document.createElement("div");
      row.className = "row";
      const t = document.createElement("div");
      t.className = "t";
      const b = document.createElement("b");
      b.textContent = name(it) + (it.size ? "  ·  " + size(it.size) : "");
      const s = document.createElement("small");
      s.textContent = host(it.url);
      s.title = it.url;
      t.append(b, s);
      const dl = document.createElement("button");
      dl.textContent = "Download";
      dl.onclick = () => chrome.runtime.sendMessage({ type: "download", item: it, choice: null, ...base }, (r) => {
        say(r && r.ok ? "Sent to Doddy" : "Failed: " + ((r && r.error) || "helper not installed?"));
      });
      row.append(t, dl);
      if (it.kind === "file") {
        const ch = document.createElement("button");
        ch.className = "alt";
        ch.textContent = "Chrome";
        ch.title = "Use Chrome's own downloader";
        ch.onclick = () => chrome.runtime.sendMessage({ type: "native", url: it.url }, (r) => {
          say(r && r.ok ? "Sent to Chrome's downloader" : "Failed: " + ((r && r.error) || "unknown"));
        });
        row.append(ch);
      }
      list.appendChild(row);
    }
  });
});

(() => {
  const D = { autoPlay: false, takeover: false, takeoverMinMB: 5,
    takeoverExts: "torrent,zip,rar,7z,tar,gz,tgz,xz,bz2,zst,iso,img,bin,dd,dmg,pkg,exe,msi,apk,deb,rpm,appimage,jar,mp4,mkv,avi,mov,wmv,flv,webm,mpg,mpeg,ts,mp3,flac,wav,m4a,aac,ogg,opus,pdf,epub",
    takeoverExclude: "" };
  const $ = (id) => document.getElementById(id);
  chrome.storage.sync.get(D, (c) => {
    $("autoPlay").checked = !!c.autoPlay;
    $("takeover").checked = !!c.takeover;
    $("takeoverMinMB").value = c.takeoverMinMB;
    $("takeoverExts").value = c.takeoverExts;
    $("takeoverExclude").value = c.takeoverExclude;
    $("more").classList.toggle("on", !!c.takeover);
  });
  const save = () => {
    $("more").classList.toggle("on", $("takeover").checked);
    chrome.storage.sync.set({
      autoPlay: $("autoPlay").checked, takeover: $("takeover").checked,
      takeoverMinMB: Math.max(0, Number($("takeoverMinMB").value) || 0),
      takeoverExts: $("takeoverExts").value, takeoverExclude: $("takeoverExclude").value,
    });
  };
  ["autoPlay", "takeover", "takeoverMinMB", "takeoverExts", "takeoverExclude"].forEach((id) => $(id).addEventListener("input", save));
})();

const tabId = parseInt(new URLSearchParams(location.search).get("tab") || "0", 10);
const NAMES = { video: "Videos", audio: "Audio", image: "Images", archive: "Archives", document: "Documents", other: "Other links" };
const state = { links: [], on: new Set(["video", "audio", "image", "archive", "document"]), q: "", picked: new Set(), pageUrl: "", title: "" };
const $ = (id) => document.getElementById(id);

function host(u) { try { return new URL(u).host; } catch (e) { return ""; } }

function visible() {
  const q = state.q.toLowerCase();
  return state.links.filter((l) => state.on.has(l.type) && (!q || (l.name + " " + l.text + " " + l.url).toLowerCase().includes(q)));
}

function render() {
  const counts = {};
  for (const l of state.links) counts[l.type] = (counts[l.type] || 0) + 1;
  $("chips").innerHTML = "";
  for (const t of Object.keys(NAMES)) {
    if (!counts[t]) continue;
    const c = document.createElement("span");
    c.className = "chip" + (state.on.has(t) ? " on" : "");
    c.textContent = `${NAMES[t]} (${counts[t]})`;
    c.onclick = () => { state.on.has(t) ? state.on.delete(t) : state.on.add(t); render(); };
    $("chips").appendChild(c);
  }
  const vis = visible();
  $("list").innerHTML = "";
  $("empty").hidden = vis.length > 0;
  for (const l of vis) {
    const row = document.createElement("label");
    row.className = "row";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = state.picked.has(l.url);
    cb.onchange = () => { cb.checked ? state.picked.add(l.url) : state.picked.delete(l.url); update(); };
    const t = document.createElement("div");
    t.className = "t";
    const b = document.createElement("b"); b.textContent = l.name || l.url;
    const s = document.createElement("small"); s.textContent = (l.text ? l.text + " · " : "") + host(l.url);
    t.append(b, s);
    const tag = document.createElement("span"); tag.className = "tag"; tag.textContent = l.type;
    row.append(cb, t, tag);
    $("list").appendChild(row);
  }
  update();
}

function update() {
  const n = state.picked.size;
  $("go").disabled = n === 0;
  $("go").textContent = n ? `Download ${n} selected` : "Download selected";
}

$("q").oninput = (e) => { state.q = e.target.value; render(); };
$("all").onclick = () => { visible().forEach((l) => state.picked.add(l.url)); render(); };
$("none").onclick = () => { state.picked.clear(); render(); };
$("go").onclick = () => {
  const items = state.links.filter((l) => state.picked.has(l.url)).map((l) => ({ url: l.url, name: l.name, type: l.type }));
  $("go").disabled = true;
  $("msg").textContent = "Sending…";
  chrome.runtime.sendMessage({ type: "grabDownload", items, pageUrl: state.pageUrl, title: state.title }, (r) => {
    $("msg").textContent = r && r.ok ? `Sent ${r.sent} to Doddy` + (r.failed ? `, ${r.failed} failed` : "") : "Failed: " + ((r && r.error) || "helper not installed?");
    state.picked.clear();
    render();
  });
};

chrome.tabs.sendMessage(tabId, { type: "grab" }, { frameId: 0 }, (r) => {
  if (chrome.runtime.lastError || !r || !r.ok) {
    $("page").textContent = "Could not read that page. Reload it and try again.";
    return;
  }
  state.links = r.links;
  state.pageUrl = r.url;
  state.title = r.title;
  $("page").textContent = r.title || r.url;
  render();
});

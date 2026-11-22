// Fetches a file from inside this page when the extension asks, exactly as the page's own player would
// (same origin, same referrer, same cookies). Used for servers that refuse everything except the player.
chrome.runtime.onMessage.addListener((m, s, reply) => {
  if (!m || m.type !== "pageFetch") return false;
  fetch(m.url, { credentials: "include" }).then(async (r) => {
    if (!r.ok) { reply({ error: "HTTP " + r.status }); return; }
    const bytes = new Uint8Array(await r.arrayBuffer());
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    reply({ data: btoa(bin) });
  }).catch((e) => reply({ error: String(e && e.message || e) }));
  return true;
});

// Starts before the page does, so no playlist the player reads is missed. Passes what hook.js saw to the extension.
window.addEventListener("message", (e) => {
  const d = e.data;
  if (e.source !== window || !d) return;
  let msg = null;
  if (d.__doddy === "playlist") msg = { type: "playlistText", url: d.url, text: d.text };
  else if (d.__doddy === "key") msg = { type: "keyData", url: d.url, data: d.data };
  if (!msg) return;
  try { chrome.runtime.sendMessage(msg, () => void chrome.runtime.lastError); } catch (err) { /* extension reloaded */ }
});

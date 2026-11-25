const saved = document.getElementById("saved");
function flash() {
  saved.textContent = "Saved";
  setTimeout(() => { saved.textContent = ""; }, 1500);
}
const defaults = {
  autoPlay: false, takeover: false, takeoverMinMB: 5,
  takeoverExts: "torrent,zip,rar,7z,tar,gz,tgz,xz,bz2,zst,iso,img,bin,dd,dmg,pkg,exe,msi,apk,deb,rpm,appimage,jar,mp4,mkv,avi,mov,wmv,flv,webm,mpg,mpeg,ts,mp3,flac,wav,m4a,aac,ogg,opus,pdf,epub",
  takeoverExclude: "",
};
chrome.storage.sync.get(defaults, (c) => {
  for (const k of Object.keys(defaults)) {
    const el = document.getElementById(k);
    if (!el) continue;
    if (el.type === "checkbox") el.checked = !!c[k]; else el.value = c[k];
    el.addEventListener("change", () => {
      const v = el.type === "checkbox" ? el.checked : (el.type === "number" ? Number(el.value) || 0 : el.value);
      chrome.storage.sync.set({ [k]: v }, flash);
    });
  }
});

// content.js - Dispatch Extension

const _api = typeof browser !== "undefined" ? browser : chrome;

let bypassKey = "Alt"; 
let isExtensionDisabled = false;
let isKeyCurrentlyHeld = false;
let bypassMemoryTimeout = null;
let isBypassActive = false; 

_api.storage.local.get(['bypassKey', 'isExtensionDisabled'], (res) => {
  if (res.bypassKey) bypassKey = res.bypassKey;
  if (res.isExtensionDisabled !== undefined) isExtensionDisabled = res.isExtensionDisabled;
});

_api.storage.onChanged.addListener((changes) => {
  if (changes.bypassKey) bypassKey = changes.bypassKey.newValue;
  if (changes.isExtensionDisabled) isExtensionDisabled = changes.isExtensionDisabled.newValue;
});

function checkKey(e) {
  if (bypassKey === "Alt") return e.altKey || e.key === "Alt";
  if (bypassKey === "Shift") return e.shiftKey || e.key === "Shift";
  if (bypassKey === "Control") return e.ctrlKey || e.key === "Control";
  if (bypassKey === "Meta") return e.metaKey || e.key === "Meta";
  return false;
}

document.addEventListener("keydown", (e) => {
  if (checkKey(e)) { isKeyCurrentlyHeld = true; isBypassActive = true; }
}, { capture: true, passive: true });

document.addEventListener("keyup", (e) => {
  if (!checkKey(e)) { isKeyCurrentlyHeld = false; }
}, { capture: true, passive: true });

window.addEventListener("blur", () => { isKeyCurrentlyHeld = false; });

function triggerBypassMemory() {
  isBypassActive = true;
  if (bypassMemoryTimeout) clearTimeout(bypassMemoryTimeout);
  bypassMemoryTimeout = setTimeout(() => { isBypassActive = isKeyCurrentlyHeld; }, 3000);
}

function shouldBypass() { return isExtensionDisabled || isBypassActive; }

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB") {
    handleBlob(message.url, message.filename);
    sendResponse({ success: true });
  }
  if (message.type === "CREDENTIALED_FETCH") {
    handleCredentialedFetch(message.url, message.filename);
    sendResponse({ success: true });
  }
});

const DOWNLOAD_EXTENSIONS = [
  "zip","gz","tar","rar","7z","bz2","xz","zst","cab","iso","tgz",
  "mp4","mkv","avi","mov","wmv","flv","webm","m4v","mpg","mpeg","ts",
  "mp3","m4a","flac","wav","aac","ogg","opus","wma",
  "pdf","doc","docx","xls","xlsx","ppt","pptx","epub","mobi",
  "dmg","pkg","exe","msi","deb","rpm","apk","ipa","bin","img","toast",
  "torrent","nzb",
];

function isDownloadURL(url) {
  try {
    const path = new URL(url).pathname.toLowerCase().split("?")[0];
    return DOWNLOAD_EXTENSIONS.some(ext => path.endsWith("." + ext));
  } catch { return false; }
}

function extractFilename(url, anchor) {
  if (anchor?.getAttribute("download")) return anchor.getAttribute("download");
  try {
    const u  = new URL(url);
    const fn = u.searchParams.get("filename") || u.searchParams.get("name");
    if (fn) return decodeURIComponent(fn);
    const parts = u.pathname.split("/");
    const last  = decodeURIComponent(parts[parts.length - 1]);
    return last || "download";
  } catch { return "download"; }
}

function nativeFallback(url, filename) {
  const a = document.createElement('a');
  a.href = url;
  if (filename) a.download = filename;
  a.setAttribute('data-daisy-bypass', 'true');
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

function sendToDispatch(url, filename) {
  if (url.startsWith("blob:")) {
    handleBlob(url, filename);
    return;
  }
  _api.runtime.sendMessage({
    type: "PREPARE_DISPATCH_DOWNLOAD",
    url: url,
    filename: filename || ""
  }).catch(() => {
    nativeFallback(url, filename);
  });
}

document.addEventListener("click", (e) => {
  let el = e.target;
  while (el && el.tagName !== "A") el = el.parentElement;
  
  if (el && el.hasAttribute('data-daisy-bypass')) return;
  if (shouldBypass() || checkKey(e) || isKeyCurrentlyHeld) { triggerBypassMemory(); return; }
  if (!el || !el.href || el.href.startsWith("javascript:")) return;

  const href        = el.href;
  const hasDownload = el.hasAttribute("download");
  const isFile      = isDownloadURL(href);

  if (href.startsWith("magnet:") || href.startsWith("blob:") || hasDownload || isFile) {
    e.preventDefault(); e.stopImmediatePropagation();
    sendToDispatch(href, extractFilename(href, el));
    return;
  }
}, { capture: true });

// Strips the browser's guessed MIME type and forces a generic binary stream
function fixMimeType(dataUri) {
  if (!dataUri || !dataUri.startsWith("data:")) return dataUri;
  return dataUri.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,");
}

async function handleCredentialedFetch(url, filename) {
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error("Fetch failed");

    const cd = r.headers.get("content-disposition");
    if (cd) {
      const rfc = cd.match(/filename\*=UTF-8''([^;\r\n]+)/i);
      const plain = cd.match(/filename=["']?([^"';\r\n]+)/i);
      const resolved = rfc ? decodeURIComponent(rfc[1].trim()) : (plain ? plain[1].trim().replace(/["']/g, "") : null);
      if (resolved) filename = resolved;
    }

    const blob = await r.blob();
    const reader = new FileReader();
    reader.onload = async () => {
      const payload = JSON.stringify({ 
        url: fixMimeType(reader.result), 
        filename: filename || "download", 
        referer: location.href, 
        ua: navigator.userAgent 
      });
      
      let success = false;
      for (let port = 6840; port <= 6850; port++) {
        try {
          const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, {
            method: "POST", headers: { "Content-Type": "application/json" }, body: payload
          });
          if (resp.ok) { success = true; break; }
        } catch (_) {}
      }
      if (!success) nativeFallback(url, filename);
    };
    reader.readAsDataURL(blob);
  } catch (_) {
    nativeFallback(url, filename);
  }
}

async function handleBlob(blobUrl, filename) {
  try {
    const r = await fetch(blobUrl);
    const blob = await r.blob();
    if (blob.size === 0) return;
    
    const reader = new FileReader();
    reader.onload = async () => {
      const payload = JSON.stringify({ 
        url: fixMimeType(reader.result), 
        filename: filename || "download", 
        referer: location.href, 
        ua: navigator.userAgent 
      });
      let success = false;
      for (let port = 6840; port <= 6850; port++) {
        try {
          const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, {
            method: "POST", headers: { "Content-Type": "application/json" }, body: payload
          });
          if (resp.ok) { success = true; break; }
        } catch (_) {}
      }
      if (!success) nativeFallback(blobUrl, filename);
    };
    reader.readAsDataURL(blob);
  } catch (_) {
    nativeFallback(blobUrl, filename);
  }
}

const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
      if (el.hasAttribute('data-daisy-bypass')) { _click(); return; }
      if (shouldBypass()) { _click(); return; }
      if (!el.href) { _click(); return; }
      if (el.href.startsWith("blob:") || el.hasAttribute("download") || isDownloadURL(el.href)) {
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
        return;
      }
      _click();
    };
  }
  return el;
};

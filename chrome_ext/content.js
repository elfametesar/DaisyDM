// content.js - Dispatch Safari/Chrome Extension

const _api = typeof browser !== "undefined" ? browser : chrome;

// ── Bypass Key Tracking ────────────────────────────────────────────────────
let bypassKey = "altKey"; 
let isBypassKeyHeld = false;

_api.runtime.sendMessage({ type: "GET_BYPASS_KEY" }, (response) => {
    if (response && response.bypassKey) bypassKey = response.bypassKey;
});

_api.runtime.onMessage.addListener((message) => {
    if (message.type === "UPDATE_BYPASS_KEY" && message.bypassKey) bypassKey = message.bypassKey;
});

window.addEventListener("keydown", (e) => {
    if (bypassKey && e[bypassKey]) isBypassKeyHeld = true;
}, { capture: true });

window.addEventListener("keyup", (e) => {
    if (bypassKey && !e[bypassKey]) isBypassKeyHeld = false;
}, { capture: true });

window.addEventListener("blur", () => isBypassKeyHeld = false);

// ── Definitions ────────────────────────────────────────────────────────────
const DOWNLOAD_EXTENSIONS = [
  "zip","gz","tar","rar","7z","bz2","xz","zst","cab","iso","tgz",
  "mp4","mkv","avi","mov","wmv","flv","webm","m4v","mpg","mpeg","ts",
  "mp3","m4a","flac","wav","aac","ogg","opus","wma",
  "pdf","doc","docx","xls","xlsx","ppt","pptx","epub","mobi",
  "dmg","pkg","exe","msi","deb","rpm","apk","ipa","bin","img","toast",
  "torrent","nzb",
];

const DOWNLOAD_SITE_PATTERNS = [
  /gofile\.io/, /drive\.google\.com/, /docs\.google\.com/, /mega\.nz/,
  /mediafire\.com/, /dropbox\.com/, /onedrive\.live\.com/,
  /wetransfer\.com/, /pixeldrain\.com/, /catbox\.moe/,
  /buzzheavier\.com/, /filebin\.net/, /workupload\.com/, /sendspace\.com/,
  /hetzner\.com/,
];

const onDownloadSite = DOWNLOAD_SITE_PATTERNS.some(p => p.test(location.href));

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

// ── Send to background (Or Relay to Browser) ──────────────────────────────
function sendToDispatch(url, filename) {
  if (isBypassKeyHeld) {
      // THE FIX: If bypassed, explicitly force the browser to handle the download natively.
      console.log("[Dispatch] Bypass active. Relaying to browser natively:", url);
      const a = document.createElement('a');
      a.href = url;
      if (filename) a.download = filename;
      a.style.display = 'none';
      a.dataset.dispatchBypass = "true"; // Tag it so our click listener ignores it
      
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      return;
  }

  _api.runtime.sendMessage({
    type:     "PREPARE_DISPATCH_DOWNLOAD",
    url:      url,
    filename: filename || ""
  }).catch(() => {});
}

// ── Click interceptor ─────────────────────────────────────────────────────
document.addEventListener("click", (e) => {
  let el = e.target;
  while (el && el.tagName !== "A") el = el.parentElement;
  if (!el || !el.href || el.href.startsWith("javascript:")) return;

  // 1. Ignore our own synthetic bypass clicks
  if (el.dataset.dispatchBypass === "true") return;

  // 2. If user is physically holding the bypass key, let the browser handle it naturally
  if (bypassKey && e[bypassKey]) return;

  const href        = el.href;
  const hasDownload = el.hasAttribute("download");
  const isFile      = isDownloadURL(href);

  if (hasDownload || isFile) {
    e.preventDefault();
    e.stopImmediatePropagation();
    sendToDispatch(href, extractFilename(href, el));
    return;
  }

  if (href.startsWith("blob:")) {
    e.preventDefault();
    e.stopImmediatePropagation();
    handleBlob(href, extractFilename(href, el));
  }
}, { capture: true });

// ── Dynamic <a>.click() intercept ─────────────────────────────────────────
const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
      if (isBypassKeyHeld || el.dataset.dispatchBypass === "true") { _click(); return; }

      if (!el.href) { _click(); return; }
      if (el.href.startsWith("blob:")) {
        handleBlob(el.href, el.getAttribute("download") || "download");
        return; 
      }
      if (el.hasAttribute("download") || isDownloadURL(el.href)) {
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
        return; 
      }
      _click();
    };
  }
  return el;
};

// ── window.open intercept ──────────────────────────────────────────────────
const _winOpen = window.open;
window.open = function(url, ...rest) {
  if (url && !url.startsWith("javascript:")) {
      if (isBypassKeyHeld) {
          sendToDispatch(url, extractFilename(url));
          return null; // Stop the popup, force the native download tag
      }
      if (url.startsWith("blob:"))  { handleBlob(url, "download"); return null; }
      if (isDownloadURL(url))       { sendToDispatch(url, extractFilename(url)); return null; }
      if (onDownloadSite)           { sendToDispatch(url, extractFilename(url)); return null; }
  }
  return _winOpen.call(this, url, ...rest);
};

// ── XHR intercept ─────────────────────────────────────────────────────────
const _xhrOpen = XMLHttpRequest.prototype.open;
const _xhrSend = XMLHttpRequest.prototype.send;

XMLHttpRequest.prototype.open = function(method, url, ...rest) {
  this.__url = url;
  return _xhrOpen.call(this, method, url, ...rest);
};

XMLHttpRequest.prototype.send = function(...args) {
  if (onDownloadSite) {
    this.addEventListener("load", function() {
      try {
        const found = findDownloadURL(JSON.parse(this.responseText));
        if (found) sendToDispatch(found.url, found.filename);
      } catch (_) {}
    });
  }
  return _xhrSend.apply(this, args);
};

// ── Fetch intercept ───────────────────────────────────────────────────────
if (onDownloadSite) {
  const _fetch = window.fetch;
  window.fetch = async function(...args) {
    const resp = await _fetch.apply(this, args);
    resp.clone().text().then(text => {
      try {
        const found = findDownloadURL(JSON.parse(text));
        if (found) sendToDispatch(found.url, found.filename);
      } catch (_) {}
    }).catch(() => {});
    return resp;
  };
}

// ── Blob handling ──────────────────────────────────────────────────────────
function handleBlob(blobUrl, filename) {
  if (isBypassKeyHeld) return;
  fetch(blobUrl).then(r => {
    const fn = r.headers.get("content-disposition")
      ?.match(/filename=["']?([^"';]+)/i)?.[1]?.trim();
    if (fn) filename = fn;
    return r.blob();
  }).then(blob => {
    const reader  = new FileReader();
    reader.onload = () => sendToDispatch(reader.result, filename || "download");
    reader.readAsDataURL(blob);
  }).catch(() => showBanner("Couldn't read blob — right-click the download button.", "error"));
}

function findDownloadURL(obj, depth = 0) {
 if (!obj || depth > 6) return null;
  if (typeof obj === "string")
    return (obj.startsWith("http") && isDownloadURL(obj))
      ? { url: obj, filename: extractFilename(obj) } : null;
  if (typeof obj !== "object") return null;
  if (obj.data?.directLink) return { url: obj.data.directLink, filename: extractFilename(obj.data.directLink) };
  if (obj.data?.link)       return { url: obj.data.link,       filename: extractFilename(obj.data.link) };
  for (const key of ["download_url","downloadUrl","url","link","file","direct","src"]) {
    if (typeof obj[key] === "string" && obj[key].startsWith("http"))
      return { url: obj[key], filename: obj.filename || obj.name || extractFilename(obj[key]) };
  }
  for (const val of Object.values(obj)) {
    const f = findDownloadURL(val, depth + 1);
    if (f) return f;
  }
  return null;
}

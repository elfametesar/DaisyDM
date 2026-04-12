// content.js - Dispatch Extension

const _api = typeof browser !== "undefined" ? browser : chrome;

// ── Global Bypass State & Memory Buffer ──────────────────────────────────
let bypassKey = "Alt"; 
let isExtensionDisabled = false;
let isKeyCurrentlyHeld = false;
let bypassMemoryTimeout = null;
let isBypassActive = false; 

// Load user settings from popup
_api.storage.local.get(['bypassKey', 'isExtensionDisabled'], (res) => {
  if (res.bypassKey) bypassKey = res.bypassKey;
  if (res.isExtensionDisabled !== undefined) isExtensionDisabled = res.isExtensionDisabled;
});

// Listen for popup changes in real-time
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
  if (checkKey(e)) {
    isKeyCurrentlyHeld = true;
    isBypassActive = true;
  }
}, { capture: true, passive: true });

document.addEventListener("keyup", (e) => {
  if (!checkKey(e)) {
    isKeyCurrentlyHeld = false;
  }
}, { capture: true, passive: true });

window.addEventListener("blur", () => {
  isKeyCurrentlyHeld = false;
});

// Creates a 3-second blind spot where the extension ignores EVERYTHING.
// This ensures async delayed downloads (like Claude) bypass successfully.
function triggerBypassMemory() {
  isBypassActive = true;
  if (bypassMemoryTimeout) clearTimeout(bypassMemoryTimeout);
  bypassMemoryTimeout = setTimeout(() => {
    isBypassActive = isKeyCurrentlyHeld; 
  }, 3000);
}

function shouldBypass() {
  return isExtensionDisabled || isBypassActive;
}

// ─────────────────────────────────────────────────────────────────────────

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

function sendToDispatch(url, filename) {
  _api.runtime.sendMessage({
    type:     "PREPARE_DISPATCH_DOWNLOAD",
    url:      url,
    filename: filename || ""
  }).catch(() => {});
}

// ── Click interceptor ─────────────────────────────────────────────────────
document.addEventListener("click", (e) => {
  if (shouldBypass() || checkKey(e) || isKeyCurrentlyHeld) {
    triggerBypassMemory(); 
    return;
  }

  let el = e.target;
  while (el && el.tagName !== "A") el = el.parentElement;
  if (!el || !el.href || el.href.startsWith("javascript:")) return;

  const href        = el.href;
  const hasDownload = el.hasAttribute("download");
  const isFile      = isDownloadURL(href);

  if (href.startsWith("magnet:")) {
    e.preventDefault();
    e.stopImmediatePropagation();
    sendToDispatch(href, extractFilename(href, el));
    return;
  }

  if (href.startsWith("blob:")) {
    e.preventDefault();
    e.stopImmediatePropagation();
    handleBlob(href, extractFilename(href, el));
    return;
  }

  if (hasDownload || isFile) {
    e.preventDefault();
    e.stopImmediatePropagation();
    sendToDispatch(href, extractFilename(href, el));
    return;
  }
}, { capture: true });

// ── Dynamic <a>.click() intercept ─────────────────────────────────────────
const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
      if (shouldBypass()) { _click(); return; }

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
  if (shouldBypass()) return _winOpen.call(this, url, ...rest);

  if (url && !url.startsWith("javascript:")) {
    if (url.startsWith("blob:"))  { handleBlob(url, "download"); return null; }
    if (isDownloadURL(url))       { sendToDispatch(url, extractFilename(url)); return null; }
    if (onDownloadSite)           { sendToDispatch(url, extractFilename(url)); return null; }
  }
  return _winOpen.call(this, url, ...rest);
};

// ── Site-specific patches ──────────────────────────────────────────────────
function patchDownloadButtons() {
  if (/gofile\.io/.test(location.href)) {
    document.querySelectorAll(
      'a[href*="gofile.io/download"], a[href*="/d/"], button[id*="download"], [class*="download"]'
    ).forEach(el => {
      if (el.__dy) return; el.__dy = true;
      el.addEventListener("click", (e) => {
        if (shouldBypass() || checkKey(e)) triggerBypassMemory();
      }, { capture: false });
    });
  }

  if (/drive\.google\.com/.test(location.href)) {
    document.querySelectorAll('[data-tooltip="Download"], [aria-label="Download"]').forEach(btn => {
      if (btn.__dy) return; btn.__dy = true;
      btn.addEventListener("click", (e) => {
        if (shouldBypass() || checkKey(e)) { triggerBypassMemory(); return; }
        e.preventDefault(); e.stopImmediatePropagation();
        const match = location.href.match(/\/d\/([a-zA-Z0-9_-]+)/);
        if (match) sendToDispatch(`https://drive.google.com/uc?export=download&id=${match[1]}`, "");
      }, { capture: true });
    });
  }

  if (/pixeldrain\.com/.test(location.href)) {
    document.querySelectorAll('a[href*="/api/file/"], a[download]').forEach(el => {
      if (el.__dy) return; el.__dy = true;
      el.addEventListener("click", (e) => {
        if (shouldBypass() || checkKey(e)) { triggerBypassMemory(); return; }
        e.preventDefault(); e.stopImmediatePropagation();
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
      }, { capture: true });
    });
  }
}

new MutationObserver(patchDownloadButtons)
  .observe(document.documentElement, { childList: true, subtree: true });
document.readyState === "loading"
  ? document.addEventListener("DOMContentLoaded", patchDownloadButtons)
  : patchDownloadButtons();

// ── Blob handling ──────────────────────────────────────────────────────────
async function handleBlob(blobUrl, filename) {
  try {
    const r = await fetch(blobUrl);
    const cd = r.headers.get("content-disposition");
    if (cd) {
      const m = cd.match(/filename=["']?([^"';]+)/i);
      if (m) filename = m[1].trim();
    }
    const blob = await r.blob();
    if (blob.size > 500 * 1024 * 1024) return;

    const isTorrent = (filename || "").toLowerCase().endsWith(".torrent")
                   || blob.type === "application/x-bittorrent"
                   || blob.type === "application/octet-stream"
                   || blob.type === "";
    if (isTorrent) {
      const buf = await blob.arrayBuffer();
      for (let port = 6840; port <= 6850; port++) {
        try {
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 1000);
          const resp = await fetch(`http://127.0.0.1:${port}/torrent`, {
            method: "POST",
            headers: {
              "Content-Type": "application/octet-stream",
              "X-Filename": filename || "download.torrent",
              "Content-Length": buf.byteLength,
            },
            body: buf,
            signal: ctrl.signal,
          });
          clearTimeout(t);
          if (resp.ok) return;
        } catch (_) {}
      }
      return;
    }

    const reader = new FileReader();
    reader.onload = () => sendToDispatch(reader.result, filename || "download");
    reader.readAsDataURL(blob);
  } catch (_) {}
}

// ── JSON response scanner ──────────────────────────────────────────────────
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

// ── XHR / Fetch Intercepts ─────────────────────────────────────────────────
const _xhrOpen = XMLHttpRequest.prototype.open;
const _xhrSend = XMLHttpRequest.prototype.send;

XMLHttpRequest.prototype.open = function(method, url, ...rest) {
  this.__url = url;
  return _xhrOpen.call(this, method, url, ...rest);
};

XMLHttpRequest.prototype.send = function(...args) {
  const skip = shouldBypass(); // Check memory window
  if (onDownloadSite) {
    this.addEventListener("load", function() {
      try {
        if (skip) return; 
        const found = findDownloadURL(JSON.parse(this.responseText));
        if (found) sendToDispatch(found.url, found.filename);
      } catch (_) {}
    });
  }
  return _xhrSend.apply(this, args);
};

if (onDownloadSite) {
  const _fetch = window.fetch;
  window.fetch = async function(...args) {
    const skip = shouldBypass(); // Check memory window
    const resp = await _fetch.apply(this, args);
    resp.clone().text().then(text => {
      try {
        if (skip) return; 
        const found = findDownloadURL(JSON.parse(text));
        if (found) sendToDispatch(found.url, found.filename);
      } catch (_) {}
    }).catch(() => {});
    return resp;
  };
}

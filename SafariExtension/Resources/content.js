// content.js - Dispatch Safari Extension
// Safari content scripts support chrome.* via a shim; browser.* is also available.
// Key difference: no chrome.downloads API, so ALL interception happens here.

const _api = typeof browser !== "undefined" ? browser : chrome;

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

// ── Send to background ────────────────────────────────────────────────────
function sendToDispatch(url, filename, additionalData = {}) {
  _api.runtime.sendMessage({
    type:     "PREPARE_DISPATCH_DOWNLOAD",
    url:      url,
    filename: filename || "",
    ...additionalData
  }).catch(() => {});
}

// ── Click interceptor ─────────────────────────────────────────────────────
document.addEventListener("click", (e) => {
  let el = e.target;
  while (el && el.tagName !== "A") el = el.parentElement;
  if (!el || !el.href || el.href.startsWith("javascript:")) return;

  const href        = el.href;
  const hasDownload = el.hasAttribute("download");
  const isFile      = isDownloadURL(href);

  if ((hasDownload || isFile) && !e.altKey) {
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
// Safari supports overriding document.createElement in content scripts.
const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
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

// ── Site-specific patches ──────────────────────────────────────────────────
function patchDownloadButtons() {
  if (/gofile\.io/.test(location.href)) {
    document.querySelectorAll(
      'a[href*="gofile.io/download"], a[href*="/d/"], button[id*="download"], [class*="download"]'
    ).forEach(el => {
      if (el.__dy) return; el.__dy = true;
      el.addEventListener("click", () => {}, { capture: false });
    });
  }

  if (/drive\.google\.com/.test(location.href)) {
    document.querySelectorAll('[data-tooltip="Download"], [aria-label="Download"]').forEach(btn => {
      if (btn.__dy) return; btn.__dy = true;
      btn.addEventListener("click", (e) => {
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
function handleBlob(blobUrl, filename) {
  fetch(blobUrl).then(r => {
    const fn = r.headers.get("content-disposition")
      ?.match(/filename=["']?([^"';]+)/i)?.[1]?.trim();
    if (fn) filename = fn;
    return r.blob();
  }).then(blob => {
    if (blob.size > 500 * 1024 * 1024) {
      showBanner("Blob > 500 MB — right-click the download button instead.", "warning");
      return;
    }
    const reader  = new FileReader();
    reader.onload = () => sendToDispatch(reader.result, filename || "download");
    reader.readAsDataURL(blob);
  }).catch(() => showBanner("Couldn't read blob — right-click the download button.", "error"));
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

// ── Banner ─────────────────────────────────────────────────────────────────
function showBanner(msg, type = "info") {
  document.getElementById("__dispatch_banner")?.remove();
  const colors = { info: "#0a84ff", warning: "#ff9f0a", error: "#ff453a" };
  const d = Object.assign(document.createElement("div"), { id: "__dispatch_banner" });
  d.style.cssText = `position:fixed;top:16px;right:16px;z-index:2147483647;background:#1c1c1e;color:#f2f2f7;padding:12px 16px;border-radius:10px;font:13px -apple-system,sans-serif;border-left:3px solid ${colors[type]};box-shadow:0 4px 20px rgba(0,0,0,0.4);max-width:320px;display:flex;align-items:center;gap:8px;`;
  d.innerHTML = `<span>${type === "error" ? "⚠️" : "↓"}</span><span>${msg}</span>`;
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 4000);
}

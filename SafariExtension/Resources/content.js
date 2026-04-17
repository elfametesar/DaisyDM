// content.js - Daisy Safari Extension

const _api = typeof browser !== "undefined" ? browser : chrome;
const IS_TOP_FRAME = window === window.top;

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
  if (bypassKey === "Meta") return e.metaKey || e.key === "Meta"; // Command Key
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

let sniffedMediaUrls = [];

function normalizeUrl(url) {
    if (!url) return "";
    try {
        const u = new URL(url);
        ["_", "t", "token", "sig", "signature", "key", "auth", "cb"].forEach(p => u.searchParams.delete(p));
        return u.toString().toLowerCase().replace(/\/+$/, "");
    } catch { return url.toLowerCase().trim(); }
}

function bubbleMediaToTop(url) {
    if (IS_TOP_FRAME) {
        if (!sniffedMediaUrls.some(m => normalizeUrl(m.url) === normalizeUrl(url))) {
            sniffedMediaUrls.push({ url, frameOrigin: window.location.origin });
        }
    } else {
        try {
            window.top.postMessage({ __daisyMedia: { url, frameOrigin: window.location.origin } }, "*");
        } catch (_) {}
    }
}

if (IS_TOP_FRAME) {
    window.addEventListener("message", (e) => {
        if (e.data && e.data.__daisyMedia) {
            const { url } = e.data.__daisyMedia;
            bubbleMediaToTop(url);
        }
    });
}

// ... [Keep getActualYtFormats, sniffScriptUrls, runScriptSniffer, fetchHlsQualities as they are standard JS]

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB") handleBlob(message.url, message.filename);
  if (message.type === "CREDENTIALED_FETCH") handleCredentialedFetch(message.url, message.filename);
  if (message.type === 'NEW_MEDIA_FOUND' && message.mediaInfo) bubbleMediaToTop(message.mediaInfo.url);
  if (message.action === "getPageInfo") {
    sendResponse({
        title: document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Unknown Video",
        pageUrl: window.location.href,
        cookies: document.cookie
    });
  }
  return true;
});

// ... [Keep DOWNLOAD_EXTENSIONS, isDownloadURL, extractFilename, nativeFallback as they are standard JS]

function sendToDispatch(url, filename, additionalData = {}) {
  if (url.startsWith("blob:") && !additionalData.forceHLS) { handleBlob(url, filename); return; }
  let finalFilename = filename || "Download";
  if (!/\.[0-9a-z]+$/i.test(finalFilename)) finalFilename += ".mp4";
  
  try {
    _api.runtime.sendMessage({
      type: "PREPARE_DISPATCH_DOWNLOAD",
      url: url,
      filename: finalFilename,
      cookies: document.cookie,
      ...additionalData
    }).catch(() => nativeFallback(url, finalFilename));
  } catch (error) {
     nativeFallback(url, finalFilename);
  }
}

// ... [Keep handleCredentialedFetch, handleBlob, and document.createElement proxy as they are]

(function() {
    // Initiation remains standard; Safari handles MutationObservers well.
    // ... [Keep the startDetection logic, overlayMap, and scanForMedia intervals]
})();

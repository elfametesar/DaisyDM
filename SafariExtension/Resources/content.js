// content.js - Daisy Safari Extension with Key-Hold Capture

const _api = typeof browser !== 'undefined' ? browser : chrome;
const IS_TOP_FRAME = window === window.top;

let bypassKey = "Alt";
let isExtensionDisabled = false;
let isKeyCurrentlyHeld = false;
let bypassMemoryTimeout = null;
let isBypassActive = false;

// New: Track if we're in capture mode
let captureModeActive = false;
let capturedUrl = null;
let captureIndicator = null;

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

// Show visual indicator when capture mode is active
function showCaptureIndicator(url) {
  if (captureIndicator) captureIndicator.remove();
  
  captureIndicator = document.createElement('div');
  captureIndicator.innerHTML = `
    <div style="position: fixed; bottom: 20px; right: 20px; z-index: 2147483647; 
                background: rgba(51, 65, 85, 0.95); backdrop-filter: blur(12px); 
                padding: 12px 20px; border-radius: 12px; font-family: -apple-system, sans-serif;
                color: white; font-size: 14px; border-left: 4px solid #10b981;
                box-shadow: 0 4px 12px rgba(0,0,0,0.3); pointer-events: none;
                animation: slideIn 0.3s ease;">
      🎯 Daisy Capture Mode Active<br>
      <span style="font-size: 11px; color: #94a3b8;">Click any link to download with Daisy</span>
    </div>
  `;
  
  const style = document.createElement('style');
  style.textContent = `
    @keyframes slideIn {
      from { transform: translateX(100px); opacity: 0; }
      to { transform: translateX(0); opacity: 1; }
    }
  `;
  if (!document.querySelector('#daisy-capture-style')) {
    style.id = 'daisy-capture-style';
    document.head.appendChild(style);
  }
  
  document.body.appendChild(captureIndicator);
  
  setTimeout(() => {
    if (captureIndicator) {
      captureIndicator.style.animation = 'slideIn 0.3s reverse';
      setTimeout(() => captureIndicator?.remove(), 300);
    }
  }, 2000);
}

function hideCaptureIndicator() {
  if (captureIndicator) {
    captureIndicator.remove();
    captureIndicator = null;
  }
}

// Global click capture for when capture mode is active
document.addEventListener('click', (e) => {
  if (!captureModeActive) return;
  
  // Find the closest link element
  let target = e.target;
  let link = null;
  
  while (target && target !== document.body) {
    if (target.tagName === 'A' && target.href) {
      link = target;
      break;
    }
    target = target.parentElement;
  }
  
  if (link && link.href) {
    e.preventDefault();
    e.stopPropagation();
    
    const url = link.href;
    const filename = link.getAttribute('download') || extractFilename(url);
    
    // Dispatch the download
    sendToDispatch(url, filename, {});
    
    // Exit capture mode after capture
    captureModeActive = false;
    hideCaptureIndicator();
    
    // Show success indicator
    showSuccessIndicator(url);
  }
}, true);

function showSuccessIndicator(url) {
  const indicator = document.createElement('div');
  indicator.innerHTML = `
    <div style="position: fixed; bottom: 20px; right: 20px; z-index: 2147483647; 
                background: rgba(16, 185, 129, 0.95); backdrop-filter: blur(12px); 
                padding: 12px 20px; border-radius: 12px; font-family: -apple-system, sans-serif;
                color: white; font-size: 14px; box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                pointer-events: none; animation: slideIn 0.3s ease;">
      ✓ Sent to Daisy!<br>
      <span style="font-size: 11px; opacity: 0.8;">Download started in app</span>
    </div>
  `;
  document.body.appendChild(indicator);
  setTimeout(() => indicator.remove(), 2000);
}

// Monitor key hold for capture mode activation
document.addEventListener("keydown", (e) => {
  const keyMatches = checkKey(e);
  
  if (keyMatches) {
    isKeyCurrentlyHeld = true;
    isBypassActive = true;
    
    // NEW: If key is held for 500ms, activate capture mode
    if (!captureModeActive && !captureModeTimeout) {
      captureModeTimeout = setTimeout(() => {
        captureModeActive = true;
        showCaptureIndicator();
        captureModeTimeout = null;
      }, 500);
    }
  }
}, { capture: true, passive: true });

let captureModeTimeout = null;

document.addEventListener("keyup", (e) => {
  if (!checkKey(e)) {
    isKeyCurrentlyHeld = false;
    
    // Clear pending capture mode activation
    if (captureModeTimeout) {
      clearTimeout(captureModeTimeout);
      captureModeTimeout = null;
    }
    
    // Deactivate capture mode if key released
    if (captureModeActive) {
      captureModeActive = false;
      hideCaptureIndicator();
    }
  }
}, { capture: true, passive: true });

window.addEventListener("blur", () => {
  isKeyCurrentlyHeld = false;
  if (captureModeTimeout) {
    clearTimeout(captureModeTimeout);
    captureModeTimeout = null;
  }
  captureModeActive = false;
  hideCaptureIndicator();
});

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

function getActualYtFormats() {
    let formats = new Set();
    try {
        const scripts = document.querySelectorAll('script');
        for (let s of scripts) {
            const text = s.textContent || "";
            if (text.includes('ytInitialPlayerResponse') || text.includes('streamingData')) {
                const regex = /"height"\s*:\s*(\d+)/g;
                let match;
                while ((match = regex.exec(text)) !== null) {
                    let height = parseInt(match[1]);
                    if (height >= 144 && height <= 4320) formats.add(height);
                }
            }
        }
    } catch(e) {}
    return Array.from(formats).sort((a, b) => b - a);
}

function sniffScriptUrls(root) {
    const found = [];
    try {
        const scripts = (root || document).querySelectorAll('script');
        const mediaRe = /https?:\/\/[^\s'"\\]+?(?:\.m3u8|\.mp4|\.webm|\.mov|\.ts|\/m3u8|\/hls\/|\/stream\/|manifest\.m3u8|master\.m3u8)[^\s'"\\]*/gi;
        for (let s of scripts) {
            const text = s.textContent || "";
            let match;
            while ((match = mediaRe.exec(text)) !== null) {
                found.push(match[0].replace(/[,;}\]]+$/, ""));
            }
        }
    } catch(e) {}
    return found;
}

function runScriptSniffer(root) {
    sniffScriptUrls(root).forEach(url => bubbleMediaToTop(url));
}

const _hlsQualityCache = new Map();
async function fetchHlsQualities(masterUrl) {
    const key = normalizeUrl(masterUrl);
    if (_hlsQualityCache.has(key)) return _hlsQualityCache.get(key);
    try {
        const resp = await fetch(masterUrl, { credentials: "include" });
        if (!resp.ok) throw new Error();
        const text = await resp.text();
        if (!text.includes("#EXT-X-STREAM-INF")) return [{ label: "HLS Stream", url: masterUrl, bandwidth: 0 }];
        const variants = [];
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].trim().startsWith("#EXT-X-STREAM-INF")) {
                const resMatch = lines[i].match(/RESOLUTION=\d+x(\d+)/);
                const height = resMatch ? parseInt(resMatch[1]) : null;
                let variantUri = "";
                for (let j = i + 1; j < lines.length; j++) {
                    const next = lines[j].trim();
                    if (next && !next.startsWith("#")) { variantUri = next; break; }
                }
                if (!variantUri) continue;
                let variantUrl = variantUri.startsWith("http") ? variantUri : new URL(variantUri, masterUrl).href;
                variants.push({ label: height ? `${height}p` : "HLS Variant", url: variantUrl, bandwidth: lines[i].match(/BANDWIDTH=(\d+)/)?.[1] || 0 });
            }
        }
        variants.sort((a, b) => b.bandwidth - a.bandwidth);
        _hlsQualityCache.set(key, variants);
        return variants;
    } catch { return [{ label: "HLS Stream", url: masterUrl, bandwidth: 0 }]; }
}

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB") handleBlob(message.url, message.filename);
  if (message.type === "CREDENTIALED_FETCH") handleCredentialedFetch(message.url, message.filename);
  if (message.type === 'NEW_MEDIA_FOUND' && message.mediaInfo) bubbleMediaToTop(message.mediaInfo.url);
  if (message.action === "getPageInfo") {
    sendResponse({
        title: document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Unknown Video",
        pageUrl: window.location.href,
        cookies: document.cookie    });
  }
  return true;
});

const DOWNLOAD_EXTENSIONS = ["mp4","mkv","avi","mov","wmv","flv","webm","m4v","mpg","mpeg","ts","m3u8"];

function isDownloadURL(url) {
  try {
    const path = new URL(url).pathname.toLowerCase().split("?")[0];
    return DOWNLOAD_EXTENSIONS.some(ext => path.endsWith("." + ext));
  } catch { return false; }
}

function extractFilename(url, anchor) {
  if (anchor?.getAttribute("download")) return anchor.getAttribute("download");
  try {
    const u = new URL(url);
    const fn = u.searchParams.get("filename") || u.searchParams.get("name");
    if (fn) return decodeURIComponent(fn);
    return decodeURIComponent(u.pathname.split("/").pop()) || "download";
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
    if (error.message && error.message.includes("Extension context invalidated")) {
      console.warn("DaisyDM: Extension updated, connection lost. Please refresh the page.");
      alert("DaisyDM has been updated. Please refresh the page to continue downloading (F5 / Cmd+R).");
    } else {
      nativeFallback(url, finalFilename);
    }
  }
}

async function handleCredentialedFetch(url, filename) {
  try {
    const r = await fetch(url);
    const blob = await r.blob();
    const reader = new FileReader();
    reader.onload = async () => {
        const payload = JSON.stringify({ url: reader.result.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,"), filename: filename || "download", referer: location.href, ua: navigator.userAgent, cookies: document.cookie });
        for (let port = 6840; port <= 6850; port++) {
            try {
                const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
                if (resp.ok) return;
            } catch (_) {}
        }
        nativeFallback(url, filename);
    };
    reader.readAsDataURL(blob);
  } catch (_) { nativeFallback(url, filename); }
}

async function handleBlob(blobUrl, filename) {
  try {
    const r = await fetch(blobUrl);
    const blob = await r.blob();
    const reader = new FileReader();
    reader.onload = async () => {
        const payload = JSON.stringify({ url: reader.result.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,"), filename: filename || "download", referer: location.href, ua: navigator.userAgent, cookies: document.cookie });
        for (let port = 6840; port <= 6850; port++) {
            try {
                const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
                if (resp.ok) return;
            } catch (_) {}
        }
        nativeFallback(blobUrl, filename);
    };
    reader.readAsDataURL(blob);
  } catch (_) { nativeFallback(blobUrl, filename); }
}

// Enhanced click interceptor with capture mode awareness
const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
      // If capture mode is active, intercept regardless
      if (captureModeActive && el.href) {
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
        captureModeActive = false;
        hideCaptureIndicator();
        showSuccessIndicator(el.href);
        return;
      }
      
      if (el.hasAttribute('data-daisy-bypass') || shouldBypass() || !el.href) {
        _click();
        return;
      }
      if (el.href.startsWith("blob:") || el.hasAttribute("download") || isDownloadURL(el.href)) {
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
      } else {
        _click();
      }
    };
  }
  return el;
};

// Also intercept clicks at document level for dynamically created links
document.addEventListener('click', (e) => {
  if (captureModeActive) return; // Already handled by capture mode handler
  
  let target = e.target;
  let link = null;
  
  while (target && target !== document.body) {
    if (target.tagName === 'A' && target.href) {
      link = target;
      break;
    }
    target = target.parentElement;
  }
  
  if (link && link.href && !link.hasAttribute('data-daisy-processed')) {
    if (!shouldBypass() && (link.href.startsWith('blob:') || link.hasAttribute('download') || isDownloadURL(link.href))) {
      e.preventDefault();
      e.stopPropagation();
      sendToDispatch(link.href, link.getAttribute('download') || extractFilename(link.href));
    }
  }
}, true);

(function() {
    runScriptSniffer(document);
    if (!IS_TOP_FRAME) {
        function watchSubframeVideos(root) {
            if (!root) return;
            const videos = root.querySelectorAll ? root.querySelectorAll('video') : [];
            videos.forEach(v => {
                if (v.dataset.daisySniffed) return;
                v.dataset.daisySniffed = "true";
                const report = () => {
                    if (v.src) bubbleMediaToTop(v.src);
                    v.querySelectorAll('source').forEach(s => bubbleMediaToTop(s.src));
                    if (v.currentSrc) bubbleMediaToTop(v.currentSrc);
                };
                report();
                v.addEventListener('loadedmetadata', report, { once: true });
            });
            if (root.querySelectorAll) root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) watchSubframeVideos(el.shadowRoot); });
        }
        const subObs = new MutationObserver(() => { watchSubframeVideos(document); runScriptSniffer(document); });
        if (document.body) { subObs.observe(document.body, { childList: true, subtree: true }); watchSubframeVideos(document); }
        else document.addEventListener('DOMContentLoaded', () => { subObs.observe(document.body, { childList: true, subtree: true }); watchSubframeVideos(document); });
        return;
    }

    if (window.__daisydm_video_injected) return;
    const init = () => {
        if (!document.head || !document.body) { setTimeout(init, 50); return; }
        window.__daisydm_video_injected = true;
        startDetection();
    };

    function startDetection() {
        const style = document.createElement('style');
        style.textContent = `
            .daisydm-overlay-container { position: fixed; z-index: 2147483647; background: rgba(28, 28, 30, 0.85); backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 10px; font-family: -apple-system, sans-serif; box-shadow: 0 12px 24px rgba(0,0,0,0.4); display: none; flex-direction: column; min-width: 220px; transition: opacity 0.2s, transform 0.2s; opacity: 0; transform: translateY(5px); pointer-events: auto; }
            .daisydm-overlay-container.visible { display: flex; opacity: 1; transform: translateY(0); }
            .daisydm-overlay-header { background: #334155; color: white; padding: 10px 14px; font-size: 13px; font-weight: 600; cursor: pointer; display: flex; justify-content: space-between; align-items: center; border-radius: 10px 10px 0 0; }
            .daisydm-overlay-dropdown { display: none; flex-direction: column; max-height: 280px; overflow-y: auto; background: transparent; }
            .daisydm-overlay-container.expanded .daisydm-overlay-dropdown { display: flex; border-top: 1px solid rgba(255, 255, 255, 0.1); }
            .daisydm-overlay-option { padding: 12px 14px; font-size: 13px; color: #efeff4; cursor: pointer; border-bottom: 1px solid rgba(255, 255, 255, 0.05); display: flex; justify-content: space-between; align-items: center; }
            .daisydm-overlay-option:hover { background: rgba(255, 255, 255, 0.1); color: #fff; }
            .daisydm-badge { font-size: 10px; background: rgba(255, 255, 255, 0.15); color: #aaa; padding: 2px 6px; border-radius: 4px; text-transform: uppercase; font-weight: 700; }
        `;
        document.head.appendChild(style);

        const overlayMap = new WeakMap();

        function createOverlay(targetEl) {
            if (overlayMap.has(targetEl)) return;
            const container = document.createElement('div');
            container.className = 'daisydm-overlay-container';
            container.innerHTML = `<div class="daisydm-overlay-header">Daisy Download</div><div class="daisydm-overlay-dropdown"></div>`;
            document.body.appendChild(container);
            overlayMap.set(targetEl, container);

            const dropdown = container.querySelector('.daisydm-overlay-dropdown');
            container.querySelector('.daisydm-overlay-header').onclick = (e) => {
                e.stopPropagation();
                container.classList.toggle('expanded');
                if (container.classList.contains('expanded')) populateDropdown(targetEl, dropdown);
            };

            const updatePos = () => {
                const rect = targetEl.getBoundingClientRect();
                container.style.top = (rect.top + window.scrollY + 15) + 'px';
                container.style.left = (rect.left + window.scrollX + 15) + 'px';
            };

            targetEl.addEventListener('mouseenter', () => { updatePos(); container.classList.add('visible'); });
            document.addEventListener('mousemove', (e) => {
                const rect = targetEl.getBoundingClientRect();
                const over = e.clientX >= rect.left - 30 && e.clientX <= rect.right + 30 && e.clientY >= rect.top - 30 && e.clientY <= rect.bottom + 30;
                if (!over && !container.classList.contains('expanded')) container.classList.remove('visible');
            });
        }

        async function populateDropdown(targetEl, dropdownEl) {
            dropdownEl.innerHTML = '<div class="daisydm-overlay-option" style="color:#888">Scanning streams...</div>';
            const pageUrl = window.location.href;
            if (pageUrl.includes('youtube.com')) {
                const trueHeights = getActualYtFormats();
                dropdownEl.innerHTML = '';
                const ytQuals = [{ id: "bestvideo+bestaudio/best", label: "Best Available" }, ...trueHeights.map(h => ({ id: `bestvideo[height<=${h}]+bestaudio/best`, label: `${h}p` })), { id: "bestaudio/best", label: "Audio Only" }];
                ytQuals.forEach(q => renderOption(dropdownEl, { label: q.label, url: pageUrl, ytQuality: q.id }));
                return;
            }
            const urls = new Set(sniffedMediaUrls.map(m => m.url));
            if (targetEl.tagName === 'VIDEO') {
                if (targetEl.src && !targetEl.src.startsWith('blob:')) urls.add(targetEl.src);
                targetEl.querySelectorAll('source').forEach(s => urls.add(s.src));
            }
            const options = [];
            for (const url of urls) {
                if (url.includes('m3u8')) {
                    const variants = await fetchHlsQualities(url);
                    variants.forEach(v => options.push({ label: v.label, url: v.url, isHLS: true }));
                } else if (isDownloadURL(url)) {
                    options.push({ label: 'Video File', url, isHLS: false });
                }
            }
            dropdownEl.innerHTML = '';
            options.forEach(opt => renderOption(dropdownEl, opt));
        }

        function renderOption(dropdownEl, opt) {
            const item = document.createElement('div');
            item.className = 'daisydm-overlay-option';
            item.innerHTML = `<span>${opt.label}</span><span class="daisydm-badge">${opt.ytQuality ? 'YT' : (opt.isHLS ? 'HLS' : 'MP4')}</span>`;
            item.onclick = (e) => {
                e.stopPropagation();
                sendToDispatch(opt.url, document.title.replace(/[\\/:*?"<>|]/g, ''), { youtubeQuality: opt.ytQuality, forceHLS: opt.isHLS });
                item.closest('.daisydm-overlay-container').classList.remove('expanded');
            };
            dropdownEl.appendChild(item);
        }

        function scanForMedia() {
            document.querySelectorAll('video, iframe').forEach(el => {
                const r = el.getBoundingClientRect();
                if (r.width > 50 && r.height > 50) createOverlay(el);
            });
        }
        const observer = new MutationObserver(scanForMedia);
        observer.observe(document.body, { childList: true, subtree: true });
        setInterval(() => { scanForMedia(); runScriptSniffer(document); }, 3000);
        scanForMedia();
    }
    init();
})();

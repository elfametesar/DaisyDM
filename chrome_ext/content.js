// content.js - Daisy Extension (Chrome & Safari)

const _api = typeof browser !== "undefined" ? browser : chrome;
const IS_TOP_FRAME = window === window.top;

let bypassKey = "Alt";
let isExtensionDisabled = false;
let isKeyCurrentlyHeld = false;
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
  if (bypassKey === "Alt")     return e.altKey   || e.key === "Alt";
  if (bypassKey === "Shift")   return e.shiftKey  || e.key === "Shift";
  if (bypassKey === "Control") return e.ctrlKey   || e.key === "Control";
  if (bypassKey === "Meta")    return e.metaKey   || e.key === "Meta";
  return false;
}

document.addEventListener("keydown", (e) => {
  if (checkKey(e)) { isKeyCurrentlyHeld = true; isBypassActive = true; }
}, { capture: true, passive: true });

document.addEventListener("keyup", (e) => {
  if (!checkKey(e)) { isKeyCurrentlyHeld = false; }
}, { capture: true, passive: true });

window.addEventListener("blur", () => { isKeyCurrentlyHeld = false; });

function shouldBypass() { return isExtensionDisabled || isBypassActive; }

// --- STATE MANAGEMENT ---
let sniffedMediaUrls = [];
let _lastSeenUrl = window.location.href;
const capturedMediaRequestHeaders = new Map();

// Strict mapping to isolate URLs to specific video elements
const playerUrlMap = new WeakMap();

// Flush dictionaries when feeds recycle DOM elements
document.addEventListener('loadstart', (e) => {
    if (e.target.tagName === 'VIDEO') playerUrlMap.delete(e.target);
}, true);

// Find exact playing video to assign incoming background network chunks to
function getLikelyTargetMediaElements() {
    const elements = Array.from(document.querySelectorAll('video'));
    const playing = elements.filter(v => !v.paused && v.readyState > 0);
    if (playing.length > 0) return playing;
    
    const loading = elements.filter(v => v.networkState === 2);
    return loading.length > 0 ? loading : [];
}

function resetDaisyState() {
    sniffedMediaUrls = [];
    document.querySelectorAll('.daisydm-overlay-container').forEach(overlay => {
        overlay.classList.remove('visible', 'expanded');
    });
}

const _origPushState = history.pushState;
history.pushState = function(...args) { resetDaisyState(); return _origPushState.apply(this, args); };
const _origReplaceState = history.replaceState;
history.replaceState = function(...args) { resetDaisyState(); return _origReplaceState.apply(this, args); };
window.addEventListener('popstate', resetDaisyState);

setInterval(() => {
    if (window.location.href !== _lastSeenUrl) {
        _lastSeenUrl = window.location.href;
        resetDaisyState();
    }
}, 1000);

function collectStorageHeaders() {
    const headers = {};
    const TOKEN_KEYS = /token|auth|bearer|access_?key|api_?key|account/i;
    const storages = [window.localStorage, window.sessionStorage];
    for (const storage of storages) {
        try {
            for (let i = 0; i < storage.length; i++) {
                const key = storage.key(i);
                if (!TOKEN_KEYS.test(key)) continue;
                const val = storage.getItem(key);
                if (!val || val.length > 512) continue;
                try {
                    const parsed = JSON.parse(val);
                    if (typeof parsed === "string") { headers["Authorization"] = `Bearer ${parsed}`; headers["X-Auth-Token"] = parsed; }
                    else if (parsed?.token) { headers["Authorization"] = `Bearer ${parsed.token}`; headers["X-Auth-Token"] = parsed.token; }
                    else if (parsed?.accessToken) { headers["Authorization"] = `Bearer ${parsed.accessToken}`; }
                } catch { headers["Authorization"] = `Bearer ${val}`; headers["X-Auth-Token"] = val; }
            }
        } catch (_) {}
    }
    return headers;
}

function normalizeUrl(url) {
    if (!url) return "";
    try {
        const u = new URL(url);
        ["_", "t", "token", "sig", "signature", "key", "auth", "cb"].forEach(p => u.searchParams.delete(p));
        return u.toString().toLowerCase().replace(/\/+$/, "");
    } catch { return url.toLowerCase().trim(); }
}

function cleanMediaUrl(urlStr) {
    try {
        const u = new URL(urlStr);
        u.searchParams.delete('bytestart');
        u.searchParams.delete('byteend');
        return u.toString();
    } catch { return urlStr; }
}

function bubbleMediaToTop(rawUrl) {
    if (!rawUrl || rawUrl.startsWith('blob:') || rawUrl.startsWith('data:')) return;
    const url = cleanMediaUrl(rawUrl);
    
    if (IS_TOP_FRAME) {
        if (!sniffedMediaUrls.some(m => normalizeUrl(m.url) === normalizeUrl(url))) {
            sniffedMediaUrls.push({ url, frameOrigin: window.location.origin });
            if (sniffedMediaUrls.length > 30) sniffedMediaUrls.shift(); // Keep memory clean
        }
        
        const targets = getLikelyTargetMediaElements();
        targets.forEach(el => {
            if (!playerUrlMap.has(el)) playerUrlMap.set(el, new Set());
            playerUrlMap.get(el).add(url);
        });
    } else {
        try { window.top.postMessage({ __daisyMedia: { url, frameOrigin: window.location.origin } }, "*"); } catch (_) {}
    }
}

window.addEventListener("message", (e) => {
    if (e.data && e.data.__daisyMedia) bubbleMediaToTop(e.data.__daisyMedia.url);
    if (e.data && e.data.__daisyMediaHeaders) {
        const { url, headers } = e.data.__daisyMediaHeaders;
        if (url && headers && typeof headers === "object") {
            const existing = capturedMediaRequestHeaders.get(url) || {};
            capturedMediaRequestHeaders.set(url, Object.assign({}, existing, headers));
        }
    }
});

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
                    const h = parseInt(match[1]);
                    if (h >= 144 && h <= 4320) formats.add(h);
                }
            }
        }
    } catch(e) {}
    return Array.from(formats).sort((a, b) => b - a);
}

async function fetchHlsQualities(masterUrl) {
    return new Promise(resolve => {
        _api.runtime.sendMessage({ type: "FETCH_HLS_QUALITIES", url: masterUrl }, (variants) => {
            resolve(variants && variants.length ? variants : [{ label: "Original", url: masterUrl, bandwidth: 0 }]);
        });
    });
}

async function fetchDashQualities(mpdUrl) {
    return new Promise(resolve => {
        _api.runtime.sendMessage({ type: "FETCH_DASH_QUALITIES", url: mpdUrl }, (variants) => {
            resolve(variants && variants.length ? variants : [{ label: "Original", url: mpdUrl }]);
        });
    });
}

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB")          handleBlob(message.url, message.filename);
  if (message.type === "CREDENTIALED_FETCH")  handleCredentialedFetch(message.url, message.filename);
  if (message.type === 'NEW_MEDIA_FOUND' && message.mediaInfo) bubbleMediaToTop(message.mediaInfo.url);
  if (message.action === "getPageInfo") {
    sendResponse({ title: document.title, pageUrl: window.location.href, cookies: document.cookie, pageHeaders: collectPageHeaders() });
  }
  return true;
});

function getExtFromUrl(url) {
    try {
        const ext = new URL(url).pathname.split('.').pop().toLowerCase();
        return ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4a', 'mp3', 'ts'].includes(ext) ? `.${ext}` : '.mp4';
    } catch { return '.mp4'; }
}

function nativeFallback(url, filename) {
  const a = document.createElement('a'); a.href = url;
  if (filename) a.download = filename;
  a.setAttribute('data-daisy-bypass', 'true');
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
}

function collectPageHeaders() {
    const headers = {};
    headers["referer"] = window.location.href;
    headers["origin"] = window.location.origin;
    if (navigator.language) headers["accept-language"] = navigator.language;
    headers["user-agent"] = navigator.userAgent;
    Object.assign(headers, collectStorageHeaders());
    return headers;
}

function collectMediaHeaders(mediaUrl) {
    if (!mediaUrl) return {};
    const exact = capturedMediaRequestHeaders.get(mediaUrl) || {};
    let originHeaders = {};
    try { originHeaders = capturedMediaRequestHeaders.get(new URL(mediaUrl).origin) || {}; } catch (_) {}
    return Object.assign({}, originHeaders, exact);
}

function sendToDispatch(url, filename, additionalData = {}) {
  if (url.startsWith("blob:") && !additionalData.forceHLS && !additionalData.forceDASH) {
      handleBlob(url, filename); return;
  }
  let finalFilename = filename || "Download";
  if (!/\.[0-9a-z]+$/i.test(finalFilename)) finalFilename += ".mp4";
  
  const mergedPageHeaders = Object.assign({}, collectPageHeaders(), collectMediaHeaders(url));
  
  try {
    _api.runtime.sendMessage({
        type: "PREPARE_DISPATCH_DOWNLOAD", url: url, filename: finalFilename, cookies: "",
        pageHeaders: mergedPageHeaders, ...additionalData
    }).catch(() => nativeFallback(url, finalFilename));
  } catch (error) {
    nativeFallback(url, finalFilename);
  }
}

async function handleCredentialedFetch(url, filename) {
  try {
    const r = await fetch(url); const blob = await r.blob(); const reader = new FileReader();
    reader.onload = async () => {
        const payload = JSON.stringify({ url: reader.result.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,"), filename: filename || "download", referer: location.href, ua: navigator.userAgent, cookies: "", pageHeaders: collectPageHeaders() });
        for (let port = 6840; port <= 6850; port++) {
            try { const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: payload }); if (resp.ok) return; } catch (_) {}
        }
        nativeFallback(url, filename);
    };
    reader.readAsDataURL(blob);
  } catch (_) { nativeFallback(url, filename); }
}

async function handleBlob(blobUrl, filename) {
    handleCredentialedFetch(blobUrl, filename);
}

// ━━━ THE SMART TITLE EXTRACTOR ━━━
// Climbs the DOM to find the exact caption/title for the specific video you hovered over
function getContextualVideoName(el) {
    if (!el) return null;
    let label = el.getAttribute('aria-label') || el.getAttribute('title');
    if (label && label.length > 2) return label;
    
    let curr = el;
    for (let i = 0; i < 12 && curr && curr !== document.body; i++) {
        // Facebook & Instagram Specific Captions
        let socialCaption = curr.querySelector('[data-ad-comet-preview="message"], [data-ad-preview="message"], [data-testid="post_message"], ._5pbx, ._1mwp, h1');
        if (socialCaption && socialCaption.innerText) {
            let clean = socialCaption.innerText.trim().split('\n')[0].substring(0, 60);
            if (clean.length > 2) return clean;
        }
        
        // Reddit / Twitter / General Header Fallback
        let heading = curr.querySelector('h2, h3, [role="heading"]');
        if (heading && heading.innerText) {
            let clean = heading.innerText.trim().split('\n')[0].substring(0, 60);
            if (clean.length > 2) return clean;
        }
        
        curr = curr.parentElement;
    }
    return null;
}

const _createElement = document.createElement.bind(document);
document.createElement = function(tag, ...args) {
  const el = _createElement(tag, ...args);
  if (tag.toLowerCase() === "a") {
    const _click = el.click.bind(el);
    el.click = function() {
      if (el.hasAttribute('data-daisy-bypass') || shouldBypass() || !el.href) { _click(); return; }
      const isDownloadUrl = ['.mp4', '.mkv', '.avi', '.webm', '.mov', '.wmv', '.flv', '.ts', '.m3u8', '.mpd'].some(ext => { try { return new URL(el.href).pathname.toLowerCase().endsWith(ext); } catch { return false; } });
      if (el.href.startsWith("blob:") || el.hasAttribute("download") || isDownloadUrl) {
          sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href, el));
      } else { _click(); }
    };
  }
  return el;
};

(function() {
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
            if (root.querySelectorAll) {
                root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) watchSubframeVideos(el.shadowRoot); });
            }
        }
        const subObs = new MutationObserver(() => { watchSubframeVideos(document); });
        if (document.body) { subObs.observe(document.body, { childList: true, subtree: true }); watchSubframeVideos(document); }
        else { document.addEventListener('DOMContentLoaded', () => { subObs.observe(document.body, { childList: true, subtree: true }); watchSubframeVideos(document); }); }
        return;
    }

    if (window.__daisydm_video_injected) return;
    
    const init = () => {
        if (!document.head || !document.body) { setTimeout(init, 50); return; }
        document.querySelectorAll('.daisydm-overlay-container').forEach(el => el.remove());
        window.__daisydm_video_injected = true;
        startDetection();
    };

    function startDetection() {

        const style = document.createElement('style');
        style.textContent = `
            @keyframes daisy-shimmer { 0% { background-position: -200% center; } 100% { background-position: 200% center; } }
            * { -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; }
            .daisydm-overlay-container { position: absolute; z-index: 2147483647; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; display: flex; flex-direction: column; min-width: 280px; max-width: 280px; width: max-content; pointer-events: none; visibility: hidden; background-color: #1c1c1e; border: 1px solid #2c2c2e; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25); border-radius: 16px; overflow: hidden; opacity: 0; transform: translateY(12px) scale(0.95); transition: opacity 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), transform 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), visibility 0.25s, max-width 0.3s cubic-bezier(0.2, 0.8, 0.2, 1); }
            .daisydm-overlay-container.expanded { max-width: 520px; }
            .daisydm-overlay-container.visible { opacity: 1; transform: translateY(0) scale(1); visibility: visible; pointer-events: auto; }
            .daisydm-overlay-container.scroll-hidden { opacity: 0 !important; pointer-events: none !important; transform: translateY(12px) scale(0.95) !important; visibility: hidden !important; }
            .daisydm-overlay-header { padding: 12px 16px; font-size: 14px; font-weight: 500; cursor: pointer; display: flex; align-items: center; gap: 10px; color: #f4f4f5; user-select: none; -webkit-user-select: none; }
            .daisydm-header-icon { font-size: 15px; line-height: 1; flex-shrink: 0; }
            .daisydm-header-label { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .daisydm-chevron { font-size: 10px; color: #8e8e93; flex-shrink: 0; transition: transform 0.2s ease; }
            .daisydm-overlay-container.expanded .daisydm-chevron { transform: rotate(180deg); }
            .daisydm-close-btn { background: transparent; border: none; color: #8e8e93; font-size: 12px; line-height: 1; cursor: pointer; padding: 4px; border-radius: 4px; flex-shrink: 0; transition: background 0.15s ease, color 0.15s ease; }
            .daisydm-close-btn:hover { background: #2c2c2e; color: #f4f4f5; }
            .daisydm-dropdown-wrapper { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 0.3s cubic-bezier(0.2, 0.8, 0.2, 1), border-color 0.2s ease; border-top: 1px solid transparent; }
            .daisydm-overlay-container.expanded .daisydm-dropdown-wrapper { grid-template-rows: 1fr; border-top: 1px solid #2c2c2e; }
            .daisydm-dropdown-inner { min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
            .daisydm-overlay-dropdown { max-height: 350px; overflow-y: auto; display: flex; flex-direction: column; opacity: 0; pointer-events: none; transition: opacity 0.2s ease; background-color: #1c1c1e; }
            .daisydm-overlay-container.expanded .daisydm-overlay-dropdown { opacity: 1; pointer-events: auto; }
            .daisydm-overlay-option { padding: 12px 16px; font-size: 13px; color: #d1d1d6; cursor: pointer; border-bottom: 1px solid #2c2c2e; display: flex; justify-content: space-between; align-items: center; gap: 12px; transition: background 0.15s ease, color 0.15s ease; }
            .daisydm-overlay-option:last-child { border-bottom: none; }
            .daisydm-overlay-option:hover { background-color: #2c2c2e; color: #ffffff; }
            .daisydm-overlay-option:active { background-color: #3a3a3c; }
            .daisydm-badge { font-size: 10px; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; padding: 3px 6px; border-radius: 4px; flex-shrink: 0; white-space: nowrap; }
            .daisydm-badge.yt { color: #ff453a; background: rgba(255, 69, 58, 0.15); }
            .daisydm-badge.hls { color: #0a84ff; background: rgba(10, 132, 255, 0.15); }
            .daisydm-badge.dash { color: #bf5af2; background: rgba(191, 90, 242, 0.15); }
            .daisydm-badge.mp4 { color: #32d74b; background: rgba(50, 215, 75, 0.15); }
            .daisydm-badge.ext { color: #d1d1d6; background: rgba(209, 209, 214, 0.15); }
            .daisydm-shimmer { height: 12px; border-radius: 6px; background: linear-gradient(90deg, #2c2c2e 0%, #3a3a3c 50%, #2c2c2e 100%); background-size: 200% 100%; animation: daisy-shimmer 1.5s ease infinite; margin: 10px 16px; }
        `;
        document.head.appendChild(style);

        let globalOverlay = null;
        let currentTarget = null;
        let hideTimeout = null;
        let scrollTimer = null;
        const dismissedEls = new WeakSet();

        document.addEventListener('mousedown', (e) => {
            if (globalOverlay && globalOverlay.classList.contains('expanded')) {
                if (!globalOverlay.contains(e.target)) globalOverlay.classList.remove('visible', 'expanded');
            }
        });

        window.addEventListener('scroll', (e) => {
            if (!globalOverlay || globalOverlay.contains(e.target)) return;
            globalOverlay.classList.add('scroll-hidden');
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(() => {
                if (currentTarget && globalOverlay.classList.contains('visible')) positionOverlay(currentTarget);
                globalOverlay.classList.remove('scroll-hidden');
            }, 250);
        }, { passive: true, capture: true });

        function initGlobalOverlay() {
            if (globalOverlay) {
                if (!document.body.contains(globalOverlay)) { document.body.appendChild(globalOverlay); }
                document.querySelectorAll('.daisydm-overlay-container').forEach(el => { if (el !== globalOverlay) el.remove(); });
                return;
            }

            document.querySelectorAll('.daisydm-overlay-container').forEach(el => el.remove());
            globalOverlay = document.createElement('div');
            globalOverlay.className = 'daisydm-overlay-container';
            globalOverlay.style.position = 'absolute';
            
            globalOverlay.innerHTML = `
                <div class="daisydm-overlay-header">
                    <span class="daisydm-header-icon">🌼</span>
                    <span class="daisydm-header-label">Daisy Download</span>
                    <span class="daisydm-chevron">▼</span>
                    <button class="daisydm-close-btn" title="Dismiss">✕</button>
                </div>
                <div class="daisydm-dropdown-wrapper">
                    <div class="daisydm-dropdown-inner">
                        <div class="daisydm-overlay-dropdown"></div>
                    </div>
                </div>
            `;
            document.body.appendChild(globalOverlay);

            const dropdown = globalOverlay.querySelector('.daisydm-overlay-dropdown');

            globalOverlay.querySelector('.daisydm-close-btn').onclick = (e) => {
                e.stopPropagation();
                globalOverlay.classList.remove('visible', 'expanded');
                if (currentTarget) dismissedEls.add(currentTarget);
            };

            globalOverlay.querySelector('.daisydm-overlay-header').onclick = (e) => {
                if (e.target.closest('.daisydm-close-btn')) return;
                e.stopPropagation();
                globalOverlay.classList.toggle('expanded');
                if (globalOverlay.classList.contains('expanded') && currentTarget) {
                    populateDropdown(currentTarget, dropdown);
                }
            };

            globalOverlay.addEventListener('mouseenter', () => clearTimeout(hideTimeout));
            globalOverlay.addEventListener('mouseleave', () => {
                if (!globalOverlay.classList.contains('expanded')) {
                    clearTimeout(hideTimeout);
                    hideTimeout = setTimeout(() => { globalOverlay.classList.remove('visible'); }, 350);
                }
            });
        }

        function positionOverlay(el) {
            const rect = el.getBoundingClientRect();
            const margin = 12, ow = 520;
            let left = rect.left + window.scrollX + margin, top = rect.top + window.scrollY + margin;
            if (rect.left + margin + ow > window.innerWidth) { left = (rect.right + window.scrollX) - ow - margin; }
            globalOverlay.style.left = left + 'px';
            globalOverlay.style.top  = top + 'px';
        }
        
        function hasDownloadableMedia(el) {
            const pageUrl = window.location.href;
            if (pageUrl.includes('youtube.com')) { return window.location.pathname.startsWith('/watch') || window.location.pathname.startsWith('/shorts'); }
            if (sniffedMediaUrls.length > 0) return true;
            let found = false;
            const check = (url) => { if (url && !url.startsWith('blob:') && !url.startsWith('data:')) found = true; };
            [el, ...Array.from(el.querySelectorAll ? el.querySelectorAll('video') : [])].forEach(v => {
                if (!v) return;
                check(v.src); check(v.currentSrc);
                if (v.querySelectorAll) { v.querySelectorAll('source').forEach(s => check(s.src)); }
            });
            return found;
        }

        function attachToElement(el) {
            if (el.dataset.daisyBound) return;
            el.dataset.daisyBound = "true";
            el.addEventListener('mouseenter', () => {
                if (dismissedEls.has(el) || !hasDownloadableMedia(el)) return;
                initGlobalOverlay(); clearTimeout(hideTimeout);
                if (currentTarget !== el) { currentTarget = el; globalOverlay.classList.remove('expanded'); }
                positionOverlay(el); globalOverlay.classList.add('visible');
            });
            el.addEventListener('mouseleave', () => {
                if (globalOverlay && !globalOverlay.classList.contains('expanded')) {
                    clearTimeout(hideTimeout);
                    hideTimeout = setTimeout(() => { globalOverlay.classList.remove('visible'); }, 350);
                }
            });
        }

        async function populateDropdown(targetEl, dropdownEl) {
            dropdownEl.innerHTML = `
                <div class="daisydm-shimmer" style="width:58%"></div>
                <div class="daisydm-shimmer" style="width:72%;margin-top:5px"></div>
                <div class="daisydm-shimmer" style="width:44%;margin-top:5px;margin-bottom:8px"></div>
            `;
            
            const pageUrl = window.location.href;
            
            // 1. EXTRACT ACCURATE VIDEO NAME
            let contextualName = getContextualVideoName(targetEl);
            let vidName = contextualName || (document.title ? document.title.split(' - ')[0] : "Media");
            vidName = vidName.replace(/[\\/:*?"<>|]/g, '').trim() || "Video";

            if (pageUrl.includes('youtube.com')) {
                if (!window.location.pathname.startsWith('/watch') && !window.location.pathname.startsWith('/shorts')) {
                    dropdownEl.innerHTML = '<div class="daisydm-overlay-option" style="color:rgba(40,50,90,0.50);justify-content:center;font-size:12px">No video on this page</div>';
                    return;
                }
                const trueHeights = getActualYtFormats();
                dropdownEl.innerHTML = '';
                if (trueHeights.length > 0) {
                    trueHeights.map(h => ({ id: `bestvideo[height<=${h}]+bestaudio/best`, vidName: vidName, quality: `${h}p`, ext: ".mp4" }))
                        .forEach(q => renderOption(dropdownEl, { vidName: q.vidName, quality: q.quality, ext: q.ext, url: pageUrl, ytQuality: q.id, type: 'yt' }));
                } else {
                    renderOption(dropdownEl, { vidName: vidName, quality: "Original", ext: ".mp4", url: pageUrl, ytQuality: "bestvideo+bestaudio/best", type: 'yt' });
                }
                return;
            }

            const urls = new Set();
            const mediaNodes = [targetEl, ...Array.from(targetEl.querySelectorAll ? targetEl.querySelectorAll('video, iframe') : [])];
            
            // 2. GET URLS STRICTLY BOUND TO THIS SPECIFIC PLAYER
            mediaNodes.forEach(v => {
                if (!v) return;
                [v.src, v.currentSrc, ...Array.from(v.querySelectorAll ? v.querySelectorAll('source') : []).map(s => s.src)]
                    .filter(u => u && !u.startsWith('blob:') && !u.startsWith('data:'))
                    .forEach(u => urls.add(u));
                    
                if (playerUrlMap.has(v)) {
                    playerUrlMap.get(v).forEach(u => urls.add(u));
                }
            });

            // 3. AGGRESSIVE LOCAL DOM SNIFFER (Pierces Facebook/React hidden states)
            let container = targetEl;
            for (let i=0; i<8 && container.parentElement && container.tagName !== 'BODY'; i++) {
                container = container.parentElement;
            }
            const mediaRe = /https?:\/\/[^\s'"\\]+?(?:\.m3u8|\.mp4|\.webm|\.mov|\.ts|\.mpd|\/m3u8|\/hls\/|\/stream\/)[^\s'"\\,;}\]))]*/gi;
            let match;
            const htmlObj = container.outerHTML || "";
            while ((match = mediaRe.exec(htmlObj)) !== null) {
                let clean = match[0].replace(/[,;}\]]+$/, "").replace(/\\/g, '').replace(/&amp;/g, '&');
                urls.add(cleanMediaUrl(clean));
            }

            // 4. SMART FALLBACK (Only use global list if this isn't an infinite feed)
            const allVideosOnPage = document.querySelectorAll('video').length;
            if (urls.size === 0 && sniffedMediaUrls.length > 0 && allVideosOnPage <= 2) {
                sniffedMediaUrls.slice(-4).forEach(m => urls.add(m.url));
            }

            const options = [];
            for (const url of urls) {
                if (!url || url.startsWith('blob:') || url.startsWith('data:')) continue;
                if (url.includes('.ts') && !url.includes('.m3u8') && !url.includes('.mp4')) continue; // Ignore spam fragments
                
                if (url.includes('m3u8') || url.includes('HLSPlaylist') || url.includes('m3u8?')) {
                    const variants = await fetchHlsQualities(url);
                    variants.forEach(v => options.push({ vidName: vidName, quality: v.label === "Original" ? "" : v.label, ext: '.mp4', url: v.url, type: 'hls' }));
                } else if (url.includes('.mpd') || url.includes('DASHPlaylist')) {
                    const variants = await fetchDashQualities(url);
                    variants.forEach(v => {
                        if (v.height) {
                            options.push({ vidName: vidName, quality: v.label, ext: '.mp4', url: v.url, type: 'dash', ytQuality: `bestvideo[height<=${v.height}]+bestaudio/best` });
                        } else {
                            options.push({ vidName: vidName, quality: '', ext: '.mp4', url: v.url, type: 'dash' });
                        }
                    });
                } else {
                    options.push({ vidName: vidName, quality: '', ext: getExtFromUrl(url), url, type: 'mp4' });
                }
            }

            dropdownEl.innerHTML = '';
            if (options.length === 0) {
                if (globalOverlay) globalOverlay.classList.remove('visible', 'expanded');
                if (typeof dismissedEls !== "undefined" && targetEl) dismissedEls.add(targetEl);
                return;
            }
            options.forEach(opt => renderOption(dropdownEl, opt));
        }

        function renderOption(dropdownEl, opt) {
            let typeLabel = (opt.type || 'MP4').toUpperCase(), badgeClass = `daisydm-badge ${(opt.type || 'mp4').toLowerCase()}`;
            if (opt.ytQuality && opt.type !== 'dash') { typeLabel = 'YT'; badgeClass = 'daisydm-badge yt'; }
            else if (opt.type === 'dash') { typeLabel = 'DASH'; badgeClass = 'daisydm-badge dash'; }
            else if (opt.type === 'hls') { typeLabel = 'HLS'; badgeClass = 'daisydm-badge hls'; }
            else if (opt.type === 'yt') { typeLabel = 'YT'; badgeClass = 'daisydm-badge yt'; }

            const extLabel   = (opt.ext || '.mp4').replace('.', '').toUpperCase();
            const item = document.createElement('div');
            item.className = 'daisydm-overlay-option';
            const qualityHtml = opt.quality ? `<span style="white-space: nowrap; flex-shrink: 0; color: #a1a1a6;">&nbsp;- ${opt.quality}</span>` : '';
            item.innerHTML = `
                <div style="display: flex; align-items: center; min-width: 0; flex: 1; padding-right: 12px;">
                    <span style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex-shrink: 1;" title="${opt.vidName}">${opt.vidName}</span>
                    ${qualityHtml}
                </div>
                <div style="display: flex; gap: 6px; flex-shrink: 0;">
                    <span class="daisydm-badge ext">${extLabel}</span>
                    <span class="${badgeClass}">${typeLabel}</span>
                </div>
            `;
            
            item.onclick = (e) => {
                e.stopPropagation(); if (item._clicked) return; item._clicked = true;
                let sanitizedName = opt.vidName.replace(/[\\/:*?"<>|]/g, '').trim();
                let finalName = opt.quality ? `${sanitizedName} - ${opt.quality}` : sanitizedName;
                finalName += (opt.ext || '.mp4');
                sendToDispatch(opt.url, finalName, { youtubeQuality: opt.ytQuality, forceHLS: opt.type === 'hls', forceDASH: opt.type === 'dash' });
                const overlayContainer = item.closest('.daisydm-overlay-container');
                if (overlayContainer) overlayContainer.classList.remove('expanded', 'visible');
            };
            dropdownEl.appendChild(item);
        }

        const VIDEO_CONTAINER_SELECTORS = [
            'video', 'shreddit-player', 'shreddit-video', 'reddit-video-player', 'packaged-media-player',
            '[data-testid="media-element"]', '[data-testid="videoPlayer"]', '[data-testid="previewPlayPauseButton"]',
            '[class*="VideoPlayer"]', '[class*="video-player"]', '[class*="VideoContainer"]',
            '[class*="media-player"]', '[class*="MediaPlayer"]', '[class*="player-container"]',
            '[class*="video-container"]', '[data-component="VideoPlayer"]',
        ].join(', ');

        function scanForMedia() {
            document.querySelectorAll(VIDEO_CONTAINER_SELECTORS).forEach(el => {
                const r = el.getBoundingClientRect();
                if (r.width > 60 && r.height > 50) attachToElement(el);
            });
            
            document.querySelectorAll('video').forEach(v => {
                const r = v.getBoundingClientRect();
                if (r.width > 50 && r.height > 50) {
                    attachToElement(v);
                    let parent = v.parentElement;
                    for (let i = 0; i < 8 && parent; i++) {
                        if (parent.tagName === 'BODY' || parent.tagName === 'HTML') break;
                        attachToElement(parent);
                        parent = parent.parentElement;
                    }
                }
            });

            document.querySelectorAll('iframe').forEach(el => {
                const src = el.src || '', r = el.getBoundingClientRect();
                if (r.width > 200 && r.height > 120) attachToElement(el);
                else if (/youtube|vimeo|twitch|reddit|dailymotion|facebook|tiktok|streamable/i.test(src)) attachToElement(el);
            });
        }

        const observer = new MutationObserver(() => { scanForMedia(); });
        observer.observe(document.body, { childList: true, subtree: true });
        setInterval(() => { scanForMedia(); }, 2000);
        scanForMedia();
    }
    init();
})();

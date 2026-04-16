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

// Store network media caught by background.js
let sniffedMediaUrls = [];

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB") {
    handleBlob(message.url, message.filename);
    sendResponse({ success: true });
  }
  if (message.type === "CREDENTIALED_FETCH") {
    handleCredentialedFetch(message.url, message.filename);
    sendResponse({ success: true });
  }
  if (message.type === 'NEW_MEDIA_FOUND' && message.mediaInfo) { 
    sniffedMediaUrls.push(message.mediaInfo); 
    sendResponse({ success: true });
  }
  if (message.action === "getPageInfo") {
    sendResponse({
        title: document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Unknown Video",
        pageUrl: window.location.href,
        cookies: document.cookie
    });
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

function extractMagnetName(magnetUrl) {
    try {
        const params = new URLSearchParams(magnetUrl.replace('magnet:', '?'));
        const dn = params.get('dn');
        return dn ? decodeURIComponent(dn).replace(/\+/g, ' ') : "Torrent";
    } catch { return "Torrent"; }
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
  if (url.startsWith("blob:") && !additionalData.forceHLS) {
    handleBlob(url, filename);
    return;
  }
  
  let finalFilename = filename || "Download";
  
  // Only force .mp4 if it is explicitly a video stream, blob, or youtube link missing an extension
  const isMedia = url.startsWith("blob:") || additionalData.forceHLS || additionalData.youtubeQuality;
  const hasExtension = /\.[0-9a-z]+$/i.test(finalFilename);
  
  if (!hasExtension && isMedia) {
    finalFilename += ".mp4";
  }

  _api.runtime.sendMessage({
    type: "PREPARE_DISPATCH_DOWNLOAD",
    url: url,
    filename: finalFilename,
    ...additionalData
  }).catch(() => {
    nativeFallback(url, finalFilename);
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

  if (href.startsWith("magnet:")) {
    e.preventDefault(); e.stopImmediatePropagation();
    sendToDispatch(href, extractMagnetName(href));
    return;
  }

  if (href.startsWith("blob:") || hasDownload || isFile) {
    e.preventDefault(); e.stopImmediatePropagation();
    sendToDispatch(href, extractFilename(href, el));
    return;
  }
}, { capture: true });

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
        // FIX: Removed the hardcoded .mp4 forcing. It now respects the exact filename (e.g., .torrent)
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
  } catch (err) {
    console.error("DaisyDM: Blob capture failed, falling back to direct URL", err);
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
      if (el.href.startsWith("magnet:")) {
        sendToDispatch(el.href, extractMagnetName(el.href));
        return;
      }
      if (el.href.startsWith("blob:") || el.hasAttribute("download") || isDownloadURL(el.href)) {
        sendToDispatch(el.href, el.getAttribute("download") || extractFilename(el.href));
        return;
      }
      _click();
    };
  }
  return el;
};

// --- VIDEO PLAYER OVERLAY ---
(function() {
    if (window.__daisydm_video_injected) return;
    window.__daisydm_video_injected = true;

    const style = document.createElement('style');
    style.textContent = `
        .daisydm-overlay-container {
            position: absolute; 
            z-index: 2147483647; 
            background: rgba(28, 28, 30, 0.85);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.1); 
            border-radius: 10px; 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            box-shadow: 0 12px 24px rgba(0,0,0,0.4); 
            display: none; 
            flex-direction: column; 
            min-width: 200px;
            overflow: hidden;
            transition: opacity 0.2s ease, transform 0.2s ease;
            opacity: 0;
            transform: translateY(5px);
        }
        .daisydm-overlay-container.visible { 
            display: flex; 
            opacity: 1;
            transform: translateY(0);
        }
        .daisydm-overlay-header {
            background: #334155; 
            color: white; 
            padding: 10px 14px; 
            font-size: 13px; 
            font-weight: 600; 
            cursor: pointer;
            text-align: left; 
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.2s;
        }
        .daisydm-overlay-header:hover {
            background: #475569;
        }
        .daisydm-overlay-header::after {
            content: '▼';
            font-size: 10px;
            transition: transform 0.3s;
        }
        .daisydm-overlay-container.expanded .daisydm-overlay-header::after {
            transform: rotate(180deg);
        }
        .daisydm-overlay-dropdown { 
            display: none; 
            flex-direction: column; 
            background: transparent; 
            max-height: 280px; 
            overflow-y: auto; 
        }
        .daisydm-overlay-container.expanded .daisydm-overlay-dropdown { 
            display: flex; 
            border-top: 1px solid rgba(255, 255, 255, 0.1);
        }
        .daisydm-overlay-option { 
            padding: 12px 14px; 
            font-size: 13px; 
            color: #efeff4; 
            cursor: pointer; 
            border-bottom: 1px solid rgba(255, 255, 255, 0.05); 
            line-height: 1.4; 
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.2s;
        }
        .daisydm-overlay-option:last-child {
            border-bottom: none;
        }
        .daisydm-overlay-option:hover { 
            background: rgba(255, 255, 255, 0.1); 
            color: #fff; 
        }
        .daisydm-badge { 
            font-size: 10px; 
            background: rgba(255, 255, 255, 0.15); 
            color: #aaa;
            padding: 2px 6px; 
            border-radius: 4px; 
            text-transform: uppercase;
            font-weight: 700;
        }
        .daisydm-overlay-dropdown::-webkit-scrollbar {
            width: 6px;
        }
        .daisydm-overlay-dropdown::-webkit-scrollbar-thumb {
            background: rgba(255, 255, 255, 0.2);
            border-radius: 10px;
        }
    `;
    document.head.appendChild(style);

    function createOverlay(videoEl) {
        const container = document.createElement('div');
        container.className = 'daisydm-overlay-container';
        const header = document.createElement('div');
        header.className = 'daisydm-overlay-header';
        header.textContent = 'Daisy Download';
        const dropdown = document.createElement('div');
        dropdown.className = 'daisydm-overlay-dropdown';
        
        container.appendChild(header);
        container.appendChild(dropdown);
        document.body.appendChild(container);

        header.onclick = (e) => { 
            e.stopPropagation(); 
            container.classList.toggle('expanded'); 
            populateDropdown(videoEl, dropdown); 
        };
        
        const updatePos = () => {
            const rect = videoEl.getBoundingClientRect();
            container.style.top = (window.scrollY + rect.top + 15) + 'px';
            container.style.left = (window.scrollX + rect.left + 15) + 'px';
        };

        videoEl.addEventListener('mouseenter', () => { 
            updatePos(); 
            container.classList.add('visible'); 
        });
        
        document.addEventListener('mousemove', (e) => {
            const rect = videoEl.getBoundingClientRect();
            const padding = 30;
            const isOverVideo = (e.clientX >= rect.left - padding && e.clientX <= rect.right + padding && 
                                e.clientY >= rect.top - padding && e.clientY <= rect.bottom + padding);
            
            if (!isOverVideo && !container.classList.contains('expanded')) {
                container.classList.remove('visible');
            }
        });
    }

    function populateDropdown(videoEl, dropdownEl) {
        dropdownEl.innerHTML = ''; 
        let options = [];
        const currentUrl = window.location.href;

        const getQualityLabel = (url, fallback) => {
            const qualityMatch = url.match(/(\d{3,4}p|720|1080|2160|4K)/i);
            return qualityMatch ? qualityMatch[0].toUpperCase() : fallback;
        };

        const isLikelyVideo = (url) => {
            const videoPatterns = ['.mp4', '.m3u8', '.webm', '.mov', 'video', 'm3u8', 'stream'];
            return videoPatterns.some(pattern => url.toLowerCase().includes(pattern));
        };

        if (currentUrl.includes('youtube.com') || currentUrl.includes('youtu.be')) {
            const ytQualities = [
                { id: "b", label: "Best Quality" },
                { id: "bestvideo[height<=1080]+bestaudio/best", label: "1080p HD" },
                { id: "bestaudio/best", label: "Audio Only" }
            ];
            ytQualities.forEach(q => options.push({ label: q.label, url: currentUrl, ytQuality: q.id }));
        } else {
            if (videoEl.src && isLikelyVideo(videoEl.src)) {
                const isBlob = videoEl.src.startsWith('blob:');
                const label = isBlob ? 'Detected Stream' : getQualityLabel(videoEl.src, 'Primary Video');
                options.push({ label: label, url: videoEl.src, isHLS: videoEl.src.includes('m3u8') });
            }

            const sources = videoEl.querySelectorAll('source');
            sources.forEach((s) => {
                if (s.src && isLikelyVideo(s.src)) {
                    const label = getQualityLabel(s.src, s.type ? s.type.split('/')[1].toUpperCase() : 'Video Source');
                    options.push({ label: label, url: s.src, isHLS: s.src.includes('m3u8') });
                }
            });

            Array.from(new Set(sniffedMediaUrls.map(a => a.url))).forEach((url) => {
                if (isLikelyVideo(url) && url !== videoEl.src) {
                    const isHLS = url.includes('.m3u8') || url.includes('/m3u8/') || url.includes('type=m3u8');
                    const label = getQualityLabel(url, isHLS ? 'HLS Stream' : 'Video File');
                    options.push({ label: label, url: url, isHLS: isHLS });
                }
            });
        }

        if (options.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'daisydm-overlay-option';
            empty.style.color = '#888';
            empty.textContent = 'Searching for links...';
            dropdownEl.appendChild(empty);
            return;
        }

        options.forEach(opt => {
            const item = document.createElement('div');
            item.className = 'daisydm-overlay-option';
            item.innerHTML = `<span>${opt.label}</span> <span class="daisydm-badge">${opt.isHLS ? 'HLS' : 'MP4'}</span>`;
            item.onclick = (e) => {
                e.stopPropagation();
                item.innerHTML = `<span>Sending...</span>`;
                let cleanTitle = document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Video";
                
                // Transformed to match our robust downloading parameters
                sendToDispatch(opt.url, cleanTitle, { youtubeQuality: opt.ytQuality, forceHLS: opt.isHLS });
                
                setTimeout(() => { 
                    dropdownEl.parentElement.classList.remove('expanded'); 
                    populateDropdown(videoEl, dropdownEl); // Reset labels
                }, 1500);
            };
            dropdownEl.appendChild(item);
        });
    }

    function scanForVideos(root = document) {
        root.querySelectorAll('video').forEach(v => {
            if (!v.dataset.daisy) {
                v.dataset.daisy = "true";
                createOverlay(v);
            }
        });

        root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) {
                scanForVideos(el.shadowRoot);
            }
        });
    }

    const observer = new MutationObserver(() => scanForVideos());
    observer.observe(document.body, { childList: true, subtree: true });

    scanForVideos();
})();

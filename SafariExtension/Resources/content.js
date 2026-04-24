// content.js - Daisy Extension (Chrome & Safari)

// INJECT XHR/FETCH INTERCEPTOR TO CAPTURE AUTH HEADERS SENT BY CLIENT JS
const interceptorScript = document.createElement('script');
interceptorScript.textContent = `
    (function() {
        const MEDIA_RE = /\\.m3u8|stream\\.mpd|\\.mpd|dash|hls|\\.mp4|\\.webm|\\.mov|\\.ts|manifest/i;

        // Listen for requests to fetch YouTube formats natively from the page context
        window.addEventListener("message", (e) => {
            if (e.data && e.data.__daisyReqYtFormats) {
                let formats = new Set();
                try {
                    const player = document.querySelector('#movie_player');
                    if (player && typeof player.getPlayerResponse === 'function') {
                        const resp = player.getPlayerResponse();
                        if (resp && resp.streamingData) {
                            if (resp.streamingData.formats) resp.streamingData.formats.forEach(f => { if(f.height) formats.add(f.height); });
                            if (resp.streamingData.adaptiveFormats) resp.streamingData.adaptiveFormats.forEach(f => { if(f.height) formats.add(f.height); });
                        }
                    }
                    if (window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.streamingData) {
                        const sd = window.ytInitialPlayerResponse.streamingData;
                        if (sd.formats) sd.formats.forEach(f => { if(f.height) formats.add(f.height); });
                        if (sd.adaptiveFormats) sd.adaptiveFormats.forEach(f => { if(f.height) formats.add(f.height); });
                    }
                } catch(err) {}
                window.postMessage({ __daisyYtFormatsResp: Array.from(formats) }, "*");
            }
        });

        const _fetch = window.fetch;
        window.fetch = async function(...args) {
            const req = args[0];
            const opts = args[1] || {};
            let url = typeof req === 'string' ? req : (req && req.url ? req.url : '');
            let headers = {};
            
            if (opts.headers) {
                if (opts.headers instanceof Headers) {
                    for (let [k, v] of opts.headers.entries()) headers[k] = v;
                } else if (typeof opts.headers === 'object') {
                    headers = { ...opts.headers };
                } else if (Array.isArray(opts.headers)) {
                    opts.headers.forEach(h => headers[h[0]] = h[1]);
                }
            }
            
            if (req instanceof Request) {
                for (let [k, v] of req.headers.entries()) headers[k] = v;
            }
            
            let hasRange = false;
            if (headers) {
                const lowerHeaders = Object.keys(headers).map(k => k.toLowerCase());
                hasRange = lowerHeaders.includes('range');
            }
            
            // Always fire for media URLs or Range fetching, even if no custom headers
            if (Object.keys(headers).length > 0 || MEDIA_RE.test(url) || hasRange) {
                window.postMessage({ __daisyMediaHeaders: { url, headers } }, "*");
            }
            return _fetch.apply(this, args);
        };

        const _open = XMLHttpRequest.prototype.open;
        const _setRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
        const _send = XMLHttpRequest.prototype.send;
        
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this._daisyUrl = url;
            this._daisyHeaders = {};
            return _open.call(this, method, url, ...rest);
        };
        
        XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
            if (this._daisyHeaders) this._daisyHeaders[header] = value;
            return _setRequestHeader.call(this, header, value);
        };
        
        XMLHttpRequest.prototype.send = function(...args) {
            if (this._daisyUrl) {
                try {
                    const absoluteUrl = new URL(this._daisyUrl, document.baseURI).href;
                    let hasRange = false;
                    if (this._daisyHeaders) {
                        const lowerHeaders = Object.keys(this._daisyHeaders).map(k => k.toLowerCase());
                        hasRange = lowerHeaders.includes('range');
                    }
                    if (Object.keys(this._daisyHeaders || {}).length > 0 || MEDIA_RE.test(absoluteUrl) || hasRange) {
                        window.postMessage({ __daisyMediaHeaders: { url: absoluteUrl, headers: this._daisyHeaders || {} } }, "*");
                    }
                } catch(e) {
                    let hasRange = false;
                    if (this._daisyHeaders) {
                        const lowerHeaders = Object.keys(this._daisyHeaders).map(k => k.toLowerCase());
                        hasRange = lowerHeaders.includes('range');
                    }
                    if (Object.keys(this._daisyHeaders || {}).length > 0 || MEDIA_RE.test(this._daisyUrl) || hasRange) {
                        window.postMessage({ __daisyMediaHeaders: { url: this._daisyUrl, headers: this._daisyHeaders || {} } }, "*");
                    }
                }
            }
            return _send.apply(this, args);
        };
    })();
`;
if (document.head || document.documentElement) {
    (document.head || document.documentElement).prepend(interceptorScript);
    interceptorScript.remove();
}

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
  if (bypassKey === "Alt") return e.altKey || e.key === "Alt";
  if (bypassKey === "Shift") return e.shiftKey || e.key === "Shift";
  if (bypassKey === "Control") return e.ctrlKey || e.key === "Control";
  if (bypassKey === "Meta") return e.metaKey || e.key === "Meta";
  return false;
}

document.addEventListener("keydown", (e) => { if (checkKey(e)) { isKeyCurrentlyHeld = true; isBypassActive = true; } }, { capture: true, passive: true });
document.addEventListener("keyup", (e) => { if (!checkKey(e)) isKeyCurrentlyHeld = false; }, { capture: true, passive: true });
window.addEventListener("blur", () => { isKeyCurrentlyHeld = false; });

function shouldBypass() { return isExtensionDisabled || isBypassActive; }

// --- STATE MANAGEMENT ---
let sniffedMediaUrls = [];
let _lastSeenUrl = window.location.href;
const capturedMediaRequestHeaders = new Map();

const playerUrlMap = new WeakMap();
const iframeSrcMap = new WeakMap();

document.addEventListener('loadstart', (e) => {
    if (e.target.tagName === 'VIDEO') playerUrlMap.delete(e.target);
}, true);

setInterval(() => {
    document.querySelectorAll('iframe').forEach(ifr => {
        if (iframeSrcMap.get(ifr) !== ifr.src) {
            iframeSrcMap.set(ifr, ifr.src);
            playerUrlMap.delete(ifr);
        }
    });
}, 1000);

function getLikelyTargetMediaElements() {
    const elements = Array.from(document.querySelectorAll('video, iframe'));
    
    const playing = elements.filter(v => v.tagName === 'VIDEO' && !v.paused && v.readyState > 0);
    if (playing.length > 0) return playing;
    
    const loading = elements.filter(v => v.tagName === 'VIDEO' && v.networkState === 2);
    if (loading.length > 0) return loading;

    let closest = null;
    let minDistance = Infinity;
    const centerY = window.innerHeight / 2;
    
    elements.forEach(v => {
        const rect = v.getBoundingClientRect();
        if (rect.width > 50 && rect.height > 50 && rect.bottom > 0 && rect.top < window.innerHeight) {
            const vCenterY = rect.top + rect.height / 2;
            const distance = Math.abs(centerY - vCenterY);
            if (distance < minDistance) {
                minDistance = distance;
                closest = v;
            }
        }
    });
    return closest ? [closest] : [];
}

function resetDaisyState() {
    sniffedMediaUrls = [];
    document.querySelectorAll('.daisydm-overlay-container').forEach(overlay => overlay.classList.remove('visible', 'expanded'));
}

const _origPushState = history.pushState;
history.pushState = function(...args) { resetDaisyState(); return _origPushState.apply(this, args); };
const _origReplaceState = history.replaceState;
history.replaceState = function(...args) { resetDaisyState(); return _origReplaceState.apply(this, args); };
window.addEventListener('popstate', resetDaisyState);
setInterval(() => { if (window.location.href !== _lastSeenUrl) { _lastSeenUrl = window.location.href; resetDaisyState(); } }, 1000);

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
        ["_", "t", "token", "sig", "signature", "key", "auth", "cb", "expires"].forEach(p => u.searchParams.delete(p));
        return u.toString().toLowerCase().replace(/\/+$/, "");
    } catch { return url.toLowerCase().trim(); }
}

function cleanMediaUrl(urlStr) {
    try {
        const u = new URL(urlStr);
        u.searchParams.delete('bytestart');
        u.searchParams.delete('byteend');
        u.searchParams.delete('range');
        return u.toString();
    } catch { return urlStr; }
}

function bubbleMediaToTop(data) {
    let rawUrl = typeof data === 'string' ? data : data.url;
    let mediaType = typeof data === 'object' && data.mediaType ? data.mediaType : 'unknown';
    
    if (!rawUrl || rawUrl.startsWith('blob:') || rawUrl.startsWith('data:')) return;
    const url = cleanMediaUrl(rawUrl);
    
    let lower = url.toLowerCase();
    if (mediaType === 'unknown') {
        if (lower.includes('.m3u8') || lower.includes('/m3/') || lower.includes('playlist')) mediaType = 'hls';
        else if (lower.includes('.mpd') || lower.includes('/dash/') || lower.includes('manifest')) mediaType = 'dash';
        else if (lower.includes('.mp4') || lower.includes('.webm') || lower.includes('.mov') || lower.includes('.ts')) mediaType = 'mp4';
    }
    
    if (IS_TOP_FRAME) {
        const now = Date.now();
        // Maintain list memory for a 2-hour sliding window, capped at 200 URLs to solve missing videos that ended fetching.
        sniffedMediaUrls = sniffedMediaUrls.filter(m => now - m.timestamp < 7200000).slice(-200);

        if (!sniffedMediaUrls.some(m => normalizeUrl(m.url) === normalizeUrl(url))) {
            const entry = { url, mediaType, frameOrigin: data.frameOrigin || window.location.origin, timestamp: now };
            if (data.mailRuKey) entry.mailRuKey = data.mailRuKey;
            if (data.mailRuTitle) entry.mailRuTitle = data.mailRuTitle;
            sniffedMediaUrls.push(entry);
        }
        
        const targets = getLikelyTargetMediaElements();
        targets.forEach(el => {
            if (!playerUrlMap.has(el)) playerUrlMap.set(el, new Map());
            
            const existingType = playerUrlMap.get(el).get(url);
            if (!existingType || existingType === 'unknown' || mediaType !== 'unknown') {
                playerUrlMap.get(el).set(url, mediaType);
            }
        });
    } else {
        try { window.top.postMessage({ __daisyMedia: { url, mediaType, frameOrigin: window.location.origin } }, "*"); } catch (_) {}
    }
}

window.addEventListener("message", (e) => {
    if (e.data && e.data.__daisyMedia) bubbleMediaToTop(e.data.__daisyMedia);
    if (e.data && e.data.__daisyMediaHeaders) {
        const { url, headers } = e.data.__daisyMediaHeaders;
        if (url && headers && typeof headers === "object") {
            const existing = capturedMediaRequestHeaders.get(url) || {};
            const merged = Object.assign({}, existing, headers);
            capturedMediaRequestHeaders.set(url, merged);
            try {
                _api.runtime.sendMessage({ type: "PUSH_MEDIA_HEADERS", headers: { [url]: headers } }).catch(() => {});
            } catch(err) {}
            // Also register the URL itself as a media candidate
            bubbleMediaToTop({ url, mediaType: 'unknown', frameOrigin: window.location.origin });
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

function getActualYtFormatsAsync() {
    return new Promise(resolve => {
        const timeout = setTimeout(() => {
            window.removeEventListener("message", listener);
            resolve(getActualYtFormats());
        }, 800);

        const listener = (e) => {
            if (e.data && e.data.__daisyYtFormatsResp) {
                clearTimeout(timeout);
                window.removeEventListener("message", listener);
                let formats = new Set(e.data.__daisyYtFormatsResp);
                getActualYtFormats().forEach(h => formats.add(h));
                resolve(Array.from(formats).sort((a, b) => b - a));
            }
        };
        window.addEventListener("message", listener);
        window.postMessage({ __daisyReqYtFormats: true }, "*");
    });
}

function sniffScriptUrls(root) {
    const found = [];
    try {
        const scripts = (root || document).querySelectorAll('script');
        const mediaRe = /(?:https?:)?\/\/[^\s'"\\]+?(?:\.m3u8|\.mp4|\.webm|\.mov|\.ts|\.mpd|\/m3u8|\/hls\/|\/stream\/|\/m3\/|\/dash\/)[^\s'"\\,;}\]))]*/gi;
        for (let s of scripts) {
            const text = s.textContent || "";
            let match;
            while ((match = mediaRe.exec(text)) !== null) {
                let url = match[0].replace(/[,;}\]]+$/, "");
                if (url.startsWith('//')) url = window.location.protocol + url;
                found.push({url: url, type: 'unknown', frameOrigin: window.location.origin});
            }
        }
    } catch(e) {}
    return found;
}

function sniffJsonBlobs(root) {
    const found = [];
    try {
        const scripts = (root || document).querySelectorAll('script[type="application/json"], script#data');
        for (let s of scripts) {
            const text = s.textContent || "";
            const patterns = [
                /["']hlsUrl["']\s*:\s*["'](https?:\/\/[^"']+\.m3u8[^"']*)/g,
                /["']dashUrl["']\s*:\s*["'](https?:\/\/[^"']+\.mpd[^"']*)/g,
                /["'](?:hls_url|hlsUrl|hls|streamUrl|stream_url|playbackUrl|playback_url|videoUrl|video_url|manifestUrl|manifest_url)["']\s*:\s*["'](https?:\/\/[^"']+)/g
            ];
            for (const re of patterns) {
                let m;
                while ((m = re.exec(text)) !== null) found.push({url: m[1], type: 'unknown', frameOrigin: window.location.origin});
            }
        }
    } catch(_) {}
    return found;
}

function sniffWindowState() {
    const found = [];
    try {
        const stateKeys = ['__INITIAL_STATE__', '__REDUX_STATE__', '__DATA__', '__NEXT_DATA__', 'reduxStore', '__APP_STATE__'];
        for (const key of stateKeys) {
            try {
                const val = window[key];
                if (!val) continue;
                const str = typeof val === 'string' ? val : JSON.stringify(val);
                const mediaRe = /https?:\/\/[^\s"'\\]+?(?:\.m3u8|\.mpd|HLSPlaylist\.m3u8|DASHPlaylist\.mpd|\/m3\/|\/dash\/)[^\s"'\\,;}\]))]*/g;
                let m;
                while ((m = mediaRe.exec(str)) !== null) found.push({url: m[0], type: 'unknown', frameOrigin: window.location.origin});
            } catch(_) {}
        }
    } catch(_) {}
    return found;
}

function runScriptSniffer(root) {
    sniffScriptUrls(root).forEach(data => bubbleMediaToTop(data));
    sniffJsonBlobs(root).forEach(data => bubbleMediaToTop(data));
    if (IS_TOP_FRAME) sniffWindowState().forEach(data => bubbleMediaToTop(data));
    if (IS_TOP_FRAME) sniffMailRu(root);
}

// mail.ru / my.mail.ru video support.
async function sniffMailRu(root) {
    try {
        const host = window.location.hostname;
        if (!host.includes('mail.ru')) return;

        let metaUrl = null;

        const cfgScripts = (root || document).querySelectorAll('script.sp-video__page-config, script[class*="page-config"]');
        for (const s of cfgScripts) {
            try {
                const cfg = JSON.parse(s.textContent);
                metaUrl = cfg.metaUrl || (cfg.video && cfg.video.metaUrl);
                if (metaUrl) break;
            } catch (_) {}
        }

        if (!metaUrl) {
            const allScripts = (root || document).querySelectorAll('script:not([src])');
            for (const s of allScripts) {
                const m = s.textContent.match(/"metaUrl"\s*:\s*"(https?:\/\/[^"]+)"/);
                if (m) { metaUrl = m[1]; break; }
            }
        }

        if (!metaUrl) return;

        const res = await new Promise(resolve =>
            _api.runtime.sendMessage({ type: "FETCH_MANIFEST", url: metaUrl }, resolve)
        );
        if (!res || !res.ok) return;

        const data = JSON.parse(res.text);
        const videos = data.videos || [];
        const title = (data.meta && data.meta.title) ? data.meta.title.replace(/\.mp4$/i, '') : null;

        for (const v of videos) {
            if (!v.url) continue;
            bubbleMediaToTop({ url: v.url, mediaType: 'mp4', frameOrigin: window.location.origin, mailRuKey: v.key, mailRuTitle: title });
        }
    } catch (_) {}
}

async function fetchDashQualities(mpdUrl) {
    try {
        const res = await new Promise(resolve => _api.runtime.sendMessage({ type: "FETCH_MANIFEST", url: mpdUrl }, resolve));
        if (!res || !res.ok) throw new Error('fetch failed');
        const text = res.text;
        const parser = new DOMParser();
        const doc = parser.parseFromString(text, 'application/xml');

        let manifestTitle = null;
        const titleEl = doc.querySelector('ProgramInformation Title, MPD Title, title');
        if (titleEl && titleEl.textContent.trim().length > 1) manifestTitle = titleEl.textContent.trim();

        const variants = [];
        const seen = new Set();

        doc.querySelectorAll('AdaptationSet').forEach(adaptSet => {
            const contentType = (adaptSet.getAttribute('contentType') || '').toLowerCase();
            const mimeType    = (adaptSet.getAttribute('mimeType') || '').toLowerCase();

            const combinedType = contentType || mimeType;
            if (combinedType && !combinedType.includes('video')) return;

            const role = adaptSet.querySelector('Role');
            if (role) {
                const roleVal = (role.getAttribute('value') || '').toLowerCase();
                if (roleVal === 'supplemental' || roleVal === 'caption' || roleVal === 'subtitle') return;
            }

            adaptSet.querySelectorAll('Representation').forEach(rep => {
                const repMime = (rep.getAttribute('mimeType') || '').toLowerCase();
                if (repMime && !repMime.includes('video')) return;

                const height    = parseInt(rep.getAttribute('height') || adaptSet.getAttribute('height') || '0');
                const bandwidth = parseInt(rep.getAttribute('bandwidth') || '0');
                const id        = rep.getAttribute('id') || '';

                if (height === 0 && bandwidth === 0) return;

                const key = height > 0 ? `h${height}` : `bw${bandwidth}`;
                if (seen.has(key)) return;
                seen.add(key);

                const label = height > 0
                    ? `${height}p`
                    : bandwidth > 0
                        ? `${Math.round(bandwidth / 1000)}k`
                        : id || "Original";

                variants.push({ label, url: mpdUrl, height, bandwidth, title: manifestTitle });
            });
        });

        if (variants.length === 0) return [{ label: "Original", url: mpdUrl, title: manifestTitle }];

        variants.sort((a, b) => (b.height || b.bandwidth) - (a.height || a.bandwidth));
        return variants;
    } catch (_) {
        return [{ label: "Original", url: mpdUrl, title: null }];
    }
}

async function fetchHlsQualities(masterUrl) {
    try {
        const res = await new Promise(resolve => _api.runtime.sendMessage({ type: "FETCH_MANIFEST", url: masterUrl }, resolve));
        if (!res || !res.ok) throw new Error('fetch failed');
        const text = res.text;

        let manifestTitle = null;
        const titleMatch = text.match(/#EXT-X-SESSION-DATA:[^\n]*DATA-ID="[^"]*title[^"]*"[^\n]*VALUE="([^"]+)"/i)
                        || text.match(/#EXT-X-TITLE:([^\n]+)/i);
        if (titleMatch) manifestTitle = titleMatch[1].trim();

        if (!text.includes('#EXT-X-STREAM-INF')) {
            return [{ label: "Original", url: masterUrl, bandwidth: 0, title: manifestTitle }];
        }

        const variants = [];
        const lines = text.split('\n');
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

            const bwMatch   = line.match(/BANDWIDTH=(\d+)/);
            const resMatch  = line.match(/RESOLUTION=(\d+)x(\d+)/);
            const nameMatch = line.match(/NAME="([^"]+)"/);
            const bandwidth = bwMatch  ? parseInt(bwMatch[1])  : 0;
            const height    = resMatch ? parseInt(resMatch[2]) : 0;

            let variantUrl = '';
            for (let j = i + 1; j < lines.length; j++) {
                const next = lines[j].trim();
                if (next && !next.startsWith('#')) { variantUrl = next; break; }
            }
            if (!variantUrl) continue;

            try { variantUrl = new URL(variantUrl, masterUrl).toString(); } catch (_) {}

            const label = nameMatch ? nameMatch[1]
                        : height    ? `${height}p`
                        : bandwidth ? `${Math.round(bandwidth / 1000)}k`
                        : "Original";

            variants.push({ label, url: variantUrl, bandwidth, height, title: manifestTitle });
        }

        if (variants.length === 0) return [{ label: "Original", url: masterUrl, bandwidth: 0, title: manifestTitle }];

        variants.sort((a, b) => (b.height || b.bandwidth) - (a.height || a.bandwidth));
        return variants;
    } catch (_) {
        return [{ label: "Original", url: masterUrl, bandwidth: 0, title: null }];
    }
}

function collectPageHeaders(mediaUrl = null) {
    const headers = {};
    let realReferer = window.location.href;
    let realOrigin = window.location.origin;

    if (mediaUrl && typeof mediaUrl === 'string' && mediaUrl.startsWith('http')) {
        const sniffed = sniffedMediaUrls.find(m => m.url === mediaUrl || normalizeUrl(m.url) === normalizeUrl(mediaUrl));
        
        if (sniffed && sniffed.frameOrigin && sniffed.frameOrigin !== "null" && sniffed.frameOrigin !== "undefined") {
            realOrigin = sniffed.frameOrigin;
            realReferer = sniffed.frameOrigin + "/";
        } else {
            try {
                const u = new URL(mediaUrl);
                realOrigin = u.origin;
                realReferer = u.origin + "/";
            } catch(e) {}
        }
    }

    headers["referer"] = realReferer;
    headers["origin"] = realOrigin;
    if (navigator.language) headers["accept-language"] = navigator.language;
    headers["user-agent"] = navigator.userAgent;
    Object.assign(headers, collectStorageHeaders());
    return headers;
}

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "FETCH_BLOB")          handleBlob(message.url, message.filename);
  if (message.type === "CREDENTIALED_FETCH")  handleCredentialedFetch(message.url, message.filename);
  if (message.type === 'NEW_MEDIA_FOUND' && message.mediaInfo) bubbleMediaToTop(message.mediaInfo);
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
  
  const mergedPageHeaders = Object.assign({}, collectPageHeaders(url), collectMediaHeaders(url));
  
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
        const payload = JSON.stringify({ url: reader.result.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,"), filename: filename || "download", referer: collectPageHeaders(url)["referer"], ua: navigator.userAgent, cookies: "", pageHeaders: collectPageHeaders(url) });
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

function getContextualVideoName(el) {
    if (!el) return null;
    let label = el.getAttribute('aria-label') || el.getAttribute('title');
    if (label && label.length > 2) return label;
    
    let curr = el;
    for (let i = 0; i < 12 && curr && curr !== document.body; i++) {
        let socialCaption = curr.querySelector('[data-ad-comet-preview="message"], [data-ad-preview="message"], [data-testid="post_message"], ._5pbx, ._1mwp, h1');
        if (socialCaption && socialCaption.innerText) {
            let clean = socialCaption.innerText.trim().split('\n')[0].substring(0, 60);
            if (clean.length > 2) return clean;
        }
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
                    if (v.src) bubbleMediaToTop({url: v.src, mediaType: 'unknown', frameOrigin: window.location.origin});
                    v.querySelectorAll('source').forEach(s => bubbleMediaToTop({url: s.src, mediaType: 'unknown', frameOrigin: window.location.origin}));
                    if (v.currentSrc) bubbleMediaToTop({url: v.currentSrc, mediaType: 'unknown', frameOrigin: window.location.origin});
                };
                report();
                v.addEventListener('loadedmetadata', report, { once: true });
            });
            if (root.querySelectorAll) {
                root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) watchSubframeVideos(el.shadowRoot); });
            }
        }
        const subObs = new MutationObserver(() => { watchSubframeVideos(document); });
        
        // Ensure script sniffers actively run inside subframes (crucial for Reddit embeds)
        if (document.body) {
            subObs.observe(document.body, { childList: true, subtree: true });
            watchSubframeVideos(document);
            runScriptSniffer(document);
            setInterval(() => runScriptSniffer(document), 2000);
        } else {
            document.addEventListener('DOMContentLoaded', () => {
                subObs.observe(document.body, { childList: true, subtree: true });
                watchSubframeVideos(document);
                runScriptSniffer(document);
                setInterval(() => runScriptSniffer(document), 2000);
            });
        }
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
                // We keep the click event to prevent bubbling, but expansion is now handled by hover
            };

            globalOverlay.addEventListener('mouseenter', () => {
                clearTimeout(hideTimeout);
                if (!globalOverlay.classList.contains('expanded')) {
                    globalOverlay.classList.add('expanded');
                    if (currentTarget) populateDropdown(currentTarget, dropdown);
                }
            });
            
            globalOverlay.addEventListener('mouseleave', () => {
                clearTimeout(hideTimeout);
                hideTimeout = setTimeout(() => { globalOverlay.classList.remove('visible', 'expanded'); }, 350);
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
                if (globalOverlay) {
                    clearTimeout(hideTimeout);
                    hideTimeout = setTimeout(() => { globalOverlay.classList.remove('visible', 'expanded'); }, 350);
                }
            });
        }

        async function populateDropdown(targetEl, dropdownEl) {
            dropdownEl.innerHTML = `
                <div class="daisydm-shimmer" style="width:58%"></div>
                <div class="daisydm-shimmer" style="width:72%;margin-top:5px"></div>
                <div class="daisydm-shimmer" style="width:44%;margin-top:5px;margin-bottom:8px"></div>
            `;
            
            console.log('[Daisy] populateDropdown called. sniffedMediaUrls:', JSON.stringify(sniffedMediaUrls.map(m => ({url: m.url, type: m.mediaType}))));
            
            const pageUrl = window.location.href;
            let contextualName = getContextualVideoName(targetEl);
            let _pt = document.title.trim();
            let _ptParts = _pt.split(/\s[-–—|]\s/);
            let pageTitle = (_ptParts.length > 1 ? _ptParts.slice(0, -1).join(' - ') : _pt).trim();
            let vidName = (contextualName || pageTitle || "Video").replace(/[\/:*?"<>|]/g, '').trim() || "Video";

            if (pageUrl.includes('youtube.com')) {
                if (!window.location.pathname.startsWith('/watch') && !window.location.pathname.startsWith('/shorts')) {
                    dropdownEl.innerHTML = '<div class="daisydm-overlay-option" style="color:rgba(40,50,90,0.50);justify-content:center;font-size:12px">No video on this page</div>';
                    return;
                }
                const trueHeights = await getActualYtFormatsAsync();
                dropdownEl.innerHTML = '';
                if (trueHeights.length > 0) {
                    trueHeights.map(h => ({ id: `bestvideo[height<=${h}]+bestaudio/best`, vidName: vidName, quality: `${h}p`, ext: ".mp4" }))
                        .forEach(q => renderOption(dropdownEl, { vidName: q.vidName, quality: q.quality, ext: q.ext, url: pageUrl, ytQuality: q.id, type: 'yt' }));
                } else {
                    renderOption(dropdownEl, { vidName: vidName, quality: "Original", ext: ".mp4", url: pageUrl, ytQuality: "bestvideo+bestaudio/best", type: 'yt' });
                }
                return;
            }

            const urlTypeMap = new Map();
            const mediaNodes = [targetEl, ...Array.from(targetEl.querySelectorAll ? targetEl.querySelectorAll('video, iframe') : [])];
            
            mediaNodes.forEach(v => {
                if (!v) return;
                [v.src, v.currentSrc, ...Array.from(v.querySelectorAll ? v.querySelectorAll('source') : []).map(s => s.src)]
                    .filter(u => u && !u.startsWith('blob:') && !u.startsWith('data:'))
                    .forEach(u => urlTypeMap.set(u, 'unknown'));
                    
                if (playerUrlMap.has(v)) {
                    for (const [u, t] of playerUrlMap.get(v).entries()) urlTypeMap.set(u, t);
                }
            });

            // Ensure we always merge heavily sniffed network files, don't let a dummy blob override
            if (sniffedMediaUrls.length > 0) {
                sniffedMediaUrls.forEach(m => {
                    if (!urlTypeMap.has(m.url)) {
                        urlTypeMap.set(m.url, m.mediaType || 'unknown');
                    }
                });
            }

            const options = [];
            for (const [rawUrl, type] of urlTypeMap.entries()) {
                if (!rawUrl || rawUrl.startsWith('blob:') || rawUrl.startsWith('data:')) continue;
                
                let lower = rawUrl.toLowerCase();
                let finalType = type;
                
                const sniffedEntry = sniffedMediaUrls.find(m => m.url === rawUrl || normalizeUrl(m.url) === normalizeUrl(rawUrl));

                if (finalType === 'unknown' || finalType === 'hls' || finalType === 'dash') {
                    if (lower.includes('.m3u8') || lower.includes('/m3/') || lower.includes('/hls/') || lower.includes('playlist.m3u8') || lower.includes('master.m3u8')) finalType = 'hls';
                    else if (lower.includes('.mpd') || lower.includes('/dash/') || lower.includes('/manifest') || lower.includes('dash.xml') || lower.includes('dashplaylist') || lower.includes('video.ism')) finalType = 'dash';
                    else if (lower.includes('.mp4')) finalType = 'mp4';
                }

                if (finalType === 'unknown' && sniffedEntry && sniffedEntry.mediaType && sniffedEntry.mediaType !== 'unknown') {
                    finalType = sniffedEntry.mediaType;
                }
                
                const isManifest = (finalType === 'hls' || finalType === 'dash');
                
                if (!isManifest && finalType !== 'mp4') {
                    const spamSigs = ['.ts', '.m4s', '.m4v', '.m4a', 'bytestart=', 'segment', 'frag', 'init.mp4', 'seg-'];
                    const fakeExts = ['.woff', '.css', '.js', '.html', '.png', '.jpg'];
                    
                    if (spamSigs.some(s => lower.includes(s))) continue;
                    if (fakeExts.some(e => lower.includes(e))) continue;
                }
                
                const siteQuality = sniffedEntry && sniffedEntry.mailRuKey ? sniffedEntry.mailRuKey : null;
                const siteTitle   = sniffedEntry && sniffedEntry.mailRuTitle ? sniffedEntry.mailRuTitle : null;
                
                if (finalType === 'hls') {
                    const variants = await fetchHlsQualities(rawUrl);
                    variants.forEach(v => options.push({ vidName: siteTitle || v.title || vidName, quality: v.label, ext: '.mp4', url: v.url, type: 'hls' }));
                } else if (finalType === 'dash') {
                    const variants = await fetchDashQualities(rawUrl);
                    variants.forEach(v => {
                        options.push({ vidName: siteTitle || v.title || vidName, quality: v.label, ext: '.mp4', url: v.url, type: 'dash', ytQuality: v.ytQuality });
                    });
                } else {
                    options.push({ vidName: siteTitle || vidName, quality: siteQuality || '', ext: getExtFromUrl(rawUrl), url: rawUrl, type: 'mp4' });
                }
            }

            dropdownEl.innerHTML = '';
            if (options.length === 0) {
                if (globalOverlay) globalOverlay.classList.remove('visible', 'expanded');
                if (typeof dismissedEls !== "undefined" && targetEl) dismissedEls.add(targetEl);
                return;
            }
            
            const seenOptions = new Set();
            options.forEach(opt => {
                const uid = `${opt.quality}-${opt.type}-${opt.url}`;
                if (!seenOptions.has(uid)) {
                    seenOptions.add(uid);
                    renderOption(dropdownEl, opt);
                }
            });
        }

        function renderOption(dropdownEl, opt) {
            let typeLabel = (opt.type || 'MP4').toUpperCase(), badgeClass = `daisydm-badge ${(opt.type || 'mp4').toLowerCase()}`;
            if (opt.ytQuality && opt.type !== 'dash') { typeLabel = 'DASH'; badgeClass = 'daisydm-badge yt'; }
            else if (opt.type === 'dash') { typeLabel = 'DASH'; badgeClass = 'daisydm-badge dash'; }
            else if (opt.type === 'hls') { typeLabel = 'HLS'; badgeClass = 'daisydm-badge hls'; }
            else if (opt.type === 'yt') { typeLabel = 'DASH'; badgeClass = 'daisydm-badge yt'; }

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
                const r = el.getBoundingClientRect();
                // We no longer restrict by src for iframes.
                // If it's big enough to be a player, we attach to it.
                // \`hasDownloadableMedia\` will verify if it contains sniffed URLs.
                if (r.width > 150 && r.height > 100) attachToElement(el);
            });
        }

        const observer = new MutationObserver(() => { scanForMedia(); });
        observer.observe(document.body, { childList: true, subtree: true });
        setInterval(() => { scanForMedia(); }, 2000);
        scanForMedia();
    }
    // --- MAGNET LINK INTERCEPTOR ---
    document.addEventListener('click', (e) => {
        // Find the closest anchor tag that was clicked
        const a = e.target.closest('a');
        
        // Check if it's a magnet link
        if (a && a.href && a.href.toLowerCase().startsWith('magnet:')) {
            // Obey user's bypass key (e.g., holding Alt to skip extension)
            if (shouldBypass()) return;
            
            // Stop Safari/Chrome from trying to open the native OS prompt
            e.preventDefault();
            e.stopPropagation();
            
            // Send directly to DaisyDM
            sendToDispatch(a.href, "Torrent Download");
        }
    }, { capture: true });
    init();
})();

// background.js - Daisy Chrome Extension

const _api = typeof browser !== "undefined" ? browser : chrome;

let dispatchEnabled = true;
let bypassGraceUntil = 0;

const capturedRequestHeaders  = new Map();
const capturedResponseHeaders = new Map();
const capturedCookies         = new Map();
const headerCacheTimestamps   = new Map();
const HEADER_CACHE_TTL_MS     = 5 * 60 * 1000;

// IDM-style: as the YouTube player makes range requests against
// googlevideo.com, we lift the fully-resolved (signature-decrypted +
// n-cipher decoded) URLs straight off the wire. The browser's own player
// JS does all the cryptography; we just listen.
//
// Keyed by tabId. Per-tab we track the current videoId (parsed from the
// tab's watch URL — SPA navigations within the same tab reset the format
// map) and the per-itag URL most recently observed.
//
//   capturedYtFormats[tabId] = {
//     videoId: "abc123",
//     formats: Map<itag, { url, mime, contentLength, lastSeen }>
//   }
const capturedYtFormats = new Map();
const YT_URL_TTL_MS = 15 * 60 * 1000;

function ytVideoIdFromUrl(href) {
    if (!href) return null;
    try {
        const u = new URL(href);
        if (!/(?:^|\.)youtube\.com$/.test(u.hostname) && !/(?:^|\.)youtu\.be$/.test(u.hostname)) return null;
        // /watch?v=ID
        const v = u.searchParams.get("v");
        if (v && /^[\w-]{6,}$/.test(v)) return v;
        // /shorts/ID, /embed/ID, /live/ID, youtu.be/ID
        const m = u.pathname.match(/^\/(?:shorts|embed|live|v)\/([\w-]{6,})/) || (u.hostname === "youtu.be" ? u.pathname.match(/^\/([\w-]{6,})/) : null);
        if (m) return m[1];
    } catch (_) {}
    return null;
}

function recordYtFormat(tabId, videoId, info) {
    if (!Number.isFinite(tabId) || tabId < 0 || !videoId || !info || !info.itag) return;
    let bucket = capturedYtFormats.get(tabId);
    if (!bucket || bucket.videoId !== videoId) {
        // SPA navigation to a different video — reset the format map for
        // this tab so we don't mix up old URLs with new ones.
        bucket = { videoId, formats: new Map() };
        capturedYtFormats.set(tabId, bucket);
    }
    bucket.formats.set(info.itag, {
        url: info.url,
        mime: info.mime || null,
        contentLength: info.contentLength || null,
        lastSeen: Date.now()
    });
}

function getYtFormatsFor(tabId, videoId) {
    const bucket = capturedYtFormats.get(tabId);
    if (!bucket) return [];
    if (videoId && bucket.videoId !== videoId) return [];
    const now = Date.now();
    const out = [];
    for (const [itag, entry] of bucket.formats.entries()) {
        if (now - entry.lastSeen > YT_URL_TTL_MS) continue;
        out.push({ itag, ...entry });
    }
    return out;
}

// googlevideo URLs include itag as a query param. We want every variant —
// video itags, audio itags, even fmt 18 (combined) when the player chooses
// it. The URL pattern is fairly stable: /videoplayback?...&itag=N&...
function parseGoogleVideoUrl(href) {
    try {
        const u = new URL(href);
        if (!/(?:^|\.)googlevideo\.com$/.test(u.hostname)) return null;
        if (!u.pathname.includes("/videoplayback")) return null;
        const itag = parseInt(u.searchParams.get("itag") || "", 10);
        if (!Number.isFinite(itag)) return null;
        const mime = u.searchParams.get("mime") || null;
        const contentLength = u.searchParams.get("clen") || null;
        return { itag, mime, contentLength };
    } catch (_) {
        return null;
    }
}

function storeWithTTL(map, key, value) {
    if (!key) return;
    map.set(key, value);
    headerCacheTimestamps.set(key, Date.now());
    for (const [k, ts] of headerCacheTimestamps) {
        if (Date.now() - ts > HEADER_CACHE_TTL_MS) {
            capturedRequestHeaders.delete(k);
            capturedResponseHeaders.delete(k);
            capturedCookies.delete(k);
            headerCacheTimestamps.delete(k);
        }
    }
}

function findCapturedDataAggressive(map, targetUrl) {
    let merged = {};
    if (!targetUrl) return merged;
    
    try {
        const tUrl = new URL(targetUrl);
        const tPath = tUrl.pathname;
        const tBase = tUrl.origin + tPath;

        for (const [key, val] of map.entries()) {
            try {
                const kUrl = new URL(key);
                if (kUrl.hostname === tUrl.hostname || kUrl.hostname.includes(tUrl.hostname) || tUrl.hostname.includes(kUrl.hostname)) {
                    if (key === targetUrl || key === tBase || tUrl.origin === key || kUrl.origin === targetUrl) {
                        Object.assign(merged, val);
                    } else if (tPath.length > 5 && (key.includes(tPath) || targetUrl.includes(key))) {
                        Object.assign(merged, val);
                    }
                }
            } catch(e) {}
        }
    } catch(e) {
        if (map.has(targetUrl)) Object.assign(merged, map.get(targetUrl));
    }
    return merged;
}

function findCapturedCookieAggressive(targetUrl) {
    if (!targetUrl) return "";
    if (capturedCookies.has(targetUrl)) return capturedCookies.get(targetUrl);
    try {
        const u = new URL(targetUrl);
        if (capturedCookies.has(u.origin)) return capturedCookies.get(u.origin);
        for (const [key, val] of capturedCookies.entries()) {
            if (key.includes(u.hostname)) return val;
        }
    } catch(e) {}
    return "";
}

_api.storage.local.get(["dispatchEnabled"]).then(res => {
    if (typeof res.dispatchEnabled === "boolean") dispatchEnabled = res.dispatchEnabled;
});

_api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.dispatchEnabled) {
        dispatchEnabled = changes.dispatchEnabled.newValue;
        fetch(`http://127.0.0.1:6840/setenabled`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ enabled: changes.dispatchEnabled.newValue })
        }).catch(() => {});
    }
});

_api.runtime.onInstalled.addListener(() => {
    _api.contextMenus.create({
        id: "dispatch-download",
        title: "Download with Daisy",
        contexts: ["link", "selection", "video", "audio"]
    });
});

_api.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "dispatch-download") {
        const targetUrl = info.linkUrl || info.srcUrl || info.selectionText;
        if (targetUrl) {
            triggerDownload(targetUrl, extractFilename(targetUrl), tab?.url || "");
        }
    }
});

function extractFilename(url) {
    try {
        const parts = new URL(url).pathname.split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "download";
    } catch { return "download"; }
}

function formatNetscapeCookies(cookies) {
    let output = "# Netscape HTTP Cookie File\n# Generated by Daisy\n\n";
    const unique = new Map();
    for (const c of cookies) unique.set(`${c.domain}:${c.name}`, c);
    for (const c of unique.values()) {
        const includeSubdoms = c.domain.startsWith('.') ? "TRUE" : "FALSE";
        const secure         = c.secure ? "TRUE" : "FALSE";
        const expiration     = c.expirationDate ? Math.round(c.expirationDate) : Math.round(Date.now() / 1000) + 3600;
        output += `${c.domain}\t${includeSubdoms}\t${c.path}\t${secure}\t${expiration}\t${c.name}\t${c.value}\n`;
    }
    return output;
}

async function fetchBaseDomainCookies(targetUrl) {
    return new Promise(resolve => {
        try {
            const urlObj     = new URL(targetUrl);
            const hostParts  = urlObj.hostname.split('.');
            const baseDomain = hostParts.length > 2 ? hostParts.slice(-2).join('.') : urlObj.hostname;
            _api.cookies.getAll({ domain: baseDomain }, cookies => {
                resolve(cookies && cookies.length > 0 ? formatNetscapeCookies(cookies) : "");
            });
        } catch { resolve(""); }
    });
}

async function getYouTubeAuthCookies() {
    return new Promise(resolve => {
        _api.cookies.getAll({ domain: "youtube.com" }, yt => {
            _api.cookies.getAll({ domain: "google.com" }, gl => { resolve([...(yt || []), ...(gl || [])]); });
        });
    });
}

const reqExtraInfo = ["requestHeaders"];
if (_api.webRequest && _api.webRequest.OnBeforeSendHeadersOptions && _api.webRequest.OnBeforeSendHeadersOptions.hasOwnProperty('EXTRA_HEADERS')) {
    reqExtraInfo.push("extraHeaders");
}

_api.webRequest.onBeforeSendHeaders.addListener(
    function(details) {
        const reqHeaders = {};
        for (const h of (details.requestHeaders || [])) reqHeaders[h.name.toLowerCase()] = h.value;
        
        storeWithTTL(capturedRequestHeaders, details.url, reqHeaders);
        try {
            const u = new URL(details.url);
            storeWithTTL(capturedRequestHeaders, u.origin + u.pathname, reqHeaders);
            storeWithTTL(capturedRequestHeaders, u.origin, reqHeaders);
        } catch(_) {}

        fetchBaseDomainCookies(details.url).then(cookieStr => {
            if (cookieStr) storeWithTTL(capturedCookies, details.url, cookieStr);
        });
    },
    { urls: ["<all_urls>"] },
    reqExtraInfo
);

// IDM-style googlevideo URL capture. The YouTube player generates fully
// resolved (signature-decrypted, n-cipher decoded) URLs and fires range
// requests against googlevideo.com to fetch chunks. We intercept those
// URLs and stash them per-tab so the popup can offer them as direct
// download options without going through InnerTube at all.
_api.webRequest.onBeforeRequest.addListener(
    function(details) {
        if (details.tabId < 0) return;
        const parsed = parseGoogleVideoUrl(details.url);
        if (!parsed) return;
        try {
            _api.tabs.get(details.tabId, (tab) => {
                if (_api.runtime.lastError) return;
                const vid =
                    ytVideoIdFromUrl(tab && tab.url) ||
                    ytVideoIdFromUrl(details.documentUrl) ||
                    ytVideoIdFromUrl(details.initiator);
                if (!vid) return;
                recordYtFormat(details.tabId, vid, { itag: parsed.itag, url: details.url, mime: parsed.mime, contentLength: parsed.contentLength });
            });
        } catch (_) {}
    },
    { urls: ["*://*.googlevideo.com/videoplayback*"] }
);

const resExtraInfo = ["responseHeaders"];
if (_api.webRequest && _api.webRequest.OnHeadersReceivedOptions && _api.webRequest.OnHeadersReceivedOptions.hasOwnProperty('EXTRA_HEADERS')) {
    resExtraInfo.push("extraHeaders");
}

_api.webRequest.onHeadersReceived.addListener(
    function(details) {
        const respHeaders = {};
        for (const h of (details.responseHeaders || [])) respHeaders[h.name.toLowerCase()] = h.value;
        
        storeWithTTL(capturedResponseHeaders, details.url, respHeaders);
        try {
            const u = new URL(details.url);
            storeWithTTL(capturedResponseHeaders, u.origin + u.pathname, respHeaders);
            storeWithTTL(capturedResponseHeaders, u.origin, respHeaders);
        } catch(_) {}

        const ct = respHeaders["content-type"] || "";
        const isMedia = ["video/", "audio/", "mpegurl", "m3u8", "video/mp2t", "application/x-mpegurl", "application/vnd.apple.mpegurl", "application/dash+xml", "application/xml", "text/xml"].some(m => ct.includes(m));
        const urlLower = details.url.toLowerCase();
        const isMediaByUrl = ['.m3u8', '.ts', '.mp4', '.webm', '.mov', '.mkv', '/hls/', '/m3u8', 'manifest.m3u8', 'master.m3u8', '.mpd', '/dash/', 'dashplaylist', 'dash.xml', '/manifest', 'video.ism', 'application/dash', '/stream/', 'playlist', 'quality=', 'bitrate=', 'resolution='].some(p => urlLower.includes(p));

        if ((isMedia || isMediaByUrl) && details.tabId !== -1) {
            _api.tabs.sendMessage(details.tabId, { type: 'NEW_MEDIA_FOUND', mediaInfo: { url: details.url, frameId: details.frameId } }, { frameId: 0 }).catch(() => {});
            if (details.frameId !== 0) {
                _api.tabs.sendMessage(details.tabId, { type: 'NEW_MEDIA_FOUND', mediaInfo: { url: details.url, frameId: details.frameId } }, { frameId: details.frameId }).catch(() => {});
            }
        }
    },
    { urls: ["<all_urls>"] },
    resExtraInfo
);

// --- NATIVE CHROME DOWNLOAD INTERCEPTOR ---
if (typeof chrome !== 'undefined' && chrome.downloads) {
    chrome.downloads.onCreated.addListener((item) => {
        if (!dispatchEnabled) return;
        
        if (Date.now() < bypassGraceUntil) {
            // Consume the token so we don't permanently break standard intercepts for 60s
            bypassGraceUntil = 0;
            return; // LET BROWSER HANDLE IT
        }
        
        if (item.url.startsWith("blob:") || item.url.startsWith("data:")) return;

        chrome.downloads.cancel(item.id, () => {
            chrome.downloads.erase({id: item.id}, () => {});
            triggerDownload(item.url, item.filename, item.referrer || "", null, null, false, false, {}, null, null, null);
        });
    });
}

_api.runtime.onMessage.addListener((message, sender, sendResponse) => {

    if (message.type === "SET_BYPASS_GRACE") {
        bypassGraceUntil = Date.now() + 60000; // 60 seconds
        sendResponse({ ok: true });
        return true;
    }

    if (message.type === "PUSH_MEDIA_HEADERS") {
        if (message.headers && typeof message.headers === "object") {
            for (const [url, headers] of Object.entries(message.headers)) {
                if (!url || typeof headers !== "object") continue;
                const existing = capturedRequestHeaders.get(url) || {};
                const merged = Object.assign({}, headers, existing);
                storeWithTTL(capturedRequestHeaders, url, merged);
                try {
                    const u = new URL(url);
                    storeWithTTL(capturedRequestHeaders, u.origin + u.pathname, Object.assign({}, headers, capturedRequestHeaders.get(u.origin + u.pathname) || {}));
                    storeWithTTL(capturedRequestHeaders, u.origin, Object.assign({}, headers, capturedRequestHeaders.get(u.origin) || {}));
                } catch(_) {}
            }
        }
        sendResponse({ ok: true });
        return true;
    }

    if (message.type === "FETCH_MANIFEST") {
        const reqHeaders = findCapturedDataAggressive(capturedRequestHeaders, message.url);
        fetch(message.url, { headers: reqHeaders })
            .then(r => r.text())
            .then(text => sendResponse({ ok: true, text: text }))
            .catch(e => sendResponse({ ok: false }));
        return true;
    }

    // Content script asks "what googlevideo URLs have you captured for this
    // tab + videoId?". Used by the popup to build the quality list from
    // the URLs the YouTube player has already resolved, instead of going
    // back through InnerTube.
    if (message.type === "GET_YT_CAPTURED_FORMATS") {
        const tabId = sender && sender.tab && sender.tab.id;
        const formats = (typeof tabId === "number" && tabId >= 0)
            ? getYtFormatsFor(tabId, message.videoId || null)
            : [];
        sendResponse({ ok: true, formats });
        return true;
    }

    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        const pageUrl = sender.tab?.url || message.url || "";
        const finish = async () => {
            if (pageUrl.includes("youtube.com") || pageUrl.includes("youtu.be")) {
                const cookies = await getYouTubeAuthCookies();
                let cookiePayload = "";
                if (cookies && cookies.length > 0) {
                    cookiePayload = formatNetscapeCookies(cookies);
                    console.log(`[Daisy] YouTube dispatch: ${cookies.length} cookies via chrome.cookies API`);
                } else if (message.cookies && message.cookies.length > 0) {
                    cookiePayload = message.cookies;
                    console.log(`[Daisy] YouTube dispatch: ${message.cookies.split(";").length} cookies from document.cookie`);
                } else {
                    console.warn("[Daisy] YouTube dispatch: no cookies available — request will likely hit the bot challenge");
                }
                await triggerDownload(message.url, message.filename, sender.tab?.url || "", cookiePayload, message.youtubeQuality, message.forceHLS, message.forceDASH, message.pageHeaders || {}, message.ytPoToken || null, message.ytPoTokenVisitor || null, {
                    videoUrl: message.ytVideoUrl || null,
                    audioUrl: message.ytAudioUrl || null,
                    videoMime: message.ytVideoMime || null,
                    audioMime: message.ytAudioMime || null,
                    height: message.ytHeight || null,
                    title: message.ytTitle || null
                });
            } else {
                let cookiePayload = findCapturedCookieAggressive(message.url);
                if (!cookiePayload && pageUrl.startsWith("http")) cookiePayload = await fetchBaseDomainCookies(pageUrl);
                if (!cookiePayload) cookiePayload = message.cookies || "";
                await triggerDownload(message.url, message.filename, sender.tab?.url || "", cookiePayload, message.youtubeQuality, message.forceHLS, message.forceDASH, message.pageHeaders || {}, null, null, null);
            }
        };

        finish().then(() => sendResponse({ success: true })).catch((e) => sendResponse({ success: false }));
        return true;
    }
});

async function triggerDownload(url, filename, referer, cookies, youtubeQuality, forceHLS, forceDASH, pageHeaders, ytPoToken, ytPoTokenVisitor, ytPreResolved) {
    let finalCookies = cookies;
    if (!finalCookies) finalCookies = findCapturedCookieAggressive(url) || await fetchBaseDomainCookies(referer || url);
    
    // Send full merged headers to the download app
    const reqHeaders  = findCapturedDataAggressive(capturedRequestHeaders, url);
    const respHeaders = findCapturedDataAggressive(capturedResponseHeaders, url);
    
    const mergedHeaders = Object.assign({}, pageHeaders || {}, reqHeaders);
    if (referer && !mergedHeaders["referer"]) mergedHeaders["referer"] = referer;

    const payload = JSON.stringify({
        url, filename: filename || "download", cookies: finalCookies || "", referer: referer || "",
        ua: navigator.userAgent, browser: "chrome", youtubeQuality, forceHLS, forceDASH,
        ytPoToken: ytPoToken || null,
        ytPoTokenVisitor: ytPoTokenVisitor || null,
        // IDM-style: when the popup picked a quality whose URLs we already
        // captured off the wire, we ship the resolved URLs directly. The
        // Swift side skips the InnerTube extractor and goes straight to
        // aria2c + ffmpeg merge.
        ytVideoUrl: (ytPreResolved && ytPreResolved.videoUrl) || null,
        ytAudioUrl: (ytPreResolved && ytPreResolved.audioUrl) || null,
        ytVideoMime: (ytPreResolved && ytPreResolved.videoMime) || null,
        ytAudioMime: (ytPreResolved && ytPreResolved.audioMime) || null,
        ytHeight: (ytPreResolved && ytPreResolved.height) || null,
        ytTitle: (ytPreResolved && ytPreResolved.title) || null,
        headers: mergedHeaders,
        requestHeaders: mergedHeaders,
        responseHeaders: respHeaders,
        extraHeadersFlat: Object.entries(mergedHeaders).map(([k, v]) => `${k}: ${v}`).join("\n")
    });

    for (let port = 6840; port <= 6850; port++) {
        try {
            const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
            if (resp.ok) break;
        } catch (e) {}
    }
}

// inject.js
(function() {
    const MEDIA_RE = /\.m3u8|stream\.mpd|\.mpd|dash|hls|\.mp4|\.webm|\.mov|\.ts|manifest/i;

    // YouTube format listener — runs in page context.
    // Harvests heights from every player API surface we can reach. We keep
    // retrying briefly so that a hover landing during YouTube's player init
    // (right after an SPA navigation) still returns the full quality set
    // instead of forcing the user to hard-refresh.
    const YT_QUALITY_LEVEL_HEIGHTS = {
        highres: 4320, hd2880: 2880, hd2160: 2160, hd1440: 1440,
        hd1080: 1080, hd720: 720, large: 480, medium: 360, small: 240, tiny: 144
    };

    function harvestYouTube() {
        const heights = new Set();
        let title = null;
        let author = null;
        let videoId = null;
        const addH = (h) => {
            if (typeof h !== 'number' || !isFinite(h)) return;
            if (h >= 144 && h <= 4320) heights.add(h);
        };
        const addFromLabel = (label) => {
            if (!label) return;
            const m = String(label).match(/(\d+)\s*p/i);
            if (m) addH(parseInt(m[1], 10));
        };
        const addFromFormatsArray = (arr) => {
            if (!Array.isArray(arr)) return;
            arr.forEach(f => {
                if (!f) return;
                if (typeof f.height === 'number') addH(f.height);
                else if (f.qualityLabel) addFromLabel(f.qualityLabel);
            });
        };
        const captureMeta = (resp) => {
            if (!resp || !resp.videoDetails) return;
            const d = resp.videoDetails;
            if (!title && d.title) title = String(d.title);
            if (!author && d.author) author = String(d.author);
            if (!videoId && d.videoId) videoId = String(d.videoId);
        };

        try {
            const player = document.querySelector('#movie_player') || document.getElementById('movie_player');
            if (player) {
                try {
                    if (typeof player.getAvailableQualityData === 'function') {
                        const data = player.getAvailableQualityData();
                        if (Array.isArray(data)) data.forEach(q => q && addFromLabel(q.qualityLabel));
                    }
                } catch (_) {}
                try {
                    if (typeof player.getAvailableQualityLevels === 'function') {
                        const levels = player.getAvailableQualityLevels();
                        if (Array.isArray(levels)) levels.forEach(l => {
                            if (YT_QUALITY_LEVEL_HEIGHTS[l]) addH(YT_QUALITY_LEVEL_HEIGHTS[l]);
                        });
                    }
                } catch (_) {}
                try {
                    if (typeof player.getPlayerResponse === 'function') {
                        const resp = player.getPlayerResponse();
                        if (resp && resp.streamingData) {
                            addFromFormatsArray(resp.streamingData.formats);
                            addFromFormatsArray(resp.streamingData.adaptiveFormats);
                        }
                        captureMeta(resp);
                    }
                } catch (_) {}
                // Player exposes the title directly on the element on most
                // modern YouTube layouts.
                try {
                    if (!title && typeof player.getVideoData === 'function') {
                        const vd = player.getVideoData();
                        if (vd && vd.title) title = String(vd.title);
                        if (vd && vd.author && !author) author = String(vd.author);
                        if (vd && vd.video_id && !videoId) videoId = String(vd.video_id);
                    }
                } catch (_) {}
            }
        } catch (_) {}

        // ytInitialPlayerResponse: can be stale across SPA navigations, but
        // is still our most reliable title fallback for fresh page loads.
        try {
            const initial = window.ytInitialPlayerResponse;
            if (initial) {
                if (initial.streamingData) {
                    addFromFormatsArray(initial.streamingData.formats);
                    addFromFormatsArray(initial.streamingData.adaptiveFormats);
                }
                captureMeta(initial);
            }
        } catch (_) {}

        return { heights, title, author, videoId };
    }

    window.addEventListener("message", (e) => {
        if (!e.data || !e.data.__daisyReqYtFormats) return;
        // Accumulate heights across short retries so partial early reads
        // (e.g. only ytInitialPlayerResponse before #movie_player exposes its
        // API after an SPA navigation) get merged with the full read once
        // the new player finishes initializing.
        const startedAt = Date.now();
        const maxWaitMs = 1500;
        const intervalMs = 150;
        const completeEnough = 4;
        const cumulative = new Set();
        let cumulativeTitle = null;
        let cumulativeAuthor = null;
        let cumulativeVideoId = null;

        const attempt = () => {
            const { heights, title, author, videoId } = harvestYouTube();
            heights.forEach(h => cumulative.add(h));
            if (!cumulativeTitle && title) cumulativeTitle = title;
            if (!cumulativeAuthor && author) cumulativeAuthor = author;
            if (!cumulativeVideoId && videoId) cumulativeVideoId = videoId;
            const elapsed = Date.now() - startedAt;
            const done = cumulative.size >= completeEnough || elapsed > maxWaitMs;
            if (done) {
                window.postMessage({
                    __daisyYtFormatsResp: Array.from(cumulative),
                    __daisyYtTitle: cumulativeTitle,
                    __daisyYtAuthor: cumulativeAuthor,
                    __daisyYtVideoId: cumulativeVideoId
                }, "*");
                return;
            }
            setTimeout(attempt, intervalMs);
        };
        attempt();
    });

    // Peek at YouTube's own outgoing player API requests so we can lift
    // the proof-of-origin token (PO Token) the real player generated for
    // the current video. Without this token, YouTube blocks server-side
    // InnerTube calls at the "Sign in to confirm you're not a bot" gate
    // even with a logged-in cookie session.
    function maybeCapturePoToken(url, body) {
        try {
            if (!url || !body) return;
            // Match any youtubei/v1 endpoint; YouTube has shifted token-bearing
            // payloads between /player, /next, /reel/reel_item_watch, etc.
            // We accept any of them — the videoId + poToken pair is what we
            // care about, the endpoint is incidental.
            if (!url.includes("/youtubei/v1/")) return;
            try { console.log("[Daisy] yt-fetch", url.split("?")[0]); } catch (_) {}
            const text = typeof body === "string"
                ? body
                : (body && typeof body.toString === "function" ? body.toString() : null);
            if (!text || text[0] !== "{") return;
            const json = JSON.parse(text);
            // YouTube has used several names for this; check all known ones.
            const dims = json.serviceIntegrityDimensions
                       || json.serviceIntegrity
                       || (json.context && json.context.serviceIntegrityDimensions);
            let pot = dims && (dims.poToken || dims.po_token || dims.token);
            // Fallback: deep-scan for a poToken anywhere in the body.
            if (!pot) {
                const m = text.match(/"poToken"\s*:\s*"([^"]+)"/);
                if (m) pot = m[1];
            }
            const vid = json.videoId
                     || (json.playbackContext && json.playbackContext.contentPlaybackContext && json.playbackContext.contentPlaybackContext.currentUrl && (json.playbackContext.contentPlaybackContext.currentUrl.match(/[?&]v=([\w-]{6,})/) || [])[1])
                     || null;
            const vd = json.context && json.context.client && json.context.client.visitorData;
            if (pot && vid) {
                window.postMessage({ __daisyYtPoToken: pot, __daisyYtPoTokenVideoId: vid, __daisyYtPoTokenVisitor: vd || null }, "*");
                try { console.log("[Daisy] captured poToken for videoId", vid, "len=" + pot.length); } catch (_) {}
            } else if (url.includes("/youtubei/v1/player")) {
                try { console.log("[Daisy] /player body had no poToken; keys:", Object.keys(json).join(",")); } catch (_) {}
            }
        } catch (e) {
            try { console.log("[Daisy] poToken capture parse error", e && e.message); } catch (_) {}
        }
    }

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
        // Try opts.body first (string/FormData), then clone the Request body
        // if YouTube passed a Request object. Request bodies can only be read
        // once, so we always clone() to avoid breaking the actual fetch.
        if (url.includes("/youtubei/v1/player")) {
            if (opts.body) {
                try { maybeCapturePoToken(url, opts.body); } catch (_) {}
            } else if (req instanceof Request) {
                try {
                    req.clone().text().then((txt) => {
                        if (txt) maybeCapturePoToken(url, txt);
                    }).catch(() => {});
                } catch (_) {}
            }
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
                if (args && args[0]) maybeCapturePoToken(absoluteUrl, args[0]);
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

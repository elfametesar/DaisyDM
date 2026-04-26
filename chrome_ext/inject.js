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

    function harvestYouTubeHeights() {
        const heights = new Set();
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
                    }
                } catch (_) {}
            }
        } catch (_) {}

        // Trust ytInitialPlayerResponse unconditionally. It can be stale after
        // an SPA navigation (still pointing at the previous video), but
        // yt-dlp gracefully degrades with `bestvideo[height<=N]+bestaudio/best`
        // when N isn't available — so it's much better to surface *some*
        // height options than to fall through to a single "Original" entry.
        try {
            const initial = window.ytInitialPlayerResponse;
            if (initial && initial.streamingData) {
                addFromFormatsArray(initial.streamingData.formats);
                addFromFormatsArray(initial.streamingData.adaptiveFormats);
            }
        } catch (_) {}

        return heights;
    }

    window.addEventListener("message", (e) => {
        if (!e.data || !e.data.__daisyReqYtFormats) return;
        // Accumulate heights across short retries so partial early reads
        // (e.g. only ytInitialPlayerResponse before #movie_player exposes its
        // API after an SPA navigation) get merged with the full read once
        // the new player finishes initializing. We ship early once we have
        // a reasonably complete list to keep the popup snappy, but if we're
        // stuck at zero we keep trying until the timeout.
        const startedAt = Date.now();
        const maxWaitMs = 1500;
        const intervalMs = 150;
        const completeEnough = 4; // most YouTube videos expose >=4 distinct heights
        const cumulative = new Set();

        const attempt = () => {
            harvestYouTubeHeights().forEach(h => cumulative.add(h));
            const elapsed = Date.now() - startedAt;
            const done = cumulative.size >= completeEnough || elapsed > maxWaitMs;
            if (done) {
                window.postMessage({ __daisyYtFormatsResp: Array.from(cumulative) }, "*");
                return;
            }
            setTimeout(attempt, intervalMs);
        };
        attempt();
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

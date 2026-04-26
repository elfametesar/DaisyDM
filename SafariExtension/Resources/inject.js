// inject.js
(function() {
    const MEDIA_RE = /\.m3u8|stream\.mpd|\.mpd|dash|hls|\.mp4|\.webm|\.mov|\.ts|manifest/i;
    const OBVIOUS_DOWNLOAD_RE = /\.mp4|\.mkv|\.avi|\.webm|\.mov|\.wmv|\.flv|\.ts|\.m3u8|\.mpd|\.zip|\.rar|\.pdf|\.dmg|\.iso|\.pkg|\.tar|\.gz|\.bin/i;
    const DOWNLOAD_PATH_RE = /\/download\/|\?download=/i;

    function isObviousDownload(urlStr) {
        if (!urlStr) return false;
        try {
            const url = new URL(urlStr, document.baseURI);
            return OBVIOUS_DOWNLOAD_RE.test(url.pathname) || DOWNLOAD_PATH_RE.test(url.href);
        } catch {
            return OBVIOUS_DOWNLOAD_RE.test(urlStr) || DOWNLOAD_PATH_RE.test(urlStr);
        }
    }

    // 1. Trap Blob Destruction (Prevents sites from deleting the file before we intercept it)
    const originalRevokeObjectURL = URL.revokeObjectURL;
    URL.revokeObjectURL = function(url) {
        setTimeout(() => {
            try { originalRevokeObjectURL.call(this, url); } catch(e) {}
        }, 45000); // Force blobs to stay alive for 45 seconds so Daisy can capture them
    };

    // 2. Trap Native Anchor Clicks
    const originalAnchorClick = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function() {
        if (this.hasAttribute('download') || this.href.startsWith('blob:') || isObviousDownload(this.href) || this.dataset.daisyDownload === "true") {
            window.postMessage({
                __daisyTriggerDownload: this.href,
                __daisyFilename: this.getAttribute('download') || this.dataset.daisyFilename || ''
            }, "*");
            return;
        }
        return originalAnchorClick.call(this);
    };

    // 3. Trap Synthetic/Dispatched Click Events (React/Vue/Angular invisible links)
    const originalDispatchEvent = EventTarget.prototype.dispatchEvent;
    EventTarget.prototype.dispatchEvent = function(event) {
        if (event && event.type === 'click' && this instanceof HTMLAnchorElement) {
            if (this.hasAttribute('download') || this.href.startsWith('blob:') || isObviousDownload(this.href) || this.dataset.daisyDownload === "true") {
                window.postMessage({
                    __daisyTriggerDownload: this.href,
                    __daisyFilename: this.getAttribute('download') || this.dataset.daisyFilename || ''
                }, "*");
                return false;
            }
        }
        return originalDispatchEvent.apply(this, arguments);
    };

    // 4. Trap Direct location.href Navigation (The Gofile.io method)
    const locDesc = Object.getOwnPropertyDescriptor(window.Location.prototype, 'href');
    if (locDesc && locDesc.set) {
        Object.defineProperty(window.Location.prototype, 'href', {
            set: function(val) {
                if (isObviousDownload(val)) {
                    window.postMessage({ __daisyTriggerDownload: val, __daisyFilename: '' }, "*");
                    return;
                }
                return locDesc.set.call(this, val);
            },
            get: locDesc.get
        });
    }

    // 5. Trap Window Open & Reassignments
    const originalWindowOpen = window.open;
    window.open = function(url, name, specs) {
        if (url && typeof url === 'string' && isObviousDownload(url)) {
            window.postMessage({ __daisyTriggerDownload: url, __daisyFilename: '' }, "*");
            return null;
        }
        return originalWindowOpen.apply(this, arguments);
    };

    const originalAssign = window.location.assign;
    window.location.assign = function(url) {
        if (url && typeof url === 'string' && isObviousDownload(url)) {
            window.postMessage({ __daisyTriggerDownload: url, __daisyFilename: '' }, "*");
            return;
        }
        return originalAssign.call(window.location, url);
    };

    const originalReplace = window.location.replace;
    window.location.replace = function(url) {
        if (url && typeof url === 'string' && isObviousDownload(url)) {
            window.postMessage({ __daisyTriggerDownload: url, __daisyFilename: '' }, "*");
            return;
        }
        return originalReplace.call(window.location, url);
    };

    // YouTube format listener.
    // Uses every YouTube player API surface we can reach so we don't miss
    // qualities right after an SPA navigation (when streamingData hasn't been
    // populated yet but getAvailableQualityData() is already current). The
    // harvest is retried briefly for the same reason — without this, hovering
    // the player a moment after clicking a video link returns a partial list
    // and the user has to hard-refresh the page to see all qualities.
    const YT_QUALITY_LEVEL_HEIGHTS = {
        highres: 4320, hd2880: 2880, hd2160: 2160, hd1440: 1440,
        hd1080: 1080, hd720: 720, large: 480, medium: 360, small: 240, tiny: 144
    };

    function currentYtVideoId() {
        try {
            const u = new URL(window.location.href);
            const v = u.searchParams.get('v');
            if (v) return v;
            const m = u.pathname.match(/\/(?:shorts|embed|live)\/([^/?#]+)/);
            return m ? m[1] : null;
        } catch (_) { return null; }
    }

    function harvestYouTubeHeights() {
        const heights = new Set();
        const addFromLabel = (label) => {
            if (!label) return;
            const m = String(label).match(/(\d+)\s*p/i);
            if (!m) return;
            const h = parseInt(m[1], 10);
            if (h >= 144 && h <= 4320) heights.add(h);
        };
        const addFromFormatsArray = (arr) => {
            if (!Array.isArray(arr)) return;
            arr.forEach(f => {
                if (!f) return;
                if (typeof f.height === 'number' && f.height >= 144 && f.height <= 4320) heights.add(f.height);
                else if (f.qualityLabel) addFromLabel(f.qualityLabel);
            });
        };

        const player = document.querySelector('#movie_player') || document.getElementById('movie_player');
        if (player) {
            try {
                if (typeof player.getAvailableQualityData === 'function') {
                    const data = player.getAvailableQualityData();
                    if (Array.isArray(data)) data.forEach(q => addFromLabel(q && q.qualityLabel));
                }
            } catch (_) {}
            try {
                if (typeof player.getAvailableQualityLevels === 'function') {
                    const levels = player.getAvailableQualityLevels();
                    if (Array.isArray(levels)) levels.forEach(l => {
                        if (YT_QUALITY_LEVEL_HEIGHTS[l]) heights.add(YT_QUALITY_LEVEL_HEIGHTS[l]);
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

        // Only trust ytInitialPlayerResponse when it actually refers to the
        // video currently in the URL — after SPA navigation it can lag behind
        // and inject heights from the *previous* video.
        try {
            const initial = window.ytInitialPlayerResponse;
            const initialId = initial && initial.videoDetails && initial.videoDetails.videoId;
            const currentId = currentYtVideoId();
            if (initial && initial.streamingData && (!currentId || !initialId || initialId === currentId)) {
                addFromFormatsArray(initial.streamingData.formats);
                addFromFormatsArray(initial.streamingData.adaptiveFormats);
            }
        } catch (_) {}

        return heights;
    }

    window.addEventListener("message", (e) => {
        if (!e.data || !e.data.__daisyReqYtFormats) return;
        const startedAt = Date.now();
        const minHeights = 3;
        const maxWaitMs = 1500;
        const intervalMs = 150;

        const attempt = () => {
            const heights = harvestYouTubeHeights();
            if (heights.size >= minHeights || Date.now() - startedAt > maxWaitMs) {
                window.postMessage({ __daisyYtFormatsResp: Array.from(heights) }, "*");
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

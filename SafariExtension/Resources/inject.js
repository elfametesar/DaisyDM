// inject.js
(function() {
    const MEDIA_RE = /\.m3u8|stream\.mpd|\.mpd|dash|hls|\.mp4|\.webm|\.mov|\.ts|manifest/i;

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

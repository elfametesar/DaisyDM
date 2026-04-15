// background.js - Daisy Extension Full Source

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        triggerDownload(message.url, message.filename, sender.tab?.url || "", message.youtubeQuality, message.forceHLS);
        sendResponse({ success: true });
        return false;
    }
});

function triggerDownload(url, filename, referer, youtubeQuality, forceHLS) {
    // If it's a blob/data URL, we don't need cookies from the remote server
    const cookieUrl = (url.startsWith('data:') || url.startsWith('blob:')) ? referer : url;
    
    chrome.cookies.getAll({ url: cookieUrl }).then(cookiesArr => {
        const cookies = cookiesArr.map(c => `${c.name}=${c.value}`).join("; ");
        sendViaLocalHost(url, filename, cookies, referer, youtubeQuality, forceHLS);
    }).catch(() => {
        sendViaLocalHost(url, filename, "", referer, youtubeQuality, forceHLS);
    });
}

async function sendViaLocalHost(url, filename, cookies, referer, youtubeQuality, forceHLS) {
    const payload = JSON.stringify({ 
        url, 
        filename: filename || "video", 
        cookies, 
        referer, 
        ua: navigator.userAgent,
        youtubeQuality,
        forceHLS 
    });
    
    let success = false;
    // Attempt multiple ports in case of local server conflicts
    for (let port = 6840; port <= 6850; port++) {
        try {
            const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, {
                method: "POST", 
                headers: { "Content-Type": "application/json" }, 
                body: payload
            });
            if (resp.ok) { success = true; break; }
        } catch (_) {}
    }

    // Fallback: If local server isn't running, use browser downloader (unless it's a raw blob string)
    if (!success && !url.startsWith('data:')) {
        chrome.downloads.download({ url: url, filename: filename + ".mp4" || undefined });
    }
}

// Network sniffer to catch m3u8 playlists that don't appear in video.src
chrome.webRequest.onHeadersReceived.addListener(
    function(details) {
        if (details.tabId === -1) return;
        const targetMimeTypes = ["video/", "mpegurl", "m3u8", "video/mp2t"];
        const isMedia = details.responseHeaders?.some(h => 
            h.name.toLowerCase() === "content-type" && targetMimeTypes.some(m => h.value.toLowerCase().includes(m))
        );
        if (isMedia) {
            chrome.tabs.sendMessage(details.tabId, { type: 'NEW_MEDIA_FOUND', mediaInfo: { url: details.url } }).catch(() => {});
        }
    },
    { urls: ["<all_urls>"] },
    ["responseHeaders"]
);

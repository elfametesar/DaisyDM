// background.js - Daisy Chrome Extension

let dispatchEnabled = true;
let bypassNextDownloadUrl = null;

chrome.storage.local.get(["dispatchEnabled"]).then(res => {
    if (typeof res.dispatchEnabled === "boolean") dispatchEnabled = res.dispatchEnabled;
});

chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.dispatchEnabled) {
        dispatchEnabled = changes.dispatchEnabled.newValue;
    }
});

chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.create({ id: "dispatch-download", title: "Download with Daisy", contexts: ["link"] });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "dispatch-download" && info.linkUrl) {
        triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab?.url || "");
    }
});

function needsCredentialedFetch(url) {
    try { return /claude\.ai$/.test(new URL(url).hostname); } catch { return false; }
}

chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
    if (!dispatchEnabled) return;
    const url = item.finalUrl || item.url;
    
    if (!url || url.startsWith("blob:") || url.startsWith("data:") || bypassNextDownloadUrl === url) {
        bypassNextDownloadUrl = null;
        return; 
    }

    chrome.downloads.cancel(item.id);

    const referer = item.referrer || "";
    const filename = item.filename ? item.filename.split(/[\/\\]/).pop() : extractFilename(url);

    if (needsCredentialedFetch(url)) {
        chrome.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            const tabId = tabs?.[0]?.id;
            if (tabId) {
                chrome.tabs.sendMessage(tabId, { type: "CREDENTIALED_FETCH", url, filename })
                    .catch(() => triggerDownload(url, filename, referer));
            }
        });
    } else {
        triggerDownload(url, filename, referer);
    }
    return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        triggerDownload(message.url, message.filename, sender.tab?.url || "", message.youtubeQuality, message.forceHLS);
        sendResponse({ success: true });
        return false;
    }
});

function triggerDownload(url, filename, referer, youtubeQuality, forceHLS) {
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
        filename: filename || "download", 
        cookies: cookies || "", 
        referer: referer || "", 
        ua: navigator.userAgent,
        youtubeQuality,
        forceHLS 
    });
    
    let success = false;
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

    if (!success && !url.startsWith('data:')) {
        bypassNextDownloadUrl = url;
        // Removed the hardcoded + ".mp4" string from the browser fallback
        chrome.downloads.download({ url: url, filename: filename || undefined });
    }
}

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

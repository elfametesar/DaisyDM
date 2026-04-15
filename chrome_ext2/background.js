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
        triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab?.url || "", tab?.id);
    }
});

function needsCredentialedFetch(url) {
    try { return /claude\.ai$/.test(new URL(url).hostname); } catch { return false; }
}

// FIX: Use onDeterminingFilename to cancel before the browser touches the file
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
    if (!dispatchEnabled) return;
    const url = item.finalUrl || item.url;
    
    if (!url || url.startsWith("blob:") || url.startsWith("data:") || bypassNextDownloadUrl === url) {
        bypassNextDownloadUrl = null;
        return; 
    }

    // Stop the browser download immediately
    chrome.downloads.cancel(item.id);

    const referer = item.referrer || "";
    const filename = item.filename ? item.filename.split(/[\/\\]/).pop() : extractFilename(url);

    if (needsCredentialedFetch(url)) {
        chrome.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            const tabId = tabs?.[0]?.id;
            if (tabId) {
                chrome.tabs.sendMessage(tabId, { type: "CREDENTIALED_FETCH", url, filename })
                    .catch(() => triggerDownload(url, filename, referer, tabId));
            }
        });
    } else {
        triggerDownload(url, filename, referer, null);
    }
    
    return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        triggerDownload(message.url, message.filename, sender.tab?.url || "", sender.tab?.id);
        sendResponse({ intercepted: true });
        return false;
    }
});

function triggerDownload(url, filename, referer, tabId) {
    chrome.cookies.getAll({ url }).then(cookiesArr => {
        const cookies = cookiesArr.map(c => `${c.name}=${c.value}`).join("; ");
        sendViaLocalHost(url, filename, cookies, referer);
    }).catch(() => {
        sendViaLocalHost(url, filename, "", referer);
    });
}

async function sendViaLocalHost(url, filename, cookies, referer) {
    const payload = JSON.stringify({ url, filename: filename || "", cookies: cookies || "", referer: referer || "", ua: navigator.userAgent });
    for (let port = 6840; port <= 6850; port++) {
        try {
            const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, {
                method: "POST", headers: { "Content-Type": "application/json" }, body: payload
            });
            if (resp.ok) return;
        } catch (_) {}
    }
    bypassNextDownloadUrl = url;
    chrome.downloads.download({ url: url, filename: filename || undefined });
}

function extractFilename(url) {
    try {
        const u = new URL(url);
        const parts = u.pathname.split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "download";
    } catch { return "download"; }
}

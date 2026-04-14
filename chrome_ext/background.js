// background.js - Daisy Chrome Extension

let dispatchEnabled = true;
let bypassNextDownloadUrl = null; // Fallback lock

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
        if (info.linkUrl.startsWith("blob:")) {
            if (tab && tab.id) {
                chrome.tabs.sendMessage(tab.id, { type: "FETCH_BLOB", url: info.linkUrl, filename: extractFilename(info.linkUrl) })
                    .catch(() => triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab.url || "", tab.id));
            }
        } else {
            triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab?.url || "", tab?.id);
        }
    }
});

function needsCredentialedFetch(url) {
    try { return /claude\.ai$/.test(new URL(url).hostname); } catch { return false; }
}

chrome.downloads.onCreated.addListener((item) => {
    if (!dispatchEnabled) return;

    const url = item.finalUrl || item.url;
    if (!url || url.startsWith("blob:") || url.startsWith("data:")) return;

    // FALLBACK CHECK: If this download was triggered by our fallback logic, leave it alone.
    if (bypassNextDownloadUrl === url) {
        bypassNextDownloadUrl = null; 
        return;
    }

    chrome.downloads.cancel(item.id);
    chrome.downloads.erase({ id: item.id });

    const referer  = item.referrer || "";
    const filename = item.filename ? item.filename.split(/[\/\\]/).pop() : extractFilename(url);

    if (url.startsWith("blob:")) {
        chrome.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            const tabId = tabs?.[0]?.id;
            if (tabId) {
                chrome.tabs.sendMessage(tabId, { type: "FETCH_BLOB", url: url, filename: filename })
                    .catch(() => triggerDownload(url, filename, referer, tabId));
            }
        });
        return;
    }

    if (needsCredentialedFetch(url)) {
        chrome.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            const tabId = tabs?.[0]?.id;
            if (tabId) {
                chrome.tabs.sendMessage(tabId, { type: "CREDENTIALED_FETCH", url, filename })
                    .catch(() => triggerDownload(url, filename, referer, tabId));
            }
        });
        return;
    }

    triggerDownload(url, filename, referer, null);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        triggerDownload(message.url, message.filename, sender.tab?.url || "", sender.tab?.id);
        sendResponse({ intercepted: true });
        return false;
    }
    if (message.type === "GET_STATUS") {
        sendResponse({ enabled: dispatchEnabled });
        return false;
    }
});

function triggerDownload(url, filename, referer, tabId) {
    if (!url.startsWith("http")) {
        sendViaLocalHost(url, filename, "", referer);
        return;
    }

    chrome.cookies.getAll({ url }).then(cookiesArr => {
        const cookies = cookiesArr.map(c => `${c.name}=${c.value}`).join("; ");
        sendViaLocalHost(url, filename, cookies, referer);
    }).catch(() => {
        sendViaLocalHost(url, filename, "", referer);
    });
}

async function sendViaLocalHost(url, filename, cookies, referer) {
    const payload = JSON.stringify({ url, filename: filename || "", cookies: cookies || "", referer: referer || "", ua: navigator.userAgent });
    let success = false;

    for (let port = 6840; port <= 6850; port++) {
        try {
            const controller = new AbortController();
            const t = setTimeout(() => controller.abort(), 300);
            const resp = await fetch(`http://127.0.0.1:${port}/dispatch`, {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: payload, signal: controller.signal
            });
            clearTimeout(t);
            if (resp.ok) { success = true; break; }
        } catch (_) {}
    }

    // NATIVE FALLBACK: If Swift is unreachable, allow the browser to download it naturally.
    if (!success) {
        console.warn("[Daisy] App not reachable. Natively downloading:", filename);
        bypassNextDownloadUrl = url;
        chrome.downloads.download({ url: url, filename: filename || undefined });
    }
}

function extractFilename(url) {
    try {
        const u = new URL(url);
        const fn = u.searchParams.get("filename") || u.searchParams.get("name");
        if (fn) return decodeURIComponent(fn);
        const parts = u.pathname.split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "download";
    } catch { return "download"; }
}

// background.js - Dispatch Chrome Extension

let dispatchEnabled = true;

// Per-tab bypass state: tabId -> true when Alt is held in that tab
const bypassTabs = new Set();

chrome.storage.local.get(["dispatchEnabled"]).then(res => {
    if (typeof res.dispatchEnabled === "boolean") dispatchEnabled = res.dispatchEnabled;
});
chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.dispatchEnabled) {
        dispatchEnabled = changes.dispatchEnabled.newValue;
    }
});

// Clean up when a tab is closed
chrome.tabs.onRemoved.addListener((tabId) => {
    bypassTabs.delete(tabId);
});

chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.create({
        id: "dispatch-download",
        title: "Download with Dispatch",
        contexts: ["link"]
    });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "dispatch-download" && info.linkUrl) {
        triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab?.url || "");
    }
});

// ── Native download interceptor ───────────────────────────────────────────
chrome.downloads.onCreated.addListener((item) => {
    if (!dispatchEnabled) return;

    // If the initiating tab has the bypass key held, let browser handle it
    if (item.byInitiator !== undefined) {
        try {
            const tabId = item.tabId ?? -1;
            if (tabId >= 0 && bypassTabs.has(tabId)) return;
        } catch (_) {}
    }

    // Also check via tabId directly
    chrome.downloads.search({ id: item.id }, (results) => {
        const dl = results?.[0];
        const tabId = dl?.tabId ?? -1;
        if (tabId >= 0 && bypassTabs.has(tabId)) {
            // Bypass: let browser keep this download
            return;
        }

        const url = item.finalUrl || item.url;
        if (!url || url.startsWith("blob:") || url.startsWith("data:")) return;

        // Cancel Chrome's download and send to Dispatch
        chrome.downloads.cancel(item.id);
        chrome.downloads.erase({ id: item.id });

        const referer  = item.referrer || "";
        const filename = item.filename ? item.filename.split(/[\/\\]/).pop() : extractFilename(url);

        // Claude.ai uses HttpOnly cookies — must fetch in the page context
        if (/claude\.ai/.test(new URL(url).hostname)) {
            chrome.tabs.query({ active: true, currentWindow: true }).then(tabs => {
                if (tabs?.[0]?.id) {
                    chrome.tabs.sendMessage(tabs[0].id, {
                        type: "CREDENTIALED_FETCH",
                        url,
                        filename
                    }).catch(() => triggerDownload(url, filename, referer));
                } else {
                    triggerDownload(url, filename, referer);
                }
            });
            return;
        }

        triggerDownload(url, filename, referer);
    });
});

// ── Messages from content script ─────────────────────────────────────────
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "SET_BYPASS") {
        const tabId = sender.tab?.id;
        if (tabId !== undefined) {
            if (message.held) bypassTabs.add(tabId);
            else              bypassTabs.delete(tabId);
        }
        return false;
    }

    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        triggerDownload(message.url, message.filename, sender.tab?.url || "");
        sendResponse({ intercepted: true });
        return false;
    }

    if (message.type === "GET_STATUS") {
        sendResponse({ enabled: dispatchEnabled });
        return false;
    }
});

// ── Core Download Trigger (Port Scanning HTTP Server) ─────────────────────
function triggerDownload(url, filename, referer) {
    chrome.cookies.getAll({ url }).then(cookiesArr => {
        const cookies = cookiesArr.map(c => `${c.name}=${c.value}`).join("; ");
        sendViaLocalHost(url, filename, cookies, referer);
    }).catch(() => {
        sendViaLocalHost(url, filename, "", referer);
    });
}

async function sendViaLocalHost(url, filename, cookies, referer) {
    const payload = JSON.stringify({
        url: url,
        filename: filename || "",
        cookies: cookies || "",
        referer: referer || "",
        ua: navigator.userAgent
    });

    // Scan the designated range (6840 to 6850)
    for (let port = 6840; port <= 6850; port++) {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 300);

            const response = await fetch(`http://127.0.0.1:${port}/dispatch`, {
                method: "POST",
                headers: {
                    "Content-Type": "application/json"
                },
                body: payload,
                signal: controller.signal
            });

            clearTimeout(timeoutId);

            if (response.ok) {
                console.log(`✅ Dispatched to Mac App on port ${port}`);
                return;
            }
        } catch (error) {
            // Expected for closed ports, continue
        }
    }

    console.warn("❌ Dispatch Mac App not found on any port between 6840-6850. Is the app open?");
}

// ── Helpers ───────────────────────────────────────────────────────────────
function extractFilename(url) {
    try {
        const u = new URL(url);
        const fn = u.searchParams.get("filename") || u.searchParams.get("name");
        if (fn) return decodeURIComponent(fn);
        const parts = u.pathname.split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "download";
    } catch { return "download"; }
}

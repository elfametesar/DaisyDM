// background.js - Dispatch Safari Extension
// Safari uses browser.* (WebExtensions API). chrome.* shim may exist but is unreliable.
// NOTE: safari has no chrome.downloads API — download interception is handled
// entirely via content.js click/fetch/XHR hooks.

const api = typeof browser !== "undefined" ? browser : chrome;

let dispatchEnabled = true;

api.storage.local.get(["dispatchEnabled"]).then(res => {
    if (typeof res.dispatchEnabled === "boolean") dispatchEnabled = res.dispatchEnabled;
}).catch(() => {});

api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.dispatchEnabled) {
        dispatchEnabled = changes.dispatchEnabled.newValue;
    }
});

api.runtime.onInstalled.addListener(() => {
    api.contextMenus.create({
        id: "dispatch-download",
        title: "Download with Dispatch",
        contexts: ["link"]
    });
});

api.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "dispatch-download" && info.linkUrl) {
        triggerDownload(info.linkUrl, extractFilename(info.linkUrl), tab?.url || "");
    }
});

// ── NOTE: safari.downloads API does not exist in Safari Web Extensions ────
// Download interception is fully handled by content.js.
// The chrome.downloads.onCreated listener below is intentionally omitted.

// ── Messages from content script ─────────────────────────────────────────
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "PREPARE_DISPATCH_DOWNLOAD") {
        if (!dispatchEnabled) {
            sendResponse({ intercepted: false });
            return false;
        }
        triggerDownload(message.url, message.filename, sender.tab?.url || "");
        sendResponse({ intercepted: true });
        return false;
    }

    if (message.type === "GET_STATUS") {
        sendResponse({ enabled: dispatchEnabled });
        return false;
    }
});

// ── Core Download Trigger ─────────────────────────────────────────────────
function triggerDownload(url, filename, referer) {
    // Safari cookies API requires host_permissions; use getAll with url.
    api.cookies.getAll({ url }).then(cookiesArr => {
        const cookies = cookiesArr.map(c => `${c.name}=${c.value}`).join("; ");
        sendViaLocalHost(url, filename, cookies, referer);
    }).catch(() => {
        sendViaLocalHost(url, filename, "", referer);
    });
}

async function sendViaLocalHost(url, filename, cookies, referer) {
    // navigator.userAgent is NOT available in MV3 service workers on Safari.
    // We send an empty string; the Mac app should fall back to a default UA.
    const payload = JSON.stringify({
        url:      url,
        filename: filename || "",
        cookies:  cookies  || "",
        referer:  referer  || "",
        ua:       ""
    });

    for (let port = 6840; port <= 6850; port++) {
        try {
            const controller = new AbortController();
            const timeoutId  = setTimeout(() => controller.abort(), 300);

            const response = await fetch(`http://127.0.0.1:${port}/dispatch`, {
                method:  "POST",
                headers: { "Content-Type": "application/json" },
                body:    payload,
                signal:  controller.signal
            });

            clearTimeout(timeoutId);

            if (response.ok) {
                console.log(`✅ Dispatched to Mac App on port ${port}`);
                return;
            }
        } catch (_) {
            // Closed port or timeout — continue scanning.
        }
    }

    console.warn("❌ Dispatch Mac App not found on ports 6840-6850. Is the app open?");
}

// ── Helpers ───────────────────────────────────────────────────────────────
function extractFilename(url) {
    try {
        const u  = new URL(url);
        const fn = u.searchParams.get("filename") || u.searchParams.get("name");
        if (fn) return decodeURIComponent(fn);
        const parts = u.pathname.split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "download";
    } catch { return "download"; }
}

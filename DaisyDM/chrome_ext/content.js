// content.js - Daisy Extension Full Source

const _api = typeof browser !== "undefined" ? browser : chrome;

let bypassKey = "Alt"; 
let isExtensionDisabled = false;
let isKeyCurrentlyHeld = false;

_api.storage.local.get(['bypassKey', 'isExtensionDisabled'], (res) => {
  if (res.bypassKey) bypassKey = res.bypassKey;
  if (res.isExtensionDisabled !== undefined) isExtensionDisabled = res.isExtensionDisabled;
});

_api.storage.onChanged.addListener((changes) => {
  if (changes.bypassKey) bypassKey = changes.bypassKey.newValue;
  if (changes.isExtensionDisabled) isExtensionDisabled = changes.isExtensionDisabled.newValue;
});

function checkKey(e) {
  if (bypassKey === "Alt") return e.altKey || e.key === "Alt";
  if (bypassKey === "Shift") return e.shiftKey || e.key === "Shift";
  if (bypassKey === "Control") return e.ctrlKey || e.key === "Control";
  if (bypassKey === "Meta") return e.metaKey || e.key === "Meta";
  return false;
}

document.addEventListener("keydown", (e) => { if (checkKey(e)) isKeyCurrentlyHeld = true; }, { capture: true, passive: true });
document.addEventListener("keyup", (e) => { if (!checkKey(e)) isKeyCurrentlyHeld = false; }, { capture: true, passive: true });

function sendToDispatch(url, filename, youtubeQuality = null, forceHLS = false) {
  if (url.startsWith("blob:")) {
    handleBlob(url, filename);
    return;
  }
  _api.runtime.sendMessage({
    type: "PREPARE_DISPATCH_DOWNLOAD",
    url: url,
    filename: filename || "",
    youtubeQuality: youtubeQuality,
    forceHLS: forceHLS
  });
}

async function handleBlob(blobUrl, filename) {
    try {
        // Fetching with 'include' credentials to bypass some CORS locks
        const response = await fetch(blobUrl, { mode: 'cors' });
        const blob = await response.blob();
        const reader = new FileReader();
        reader.onloadend = function() {
            const base64data = reader.result;                
            const finalDataUrl = base64data.replace(/^data:[^;]+;base64,/, "data:application/octet-stream;base64,");
            sendToDispatch(finalDataUrl, filename.endsWith('.mp4') ? filename : filename + ".mp4");
        };
        reader.readAsDataURL(blob);
    } catch (err) { 
        console.error("DaisyDM: Blob capture failed, falling back to direct URL", err);
        sendToDispatch(blobUrl, filename);
    }
}

// --- VIDEO PLAYER OVERLAY ---
(function() {
    if (window.__daisydm_video_injected) return;
    window.__daisydm_video_injected = true;

    let sniffedMediaUrls = [];
    _api.runtime.onMessage.addListener((msg) => {
        if (msg.type === 'NEW_MEDIA_FOUND') { sniffedMediaUrls.push(msg.mediaInfo); }
    });

    const style = document.createElement('style');
    style.textContent = `
        .daisydm-overlay-container {
            position: absolute; z-index: 2147483647; background: rgba(20, 20, 20, 0.9);
            border: 1px solid #444; border-radius: 6px; font-family: -apple-system, system-ui, sans-serif;
            box-shadow: 0 8px 16px rgba(0,0,0,0.5); display: none; flex-direction: column; min-width: 180px;
            overflow: hidden;
        }
        .daisydm-overlay-container.visible { display: flex; }
        .daisydm-overlay-header {
            background: #2563eb; color: white; padding: 8px 12px; font-size: 13px; font-weight: bold; cursor: pointer;
            text-align: center; border-bottom: 1px solid #333;
        }
        .daisydm-overlay-dropdown { display: none; flex-direction: column; background: #fff; max-height: 300px; overflow-y: auto; }
        .daisydm-overlay-container.expanded .daisydm-overlay-dropdown { display: flex; }
        .daisydm-overlay-option { padding: 10px 14px; font-size: 12px; color: #111; cursor: pointer; border-bottom: 1px solid #eee; line-height: 1.4; }
        .daisydm-overlay-option:hover { background: #eff6ff; color: #2563eb; }
        .daisydm-badge { font-size: 9px; background: #eee; padding: 2px 4px; border-radius: 3px; margin-left: 5px; vertical-align: middle; }
    `;
    document.head.appendChild(style);

    function createOverlay(videoEl) {
        const container = document.createElement('div');
        container.className = 'daisydm-overlay-container';
        const header = document.createElement('div');
        header.className = 'daisydm-overlay-header';
        header.textContent = 'Daisy Download ▼';
        const dropdown = document.createElement('div');
        dropdown.className = 'daisydm-overlay-dropdown';
        
        container.appendChild(header);
        container.appendChild(dropdown);
        document.body.appendChild(container);

        header.onclick = (e) => { 
            e.stopPropagation(); 
            container.classList.toggle('expanded'); 
            populateDropdown(videoEl, dropdown); 
        };
        
        const updatePos = () => {
            const rect = videoEl.getBoundingClientRect();
            container.style.top = (window.scrollY + rect.top + 10) + 'px';
            container.style.left = (window.scrollX + rect.left + 10) + 'px';
        };

        videoEl.addEventListener('mouseenter', () => { updatePos(); container.classList.add('visible'); });
        
        document.addEventListener('mousemove', (e) => {
            const rect = videoEl.getBoundingClientRect();
            const padding = 20;
            if (e.clientX < rect.left - padding || e.clientX > rect.right + padding || 
                e.clientY < rect.top - padding || e.clientY > rect.bottom + padding) {
                if (!container.classList.contains('expanded')) container.classList.remove('visible');
            }
        });
    }

    function populateDropdown(videoEl, dropdownEl) {
        dropdownEl.innerHTML = ''; 
        let options = [];
        const currentUrl = window.location.href;

        // 1. YouTube Logic
        if (currentUrl.includes('youtube.com') || currentUrl.includes('youtu.be')) {
            const ytQualities = [
                { id: "b", label: "Best Quality" },
                { id: "bestvideo[height<=1080]+bestaudio/best", label: "1080p HD" },
                { id: "bestaudio/best", label: "Audio Only (MP3/M4A)" }
            ];
            ytQualities.forEach(q => options.push({ label: q.label, url: currentUrl, ytQuality: q.id }));
        } else {
            // 2. FORCE SCRAPE HTML VIDEO SRC (The fix for "It's in the HTML")
            if (videoEl.src) {
                const isBlob = videoEl.src.startsWith('blob:');
                options.push({ 
                    label: isBlob ? 'Detected Blob Stream' : 'Source from HTML', 
                    url: videoEl.src, 
                    isHLS: videoEl.src.includes('m3u8') 
                });
            }

            // 3. Scrape <source> tags
            const sources = videoEl.querySelectorAll('source');
            sources.forEach((s, i) => {
                if (s.src) {
                    options.push({ label: `Source Tag ${i+1}`, url: s.src, isHLS: s.src.includes('m3u8') });
                }
            });

            // 4. Sniffer Results
            Array.from(new Set(sniffedMediaUrls.map(a => a.url))).forEach((url, idx) => {
                const isHLS = url.includes('.m3u8') || url.includes('/m3u8/') || url.includes('type=m3u8');
                // Don't duplicate if it's already the primary src
                if (url !== videoEl.src) {
                    options.push({ label: isHLS ? `Network Stream ${idx+1}` : `Network Video ${idx+1}`, url: url, isHLS: isHLS });
                }
            });
        }

        if (options.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'daisydm-overlay-option';
            empty.textContent = 'No sources found yet...';
            dropdownEl.appendChild(empty);
            return;
        }

        options.forEach(opt => {
            const item = document.createElement('div');
            item.className = 'daisydm-overlay-option';
            item.innerHTML = `${opt.label} <span class="daisydm-badge">${opt.isHLS ? 'HLS' : 'MP4'}</span>`;
            item.onclick = () => {
                item.textContent = "Sending...";
                sendToDispatch(opt.url, document.title || "Video", opt.ytQuality, opt.isHLS);
                setTimeout(() => { dropdownEl.parentElement.classList.remove('expanded'); }, 1000);
            };
            dropdownEl.appendChild(item);
        });
    }

    setInterval(() => {
        document.querySelectorAll('video').forEach(v => { 
            if (!v.dataset.daisy) { 
                v.dataset.daisy = "true"; 
                createOverlay(v); 
            } 
        });
    }, 2000);
})();

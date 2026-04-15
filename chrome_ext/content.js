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

  // Ensure the filename has an extension if it's not a YouTube quality request
  let finalFilename = filename || "Video";
  const hasExtension = /\.[0-9a-z]+$/i.test(finalFilename);
  if (!hasExtension && !youtubeQuality) {
    finalFilename += ".mp4";
  }

  _api.runtime.sendMessage({
    type: "PREPARE_DISPATCH_DOWNLOAD",
    url: url,
    filename: finalFilename,
    youtubeQuality: youtubeQuality,
    forceHLS: forceHLS
  });
}

async function handleBlob(blobUrl, filename) {
    try {
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
    
    _api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
        if (msg.type === 'NEW_MEDIA_FOUND' && msg.mediaInfo) { 
            sniffedMediaUrls.push(msg.mediaInfo); 
        }
        if (msg.action === "getPageInfo") {
            sendResponse({
                title: document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Unknown Video",
                pageUrl: window.location.href,
                cookies: document.cookie
            });
        }
    });

    const style = document.createElement('style');
    style.textContent = `
        .daisydm-overlay-container {
            position: absolute; 
            z-index: 2147483647; 
            background: rgba(28, 28, 30, 0.85);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.1); 
            border-radius: 10px; 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            box-shadow: 0 12px 24px rgba(0,0,0,0.4); 
            display: none; 
            flex-direction: column; 
            min-width: 200px;
            overflow: hidden;
            transition: opacity 0.2s ease, transform 0.2s ease;
            opacity: 0;
            transform: translateY(5px);
        }
        .daisydm-overlay-container.visible { 
            display: flex; 
            opacity: 1;
            transform: translateY(0);
        }
        .daisydm-overlay-header {
            background: #334155; 
            color: white; 
            padding: 10px 14px; 
            font-size: 13px; 
            font-weight: 600; 
            cursor: pointer;
            text-align: left; 
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.2s;
        }
        .daisydm-overlay-header:hover {
            background: #475569;
        }
        .daisydm-overlay-header::after {
            content: '▼';
            font-size: 10px;
            transition: transform 0.3s;
        }
        .daisydm-overlay-container.expanded .daisydm-overlay-header::after {
            transform: rotate(180deg);
        }
        .daisydm-overlay-dropdown { 
            display: none; 
            flex-direction: column; 
            background: transparent; 
            max-height: 280px; 
            overflow-y: auto; 
        }
        .daisydm-overlay-container.expanded .daisydm-overlay-dropdown { 
            display: flex; 
            border-top: 1px solid rgba(255, 255, 255, 0.1);
        }
        .daisydm-overlay-option { 
            padding: 12px 14px; 
            font-size: 13px; 
            color: #efeff4; 
            cursor: pointer; 
            border-bottom: 1px solid rgba(255, 255, 255, 0.05); 
            line-height: 1.4; 
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.2s;
        }
        .daisydm-overlay-option:last-child {
            border-bottom: none;
        }
        .daisydm-overlay-option:hover { 
            background: rgba(255, 255, 255, 0.1); 
            color: #fff; 
        }
        .daisydm-badge { 
            font-size: 10px; 
            background: rgba(255, 255, 255, 0.15); 
            color: #aaa;
            padding: 2px 6px; 
            border-radius: 4px; 
            text-transform: uppercase;
            font-weight: 700;
        }
        .daisydm-overlay-dropdown::-webkit-scrollbar {
            width: 6px;
        }
        .daisydm-overlay-dropdown::-webkit-scrollbar-thumb {
            background: rgba(255, 255, 255, 0.2);
            border-radius: 10px;
        }
    `;
    document.head.appendChild(style);

    function createOverlay(videoEl) {
        const container = document.createElement('div');
        container.className = 'daisydm-overlay-container';
        const header = document.createElement('div');
        header.className = 'daisydm-overlay-header';
        header.textContent = 'Daisy Download';
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
            // Position near the top-left of the video
            container.style.top = (window.scrollY + rect.top + 15) + 'px';
            container.style.left = (window.scrollX + rect.left + 15) + 'px';
        };

        videoEl.addEventListener('mouseenter', () => { 
            updatePos(); 
            container.classList.add('visible'); 
        });
        
        document.addEventListener('mousemove', (e) => {
            const rect = videoEl.getBoundingClientRect();
            const padding = 30;
            // Check if mouse is away from video and container
            const isOverVideo = (e.clientX >= rect.left - padding && e.clientX <= rect.right + padding && 
                                e.clientY >= rect.top - padding && e.clientY <= rect.bottom + padding);
            
            if (!isOverVideo && !container.classList.contains('expanded')) {
                container.classList.remove('visible');
            }
        });
    }

    function populateDropdown(videoEl, dropdownEl) {
        dropdownEl.innerHTML = ''; 
        let options = [];
        const currentUrl = window.location.href;

        const getQualityLabel = (url, fallback) => {
            const qualityMatch = url.match(/(\d{3,4}p|720|1080|2160|4K)/i);
            return qualityMatch ? qualityMatch[0].toUpperCase() : fallback;
        };

        const isLikelyVideo = (url) => {
            const videoPatterns = ['.mp4', '.m3u8', '.webm', '.mov', 'video', 'm3u8', 'stream'];
            return videoPatterns.some(pattern => url.toLowerCase().includes(pattern));
        };

        if (currentUrl.includes('youtube.com') || currentUrl.includes('youtu.be')) {
            const ytQualities = [
                { id: "b", label: "Best Quality" },
                { id: "bestvideo[height<=1080]+bestaudio/best", label: "1080p HD" },
                { id: "bestaudio/best", label: "Audio Only" }
            ];
            ytQualities.forEach(q => options.push({ label: q.label, url: currentUrl, ytQuality: q.id }));
        } else {
            if (videoEl.src && isLikelyVideo(videoEl.src)) {
                const isBlob = videoEl.src.startsWith('blob:');
                const label = isBlob ? 'Detected Stream' : getQualityLabel(videoEl.src, 'Primary Video');
                options.push({ label: label, url: videoEl.src, isHLS: videoEl.src.includes('m3u8') });
            }

            const sources = videoEl.querySelectorAll('source');
            sources.forEach((s) => {
                if (s.src && isLikelyVideo(s.src)) {
                    const label = getQualityLabel(s.src, s.type ? s.type.split('/')[1].toUpperCase() : 'Video Source');
                    options.push({ label: label, url: s.src, isHLS: s.src.includes('m3u8') });
                }
            });

            Array.from(new Set(sniffedMediaUrls.map(a => a.url))).forEach((url) => {
                if (isLikelyVideo(url) && url !== videoEl.src) {
                    const isHLS = url.includes('.m3u8') || url.includes('/m3u8/') || url.includes('type=m3u8');
                    const label = getQualityLabel(url, isHLS ? 'HLS Stream' : 'Video File');
                    options.push({ label: label, url: url, isHLS: isHLS });
                }
            });
        }

        if (options.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'daisydm-overlay-option';
            empty.style.color = '#888';
            empty.textContent = 'Searching for links...';
            dropdownEl.appendChild(empty);
            return;
        }

        options.forEach(opt => {
            const item = document.createElement('div');
            item.className = 'daisydm-overlay-option';
            item.innerHTML = `<span>${opt.label}</span> <span class="daisydm-badge">${opt.isHLS ? 'HLS' : 'MP4'}</span>`;
            item.onclick = (e) => {
                e.stopPropagation();
                item.innerHTML = `<span>Sending...</span>`;
                let cleanTitle = document.title ? document.title.replace(/[\\/:*?"<>|]/g, '').trim() : "Video";
                sendToDispatch(opt.url, cleanTitle, opt.ytQuality, opt.isHLS);
                setTimeout(() => { 
                    dropdownEl.parentElement.classList.remove('expanded'); 
                    populateDropdown(videoEl, dropdownEl); // Reset labels
                }, 1500);
            };
            dropdownEl.appendChild(item);
        });
    }

    function scanForVideos(root = document) {
        root.querySelectorAll('video').forEach(v => {
            if (!v.dataset.daisy) {
                v.dataset.daisy = "true";
                createOverlay(v);
            }
        });

        root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) {
                scanForVideos(el.shadowRoot);
            }
        });
    }

    const observer = new MutationObserver(() => scanForVideos());
    observer.observe(document.body, { childList: true, subtree: true });

    scanForVideos();
})();

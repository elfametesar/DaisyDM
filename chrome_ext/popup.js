const _api = typeof browser !== "undefined" ? browser : chrome;

const toggle        = document.getElementById("enableToggle");
const statusDot     = document.getElementById("statusDot");
const statusText    = document.getElementById("statusText");
const videoToggle   = document.getElementById("videoGrabToggle");
const blacklistArea = document.getElementById("blacklistArea");
const blacklistInput= document.getElementById("blacklistInput");
const blacklistAdd  = document.getElementById("blacklistAdd");
const blacklistTags = document.getElementById("blacklistTags");
const keySelect     = document.getElementById("bypassKey");
const openBtn       = document.getElementById("openApp");

let blacklist = [];

loadState();

// --- Intercept toggle ---
toggle.addEventListener("change", () => {
  updateStatus(toggle.checked);
  _api.storage.local.set({ isExtensionDisabled: !toggle.checked });
});

// --- Video grab toggle ---
videoToggle.addEventListener("change", () => {
  _api.storage.local.set({ videoGrabEnabled: videoToggle.checked });
  blacklistArea.classList.toggle("visible", videoToggle.checked);
});

// --- Blacklist ---
blacklistAdd.addEventListener("click", addCurrentInput);
blacklistInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") addCurrentInput();
});

function addCurrentInput() {
  let val = blacklistInput.value.trim().toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/^www\./, '')
    .split('/')[0];
  if (!val || blacklist.includes(val)) { blacklistInput.value = ''; return; }
  blacklist.push(val);
  saveBlacklist();
  blacklistInput.value = '';
  renderTags();
}

function removeFromBlacklist(host) {
  blacklist = blacklist.filter(h => h !== host);
  saveBlacklist();
  renderTags();
}

function saveBlacklist() {
  _api.storage.local.set({ videoGrabBlacklist: blacklist });
}

function renderTags() {
  if (blacklist.length === 0) {
    blacklistTags.innerHTML = '<span class="empty-hint">No sites blocked</span>';
    return;
  }
  blacklistTags.innerHTML = '';
  blacklist.forEach(host => {
    const tag = document.createElement('div');
    tag.className = 'blacklist-tag';
    tag.innerHTML = `<span>${host}</span><button title="Remove">✕</button>`;
    tag.querySelector('button').addEventListener('click', () => removeFromBlacklist(host));
    blacklistTags.appendChild(tag);
  });
}

// --- Bypass key ---
keySelect.addEventListener("change", () => {
  _api.storage.local.set({ bypassKey: keySelect.value });
});

// --- Open app ---
// Use window.location on the active tab to trigger the custom URL scheme.
// tabs.create with a custom scheme is unreliable across browsers; sending
// the scheme URL to an existing tab avoids the dangling-tab problem.
openBtn.addEventListener("click", () => {
  _api.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    if (tabs && tabs[0] && tabs[0].id) {
      _api.tabs.update(tabs[0].id, { url: "daisy://open" });
    }
  });
});

// --- Storage sync ---
_api.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes.isExtensionDisabled) {
    const enabled = !changes.isExtensionDisabled.newValue;
    toggle.checked = enabled;
    updateStatus(enabled);
  }
  if (changes.videoGrabEnabled) {
    const v = changes.videoGrabEnabled.newValue !== false;
    videoToggle.checked = v;
    blacklistArea.classList.toggle("visible", v);
  }
  if (changes.videoGrabBlacklist) {
    blacklist = changes.videoGrabBlacklist.newValue || [];
    renderTags();
  }
  if (changes.bypassKey) keySelect.value = changes.bypassKey.newValue;
});

// --- Load ---
async function loadState() {
  try {
    const res = await _api.storage.local.get({
      isExtensionDisabled: false,
      videoGrabEnabled: true,
      videoGrabBlacklist: [],
      bypassKey: "Alt"
    });
    const enabled = !res.isExtensionDisabled;
    toggle.checked = enabled;
    updateStatus(enabled);

    const vg = res.videoGrabEnabled !== false;
    videoToggle.checked = vg;
    blacklistArea.classList.toggle("visible", vg);

    blacklist = Array.isArray(res.videoGrabBlacklist) ? res.videoGrabBlacklist : [];
    renderTags();

    keySelect.value = res.bypassKey || "Alt";
  } catch (e) {
    toggle.checked = true;
    updateStatus(true);
    videoToggle.checked = true;
  }
}

function updateStatus(enabled) {
  statusDot.className = enabled ? "status-dot" : "status-dot inactive";
  statusText.textContent = enabled
    ? "Active — intercepting downloads"
    : "Disabled — using browser downloads";
}

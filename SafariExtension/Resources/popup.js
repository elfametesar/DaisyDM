const toggle = document.getElementById("enableToggle");
const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const openBtn = document.getElementById("openApp");

loadState();

toggle.addEventListener("change", async () => {
  const enabled = toggle.checked;
  updateStatus(enabled);

  try {
    await browser.storage.local.set({ dispatchEnabled: enabled });
    await browser.runtime.sendMessage({ type: "SET_ENABLED", enabled });
  } catch (error) {
    console.error("Failed to persist Dispatch toggle state", error);
  }
});

openBtn.addEventListener("click", () => {
  browser.tabs.create({ url: "dispatch://open", active: false });
  setTimeout(() => {
    browser.tabs.query({ url: "dispatch://open*" }, (tabs) => {
      tabs.forEach((t) => browser.tabs.remove(t.id));
    });
  }, 500);
});

browser.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes.dispatchEnabled) {
    const enabled = changes.dispatchEnabled.newValue !== false;
    toggle.checked = enabled;
    updateStatus(enabled);
  }
});

async function loadState() {
  try {
    const result = await browser.storage.local.get({ dispatchEnabled: true });
    const enabled = result.dispatchEnabled !== false;
    toggle.checked = enabled;
    updateStatus(enabled);
  } catch (error) {
    console.error("Failed to load Dispatch toggle state", error);
    toggle.checked = true;
    updateStatus(true);
  }
}

function updateStatus(enabled) {
  if (enabled) {
    statusDot.className = "status-dot";
    statusText.textContent = "Active — intercepting downloads";
  } else {
    statusDot.className = "status-dot inactive";
    statusText.textContent = "Disabled — using Safari downloads";
  }
}

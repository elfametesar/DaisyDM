const _api = typeof browser !== "undefined" ? browser : chrome;

const keySelect = document.getElementById("bypassKey");
const disableToggle = document.getElementById("disableExtension");

_api.storage.local.get(['bypassKey', 'isExtensionDisabled'], (res) => {
  if (res.bypassKey) keySelect.value = res.bypassKey;
  if (res.isExtensionDisabled !== undefined) disableToggle.checked = res.isExtensionDisabled;
});

keySelect.addEventListener("change", (e) => {
  _api.storage.local.set({ bypassKey: e.target.value });
});

disableToggle.addEventListener("change", (e) => {
  _api.storage.local.set({ isExtensionDisabled: e.target.checked });
});

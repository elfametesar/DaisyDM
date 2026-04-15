const _api = typeof browser !== "undefined" ? browser : chrome;

const disableToggle = document.getElementById("disableExtension");

_api.storage.local.get(['isExtensionDisabled'], (res) => {
  if (res.isExtensionDisabled !== undefined) disableToggle.checked = res.isExtensionDisabled;
});

disableToggle.addEventListener("change", (e) => {
  _api.storage.local.set({ isExtensionDisabled: e.target.checked });
});

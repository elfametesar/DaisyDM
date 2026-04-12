#!/bin/bash
# install_native_host.sh
# Run once after installing Dispatch to register the Chrome Native Messaging host.
# Usage: ./install_native_host.sh [chrome|chromium|brave|all]
# Default: installs for all detected browsers.

set -euo pipefail

APP_BUNDLE=$(osascript -e 'tell application "Finder" to POSIX path of (application file id "com.dispatch.mac" as alias)' 2>/dev/null || true)

if [ -z "$APP_BUNDLE" ]; then
    # Fallback: find by name
    APP_BUNDLE=$(mdfind 'kMDItemCFBundleIdentifier == "com.dispatch.mac"' 2>/dev/null | head -1)
fi

if [ -z "$APP_BUNDLE" ]; then
    echo "ERROR: Could not locate Dispatch.app. Make sure it is installed in /Applications."
    exit 1
fi

HOST_BINARY="$APP_BUNDLE/Contents/MacOS/DispatchNMH"

# Create the NMH wrapper binary path symlink if needed
# (The main Dispatch binary handles the --nmh flag; see AppDelegate)
DISPATCH_BINARY="$APP_BUNDLE/Contents/MacOS/Dispatch"

NMH_SCRIPT="$APP_BUNDLE/Contents/MacOS/DispatchNMH"
cat > "$NMH_SCRIPT" << EOF
#!/bin/bash
exec "$DISPATCH_BINARY" --nmh "\$@"
EOF
chmod +x "$NMH_SCRIPT"

MANIFEST_JSON=$(cat << EOF
{
  "name": "com.dispatch.mac.nmh",
  "description": "Dispatch Download Manager Native Messaging Host",
  "path": "$NMH_SCRIPT",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://EXTENSION_ID_PLACEHOLDER/"
  ]
}
EOF
)

NMH_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
BRAVE_DIR="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
CHROMIUM_DIR="$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
ARC_DIR="$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts"

TARGET="${1:-all}"

install_for_dir() {
    local dir="$1"
    local browser="$2"
    if [ -d "$dir" ] || [ "$TARGET" != "all" ]; then
        mkdir -p "$dir"
        echo "$MANIFEST_JSON" > "$dir/com.dispatch.mac.nmh.json"
        echo "✓ Installed for $browser → $dir"
    fi
}

case "$TARGET" in
    chrome)    install_for_dir "$NMH_DIR"    "Chrome" ;;
    brave)     install_for_dir "$BRAVE_DIR"  "Brave" ;;
    chromium)  install_for_dir "$CHROMIUM_DIR" "Chromium" ;;
    arc)       install_for_dir "$ARC_DIR"    "Arc" ;;
    all)
        install_for_dir "$NMH_DIR"    "Chrome"
        install_for_dir "$BRAVE_DIR"  "Brave"
        install_for_dir "$CHROMIUM_DIR" "Chromium"
        install_for_dir "$ARC_DIR"    "Arc"
        ;;
esac

echo ""
echo "NOTE: Replace EXTENSION_ID_PLACEHOLDER in the installed .json files"
echo "with the actual extension ID shown in chrome://extensions"
echo "Then restart Chrome."

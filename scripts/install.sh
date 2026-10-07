#!/bin/zsh
# Copies ModelQuickLook.app to /Applications, clears the download quarantine flag,
# and registers the Quick Look extension. Usage: scripts/install.sh [path/to/ModelQuickLook.app]
set -euo pipefail
cd "${0:A:h}/.."

SRC="${1:-build/Release/Build/Products/Release/ModelQuickLook.app}"
DEST=/Applications/ModelQuickLook.app
[[ -d "$SRC" ]] || { echo "App not found at $SRC (run scripts/build-release.sh first)"; exit 1; }

rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
pluginkit -a "$DEST/Contents/PlugIns/FBXPreview.appex"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "Installed. Select an .fbx in Finder and press Space."
echo "If nothing happens, enable it in System Settings > General > Login Items & Extensions > Quick Look."

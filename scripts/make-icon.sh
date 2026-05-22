#!/usr/bin/env bash
# Generates Resources/AppIcon.icns from a single 1024x1024 PNG. Usage:
#   bash scripts/make-icon.sh path/to/my-icon.png
# After running, re-run scripts/build.sh and the icon is bundled into
# Conterm.app.
set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "usage: $0 path/to/1024x1024.png" >&2
    exit 1
fi

cd "$(dirname "$0")/.."

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
mkdir "$ICONSET"

# Apple expects this exact filename set inside the .iconset folder.
for spec in \
    "16   icon_16x16.png" \
    "32   icon_16x16@2x.png" \
    "32   icon_32x32.png" \
    "64   icon_32x32@2x.png" \
    "128  icon_128x128.png" \
    "256  icon_128x128@2x.png" \
    "256  icon_256x256.png" \
    "512  icon_256x256@2x.png" \
    "512  icon_512x512.png" \
    "1024 icon_512x512@2x.png" ; do
    set -- $spec
    sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"
echo "OK: Resources/AppIcon.icns"
echo "Re-run bash scripts/build.sh to embed it."

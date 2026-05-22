#!/usr/bin/env bash
# Packages Conterm.app into a release zip (and optionally .dmg) with
# a minimal install README. Run after scripts/build.sh has produced
# a working ./Conterm.app.
#
# Usage:
#   bash scripts/release.sh           # makes a .zip
#   bash scripts/release.sh dmg       # also makes a .dmg
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d Conterm.app ]]; then
    echo "Conterm.app not found — run scripts/build.sh first." >&2
    exit 1
fi

WANT_DMG="${1:-zip}"
OUT_DIR="release"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"
STAGE="$OUT_DIR/Conterm-$VERSION"
ZIP="$OUT_DIR/Conterm-$VERSION.zip"
DMG="$OUT_DIR/Conterm-$VERSION.dmg"

rm -rf "$OUT_DIR"
mkdir -p "$STAGE"

# Copy the app preserving extended attrs / symlinks / signature.
ditto Conterm.app "$STAGE/Conterm.app"

# Write a minimal install README inside the stage dir.
cat > "$STAGE/README.txt" <<'EOF'
Conterm — Install
=================

⚠️  IMPORTANT: do step 1 BEFORE you launch the app, or things will
   go wrong (keyboard input may not work, app may behave weirdly).
   This is because of macOS's "App Translocation" feature for
   quarantined downloads.

1) DRAG (not copy) Conterm.app from this folder into /Applications.
   If Conterm.app is currently in your Downloads folder, that's
   fine — just drag it from there straight to /Applications.

2) Open Terminal.app (Apple's built-in one) and run ONCE:

       xattr -d com.apple.quarantine /Applications/Conterm.app

   This removes macOS's quarantine flag so Conterm can launch
   normally without Gatekeeper warnings or App Translocation
   getting in the way.

3) Open Conterm normally from now on — double-click, Spotlight,
   or Dock all work.

   (If you skipped step 2, you can right-click → Open the first
   time to bypass Gatekeeper, but App Translocation may still mess
   with things until you do step 2.)


First time you cd into a protected folder
-----------------------------------------
When you cd into ~/Documents, ~/Downloads, or ~/Desktop the first
time, macOS may pop a permission prompt:

   "Conterm" would like to access files in your Documents folder.

Click Allow — your shell needs it to run git, ls, etc. inside
those folders. The prompt appears once per protected folder.


Keys
----
  ⌘T            new tab
  ⌘W            close active pane / tab
  ⌘D            split pane horizontally
  ⌘⇧D           split pane vertically
  ⌘K            open command palette
  ⌘F            search current pane's scrollback
  ⌘1 … ⌘9       jump to tab N
  ⌥1 … ⌥9       focus pane N in current tab
  ⌘,            settings
  Esc           close palette / settings / search


Customization
-------------
Conterm reads config from:

  ~/.config/conterm/config

Every Ghostty config option works (font-size, cursor-style,
background-opacity, etc.). Reference:

  https://ghostty.org/docs/config/reference


Requirements
------------
  macOS 14 (Sonoma) or later, Apple Silicon.


Source / issues
---------------
  https://github.com/mahdiarfrm/conterm
  Telegram Contact: @BlindFoolDead
EOF

# Make the zip with ditto so resource forks / signature survive.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
echo "OK: $ZIP ($(du -h "$ZIP" | cut -f1))"

# Optional .dmg — only built when first arg is "dmg".
if [[ "$WANT_DMG" == "dmg" ]] && command -v hdiutil >/dev/null 2>&1; then
    echo "==> creating $DMG"
    # Build a read-write DMG, then convert to compressed read-only.
    RW_DMG="$(mktemp -d)/conterm-rw.dmg"
    hdiutil create -srcfolder "$STAGE" \
                   -volname "Conterm" \
                   -fs HFS+ \
                   -format UDRW \
                   -size 30m \
                   "$RW_DMG" >/dev/null

    # Add an Applications symlink so users can drag-drop into /Applications
    # right from the DMG window.
    MOUNT_DIR="$(mktemp -d)/conterm-mount"
    hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
    ln -sf /Applications "$MOUNT_DIR/Applications"
    hdiutil detach "$MOUNT_DIR" -quiet

    hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" -quiet
    rm -rf "$RW_DMG" "$MOUNT_DIR"
    echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
fi

echo
echo "Stage directory: $STAGE/"
echo "Share with friends."

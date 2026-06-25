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

# Source of truth for the version is the built bundle. Default to it, and
# if VERSION is set explicitly, refuse to ship an artifact whose name
# disagrees with what's actually inside the bundle.
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    Conterm.app/Contents/Info.plist 2>/dev/null || true)
VERSION="${VERSION:-${PLIST_VERSION:-$(date +%Y.%m.%d)}}"
if [[ -n "$PLIST_VERSION" && "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "VERSION=$VERSION doesn't match the built bundle (CFBundleShortVersionString=$PLIST_VERSION)." >&2
    echo "Rebuild at the intended version, or unset VERSION to use the bundle's." >&2
    exit 1
fi

STAGE="$OUT_DIR/Conterm-$VERSION"
ZIP="$OUT_DIR/Conterm-$VERSION.zip"
DMG="$OUT_DIR/Conterm-$VERSION.dmg"

rm -rf "$OUT_DIR"
mkdir -p "$STAGE"

# Copy the app preserving extended attrs / symlinks / signature.
ditto Conterm.app "$STAGE/Conterm.app"

# Write a simple install README inside the stage dir (shown in the
# DMG window, and copied alongside the app).
cat > "$STAGE/README.txt" <<'EOF'
Conterm — Install
=================

1) Drag Conterm.app onto the Applications folder (shown in this
   window).

2) First launch only — macOS will say Conterm is from an
   "unidentified developer". That's expected: Conterm is
   open-source and ad-hoc signed, not notarized through a paid
   Apple Developer account. To open it:

     • Right-click Conterm in Applications → Open → Open.

   If macOS still refuses, open Apple's Terminal.app and run:

     xattr -dr com.apple.quarantine /Applications/Conterm.app

   then open Conterm normally.

3) From then on, launch Conterm any way you like — double-click,
   Spotlight, or Dock.


Requirements
------------
  macOS 14 (Sonoma) or later, Apple Silicon.
  The liquid-glass / blur effects need macOS 26 (Tahoe); on
  earlier versions Conterm runs fine with plain chrome.


First time in a protected folder
--------------------------------
The first time you cd into ~/Documents, ~/Downloads, or ~/Desktop,
macOS may ask for permission. Click Allow — your shell needs it to
run git, ls, etc. there. The prompt appears once per folder.


Keys
----
  ⌘T  new tab            ⌘D   split horizontally
  ⌘W  close pane / tab   ⌘⇧D  split vertically
  ⌘K  command palette    ⌘F   search scrollback
  ⌘1…⌘9  jump to tab     ⌥1…⌥9  focus pane
  ⌘,  settings           Esc  dismiss palette / search


Customization
-------------
Conterm reads config from ~/.config/conterm/config. Every Ghostty
config option works (font-size, cursor-style, background-opacity,
…). Reference: https://ghostty.org/docs/config/reference


Source & issues
---------------
  https://github.com/mahdiarfrm/conterm
  Telegram: @BlindFoolDead
EOF

# Make the zip with ditto so resource forks / signature survive.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
echo "OK: $ZIP ($(du -h "$ZIP" | cut -f1))"

# Optional .dmg — only built when first arg is "dmg". Produces a
# styled DMG: black window background, the Conterm text-logo at the
# bottom, and Conterm.app / Applications / README.txt arranged for a
# one-drag install.
if [[ "$WANT_DMG" == "dmg" ]] && command -v hdiutil >/dev/null 2>&1; then
    echo "==> creating $DMG"
    VOLNAME="Conterm"

    # Render the window background (black canvas + text-logo) into a
    # hidden .background folder inside the staged volume contents.
    mkdir -p "$STAGE/.background"
    swift scripts/dmg-background.swift \
        "$STAGE/.background/background.tiff" docs/assets/text-logo.png

    # Detach any stale Conterm volume from a previous run.
    hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true

    # Build a read-write DMG sized to the staged contents + headroom.
    STAGE_MB=$(du -sm "$STAGE" | cut -f1)
    RW_DMG="$(mktemp -d)/conterm-rw.dmg"
    hdiutil create -srcfolder "$STAGE" \
                   -volname "$VOLNAME" \
                   -fs HFS+ \
                   -format UDRW \
                   -size "$((STAGE_MB + 60))m" \
                   "$RW_DMG" >/dev/null

    hdiutil attach "$RW_DMG" -nobrowse -noautoopen -quiet
    MOUNT_DIR="/Volumes/$VOLNAME"

    # Applications symlink for drag-to-install.
    ln -sf /Applications "$MOUNT_DIR/Applications"
    # Keep the background folder out of the user's view.
    chflags hidden "$MOUNT_DIR/.background"

    # Arrange the Finder window: icon view, no toolbar, custom
    # background, and explicit icon positions (see dmg-background.swift
    # for the matching 620x620 layout). The delays give Finder time to
    # commit the view settings to .DS_Store before we detach.
    osascript <<OSA
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {220, 120, 840, 768}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "Conterm.app" of container window to {215, 200}
        set position of item "Applications" of container window to {405, 200}
        set position of item "README.txt" of container window to {310, 360}
        update without registering applications
        delay 3
        close
    end tell
end tell
OSA

    sync
    sleep 2
    sync
    hdiutil detach "$MOUNT_DIR" -quiet

    # Convert to a compressed, read-only DMG for distribution.
    hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" -quiet
    rm -rf "$RW_DMG"
    echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
fi

echo
echo "Stage directory: $STAGE/"
echo "Share with friends."

#!/usr/bin/env bash
# Idempotent: downloads the prebuilt GhosttyKit.xcframework if not already
# present. Adapted from thdxg/macterm's setup pattern. The framework is a
# static-library xcframework (~286 MB unstripped) so we only fetch it once.
set -euo pipefail

cd "$(dirname "$0")/.."

FORK_REPO="thdxg/ghostty"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"

if [[ -d "$XCFRAMEWORK_DIR" ]]; then
    echo "GhosttyKit.xcframework already present — skipping download."
else
    TAG=$(curl -sL "https://api.github.com/repos/${FORK_REPO}/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")

    if [[ -z "$TAG" ]]; then
        echo "Could not resolve latest release tag from ${FORK_REPO}" >&2
        exit 1
    fi

    URL="https://github.com/${FORK_REPO}/releases/download/${TAG}/GhosttyKit.xcframework.tar.gz"

    echo "Downloading GhosttyKit.xcframework (${TAG}) …"
    curl -L --progress-bar -o GhosttyKit.xcframework.tar.gz "$URL"

    echo "Extracting …"
    tar xzf GhosttyKit.xcframework.tar.gz
    rm GhosttyKit.xcframework.tar.gz

    echo "OK: $(du -sh GhosttyKit.xcframework | cut -f1)"
fi

# Bring in libghostty's shell-integration scripts + themes + docs. These
# live inside Ghostty.app's Contents/Resources/ghostty/ — without them
# the prompt-cursor-reset, OSC title reporting, etc. break, because
# libghostty injects ZDOTDIR / ENV pointing at this directory.
# Runs every setup (not just first-time) so a Ghostty.app update brings
# fresh integration scripts with it.
GHOSTTY_RES="/Applications/Ghostty.app/Contents/Resources/ghostty"
GHOSTTY_TERMINFO="/Applications/Ghostty.app/Contents/Resources/terminfo"
if [[ -d "$GHOSTTY_RES" ]]; then
    rm -rf Resources/ghostty
    cp -R "$GHOSTTY_RES" Resources/ghostty
    echo "OK: copied shell-integration from $GHOSTTY_RES ($(du -sh Resources/ghostty | cut -f1))"
else
    echo "WARN: $GHOSTTY_RES not found — install the Ghostty app once so we can borrow its shell-integration scripts. Cursor & title reporting will be broken without it."
fi

# Also copy the compiled `xterm-ghostty` terminfo. Without it,
# ncurses on the user's machine can't resolve the TERM that
# libghostty advertises — it falls back to xterm-256color, which
# doesn't understand the Kitty keyboard protocol CSI-u sequences
# libghostty emits for modified keys. Symptoms: zsh plugins
# misfiring on key presses (`e` typing 4×), garbage like `;7;13~`
# when pressing Ctrl+Opt+Up, OSC 7 emits getting corrupted.
if [[ -d "$GHOSTTY_TERMINFO" ]]; then
    rm -rf Resources/terminfo
    cp -R "$GHOSTTY_TERMINFO" Resources/terminfo
    echo "OK: copied terminfo from $GHOSTTY_TERMINFO ($(du -sh Resources/terminfo | cut -f1))"
else
    echo "WARN: $GHOSTTY_TERMINFO not found — modified-key handling will be broken without it."
fi

# Capture Ghostty's GENUINE default config (every setting at its
# compiled-in default). `+show-config --default` ignores all user
# config and dumps libghostty's built-in defaults — the authoritative,
# machine-independent default. We bundle this so Conterm's "Use
# default settings" is a real Ghostty default, NOT anyone's personal
# config. Build-time extraction from the Ghostty binary itself (no
# runtime network; Ghostty publishes no canonical default-config URL —
# the binary is the source of truth).
GHOSTTY_BIN="/Applications/Ghostty.app/Contents/MacOS/ghostty"
if [[ -x "$GHOSTTY_BIN" ]]; then
    _gd_tmp="$(mktemp)"
    "$GHOSTTY_BIN" +show-config --default > "$_gd_tmp"
    {
        printf '%s\n' \
            "# Ghostty's genuine default configuration — auto-generated" \
            "# by scripts/setup.sh via: ghostty +show-config --default" \
            "# libghostty's compiled-in defaults, NOT a personal config." \
            "# Do not edit; regenerated on every setup." \
            "#"
        cat "$_gd_tmp"
    } > Resources/ghostty-default.conf
    rm -f "$_gd_tmp"
    echo "OK: extracted Ghostty default → Resources/ghostty-default.conf ($(wc -l < Resources/ghostty-default.conf | tr -d ' ') lines)"
else
    echo "WARN: $GHOSTTY_BIN not found — keeping existing Resources/ghostty-default.conf if present."
fi

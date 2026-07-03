#!/usr/bin/env bash
# Idempotent: downloads the prebuilt GhosttyKit.xcframework if not already
# present. Adapted from thdxg/macterm's setup pattern. The framework is a
# static-library xcframework (~286 MB unstripped) so we only fetch it once.
set -euo pipefail

cd "$(dirname "$0")/.."

FORK_REPO="thdxg/ghostty"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"

# Pinned GhosttyKit build. The fork publishes daily `build-YYYY-MM-DD`
# releases and prunes them after a few weeks, so the pin can outlive its
# download URL — keep a copy of the tarball somewhere durable. Bump the
# pin deliberately (Conterm's key-encoding, occlusion, and selection
# workarounds assume specific libghostty behavior; re-test them), never
# by tracking the fork's latest release. Override with GHOSTTY_KIT_TAG
# only while validating a new pin.
GHOSTTY_KIT_TAG="${GHOSTTY_KIT_TAG:-build-2026-07-01}"
# Version string embedded in the pinned static library; drift detection.
GHOSTTY_KIT_VERSION="1.3.2-main-+24c5671"
# Durable mirror of the pinned tarball, attached to a Conterm release —
# the fork prunes its daily tags after a few weeks, so the pin must not
# depend on the upstream URL surviving. When bumping the pin: attach the
# new tarball to a release (gh release upload) and update this URL with
# the other two constants.
GHOSTTY_KIT_MIRROR="https://github.com/mahdiarfrm/conterm/releases/download/v3.2.2/GhosttyKit-${GHOSTTY_KIT_TAG}.tar.gz"

# Embedded `<semver>-<branch>-+<commit>` marker in the macOS slice's
# static library (name varies across fork builds: libghostty.a,
# libghostty-internal.a, …).
kit_version() {
    local lib
    lib=$(ls "$1"/macos-arm64_x86_64/lib*.a 2>/dev/null | head -1)
    [[ -n "$lib" ]] || return 0
    strings -a "$lib" 2>/dev/null \
        | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+-.*\+[0-9a-f]{7,}$' || true
}

# SwiftPM requires a binary target's static libraries to be lib-prefixed;
# newer fork builds ship the macOS slice as `ghostty-internal.a`. Rename
# it and keep the xcframework manifest in sync.
normalize_lib_prefix() {
    local slice="$1/macos-arm64_x86_64"
    [[ -f "$slice/ghostty-internal.a" ]] || return 0
    mv "$slice/ghostty-internal.a" "$slice/libghostty-internal.a"
    python3 - "$1/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    d = plistlib.load(f)
for lib in d.get("AvailableLibraries", []):
    if lib.get("LibraryPath") == "ghostty-internal.a":
        lib["LibraryPath"] = "libghostty-internal.a"
with open(path, "wb") as f:
    plistlib.dump(d, f)
PY
    echo "OK: renamed ghostty-internal.a -> libghostty-internal.a (SwiftPM lib prefix)"
}

if [[ -d "$XCFRAMEWORK_DIR" ]]; then
    FOUND=$(kit_version "$XCFRAMEWORK_DIR")
    if [[ "$FOUND" == "$GHOSTTY_KIT_VERSION" ]]; then
        echo "GhosttyKit.xcframework present (${FOUND}) — matches pin."
    elif [[ -n "${CI:-}" ]]; then
        # CI must never build (or re-cache) an off-pin xcframework;
        # discard it and re-fetch. Local trees only warn — a developer
        # may be deliberately validating a new build.
        echo "CI: local GhosttyKit.xcframework is '${FOUND:-unknown}', pin is '${GHOSTTY_KIT_VERSION}' — refetching." >&2
        rm -rf "$XCFRAMEWORK_DIR"
    else
        echo "WARN: local GhosttyKit.xcframework is '${FOUND:-unknown}' but the pin is '${GHOSTTY_KIT_VERSION}'." >&2
        echo "WARN: either restore the pinned build or update the pin constants in scripts/setup.sh." >&2
    fi
fi

if [[ ! -d "$XCFRAMEWORK_DIR" ]]; then
    URL="https://github.com/${FORK_REPO}/releases/download/${GHOSTTY_KIT_TAG}/GhosttyKit.xcframework.tar.gz"

    echo "Downloading GhosttyKit.xcframework (${GHOSTTY_KIT_TAG}) …"
    if ! curl -fL --progress-bar -o GhosttyKit.xcframework.tar.gz "$URL"; then
        echo "WARN: ${GHOSTTY_KIT_TAG} is not downloadable from ${FORK_REPO} (daily releases get pruned); trying the mirror." >&2
        if ! curl -fL --progress-bar -o GhosttyKit.xcframework.tar.gz "$GHOSTTY_KIT_MIRROR"; then
            echo "ERROR: the mirror is unavailable too." >&2
            echo "ERROR: restore the tarball from a local/archived copy, or pick a retained tag" >&2
            echo "ERROR: (GHOSTTY_KIT_TAG=build-YYYY-MM-DD bash scripts/setup.sh) and re-test before updating the pin." >&2
            exit 1
        fi
    fi

    echo "Extracting …"
    tar xzf GhosttyKit.xcframework.tar.gz
    rm GhosttyKit.xcframework.tar.gz
    normalize_lib_prefix "$XCFRAMEWORK_DIR"

    FOUND=$(kit_version "$XCFRAMEWORK_DIR")
    if [[ "$FOUND" == "$GHOSTTY_KIT_VERSION" ]]; then
        echo "OK: $(du -sh GhosttyKit.xcframework | cut -f1) (${FOUND})"
    elif [[ -n "${CI:-}" ]]; then
        # A republished tag with different contents must fail loudly in
        # CI before the cache freezes it under the pin's key.
        echo "ERROR: downloaded build reports '${FOUND:-unknown}', pin expects '${GHOSTTY_KIT_VERSION}'." >&2
        exit 1
    else
        echo "WARN: downloaded build reports '${FOUND:-unknown}', pin expects '${GHOSTTY_KIT_VERSION}'." >&2
        echo "WARN: update GHOSTTY_KIT_TAG + GHOSTTY_KIT_VERSION together once the new build is validated." >&2
    fi
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

    # Quiet the progress message in the bundled ssh() wrappers so the
    # terminfo install runs silently. Failure warnings are kept.
    sed -i '' '/Setting up xterm-ghostty terminfo on/d' \
        Resources/ghostty/shell-integration/bash/ghostty.bash \
        Resources/ghostty/shell-integration/zsh/ghostty-integration \
        Resources/ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish \
        Resources/ghostty/shell-integration/elvish/lib/ghostty-integration.elv \
        Resources/ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu 2>/dev/null || true
    echo "OK: stripped 'Setting up xterm-ghostty terminfo' progress echo from wrappers"
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

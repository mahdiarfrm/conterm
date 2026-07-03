# Pinned GhosttyKit build — the single source of truth for the pin.
# Sourced by scripts/setup.sh (prebuilt download) and
# scripts/build-ghostty.sh (from-source build). Bump every constant
# together, deliberately (Conterm's key-encoding, occlusion, and
# selection workarounds assume specific libghostty behavior; re-test
# them per docs/FIXPLAN.md), never by tracking the fork's latest
# release.

GHOSTTY_KIT_REPO="thdxg/ghostty"
# Fork release tag of the prebuilt xcframework. Daily tags get pruned
# after a few weeks; the mirror below outlives them. Override with
# GHOSTTY_KIT_TAG only while validating a new pin.
GHOSTTY_KIT_TAG="${GHOSTTY_KIT_TAG:-build-2026-07-01}"
# `<semver>-<branch>-+<commit>` marker embedded in the static library.
GHOSTTY_KIT_VERSION="1.3.2-main-+24c5671"
# Source commit the pinned build was produced from (the short hash is
# the version marker's suffix).
GHOSTTY_KIT_COMMIT="24c56716f0dfe55911f6f81ee76198a95423851e"
# Zig toolchain the fork's CI builds the pin with.
GHOSTTY_KIT_ZIG="0.15.2"
# Durable mirror of the pinned tarball, attached to a Conterm release —
# the pin must not depend on the upstream URL surviving. When bumping
# the pin: attach the new tarball to a release (gh release upload) and
# update this URL with the constants above.
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

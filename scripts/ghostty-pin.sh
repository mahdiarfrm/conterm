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
GHOSTTY_KIT_TAG="${GHOSTTY_KIT_TAG:-v1.4.0}"
# `<semver>-<branch>+<commit>` marker embedded in the static library
# (builds before 1.4 wrote `<semver>-<branch>-+<commit>`).
GHOSTTY_KIT_VERSION="1.4.0-main+83fb956"
# Source commit the pinned build was produced from (the short hash is
# the version marker's suffix).
GHOSTTY_KIT_COMMIT="83fb95624b0439ee660c2679b43b38c8b63769cd"
# Zig toolchain the pin builds with (v1.4.0 needs at least 0.17.0).
GHOSTTY_KIT_ZIG="0.17.0"
# Durable mirror of the pinned tarball, attached to a Conterm release —
# the pin must not depend on the upstream URL surviving. When bumping
# the pin: attach the new tarball to a release (gh release upload) and
# update this URL with the constants above.
GHOSTTY_KIT_MIRROR="https://github.com/mahdiarfrm/conterm/releases/download/v3.2.2/GhosttyKit-${GHOSTTY_KIT_TAG}.tar.gz"

# Embedded `<semver>-<branch>+<commit>` marker in the macOS slice's
# static library (name varies across fork builds: libghostty.a,
# libghostty-internal.a, …).
# The macOS slice directory is named for what it contains:
# `macos-arm64_x86_64` for a universal build, `macos-arm64` for a native
# one. Both helpers below find it rather than assuming either.
macos_slice() {
    local dir
    for dir in "$1"/macos-arm64_x86_64 "$1"/macos-arm64; do
        [[ -d "$dir" ]] && { echo "$dir"; return 0; }
    done
    return 1
}

kit_version() {
    local lib slice
    slice=$(macos_slice "$1") || return 0
    lib=$(ls "$slice"/lib*.a 2>/dev/null | head -1)
    [[ -n "$lib" ]] || return 0
    strings -a "$lib" 2>/dev/null \
        | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+-.*\+[0-9a-f]{7,}$' || true
}

# SwiftPM requires a binary target's static libraries to be lib-prefixed;
# newer fork builds ship the macOS slice as `ghostty-internal.a`. Rename
# it and keep the xcframework manifest in sync.
normalize_lib_prefix() {
    local slice
    slice=$(macos_slice "$1") || return 0
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

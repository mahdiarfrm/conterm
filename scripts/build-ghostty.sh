#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from source at the pinned commit,
# mirroring the fork's build-ghosttykit.yml recipe — so the pin does
# not depend on any prebuilt download existing. Needs the zig version
# in scripts/ghostty-pin.sh; the first run downloads zig package
# dependencies and compiles both slices, which takes a while.
#
#   bash scripts/build-ghostty.sh            # build + verify only
#   bash scripts/build-ghostty.sh install    # also replace ./GhosttyKit.xcframework
#                                            # and drop a tarball into archive/
set -euo pipefail
cd "$(dirname "$0")/.."

# Pin constants + shared helpers (kit_version, normalize_lib_prefix).
source scripts/ghostty-pin.sh

WORK=".build-ghostty"
OUT="$WORK/macos/GhosttyKit.xcframework"

# Tagless on purpose: ghostty's build derives its version from
# `git describe`, and the fork's `build-YYYY-MM-DD` tags land exactly
# on build commits — a non-vX.Y.Z tag match panics the build. The
# fork's own CI builds from a tagless checkout; mirror that, and name
# the checkout `main` so the embedded version carries the same branch
# label as the pin.
if [[ ! -d "$WORK/.git" ]]; then
    echo "==> cloning ${GHOSTTY_KIT_REPO} (blobless — objects fetch on demand)"
    git clone --filter=blob:none --no-tags "https://github.com/${GHOSTTY_KIT_REPO}.git" "$WORK"
fi
git -C "$WORK" fetch --quiet --no-tags origin "$GHOSTTY_KIT_COMMIT"
git -C "$WORK" tag -l | xargs -r git -C "$WORK" tag -d > /dev/null
git -C "$WORK" checkout --quiet -B main "$GHOSTTY_KIT_COMMIT"
# The version marker embeds `git rev-parse --short`; git widens short
# hashes with history size, so pin the abbreviation to the 7 chars the
# fork's shallow CI checkout produced.
git -C "$WORK" config core.abbrev 7

# Conterm-local patches on top of the pin (patches/ghostty/*.patch),
# applied to a pristine tree so re-runs stay idempotent. The version
# marker doesn't change — patched builds are distinguishable only by
# the archive tarball name and the patches/ dir at build time.
git -C "$WORK" checkout --quiet -- .
for p in patches/ghostty/*.patch; do
    [[ -e "$p" ]] || continue
    echo "==> applying ${p##*/}"
    git -C "$WORK" apply "$PWD/$p"
done

# zig: the pin builds with exactly ${GHOSTTY_KIT_ZIG}. Use the system
# zig when it matches; otherwise fetch the pinned toolchain from
# ziglang.org (shasum-verified against its download index) into the
# checkout, which is gitignored and survives between runs. Lives after
# the clone because `git clone` needs the directory empty.
if ! command -v zig >/dev/null || [[ "$(zig version)" != "$GHOSTTY_KIT_ZIG" ]]; then
    ARCH="$(uname -m)"
    [[ "$ARCH" == "arm64" ]] && ARCH=aarch64
    ZIG_DIR="$WORK/.zig-${GHOSTTY_KIT_ZIG}-${ARCH}"
    if [[ ! -x "$ZIG_DIR/zig" ]]; then
        echo "==> fetching zig ${GHOSTTY_KIT_ZIG} (${ARCH}-macos)"
        INFO="$(curl -fsSL https://ziglang.org/download/index.json \
            | python3 -c "import json,sys; d=json.load(sys.stdin)[\"${GHOSTTY_KIT_ZIG}\"][\"${ARCH}-macos\"]; print(d[\"tarball\"], d[\"shasum\"])")"
        URL="${INFO%% *}"; SHA="${INFO##* }"
        curl -fsSL --retry 3 -o "$WORK/zig.tar.xz" "$URL"
        echo "$SHA  $WORK/zig.tar.xz" | shasum -a 256 -c - > /dev/null
        mkdir -p "$ZIG_DIR"
        tar xf "$WORK/zig.tar.xz" -C "$ZIG_DIR" --strip-components 1
        rm "$WORK/zig.tar.xz"
    fi
    export PATH="$(cd "$ZIG_DIR" && pwd):$PATH"
fi
echo "==> zig $(zig version)"

# zig discovers the SDK by probing `xcrun --show-sdk-path` — even for
# compiling its own build runner, before --sysroot applies — and cannot
# read a libSystem.tbd newer than itself (zig 0.15 against the macOS 26
# SDK fails with every libc symbol undefined). Prefer the Command Line
# Tools SDK matching the pin's CI builder (macos-15) and shim the probe
# so every compilation stage sees the same SDK. Override with
# GHOSTTY_SYSROOT.
SYSROOT="${GHOSTTY_SYSROOT:-}"
if [[ -z "$SYSROOT" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk ]]; then
    SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk
fi
if [[ -n "$SYSROOT" ]]; then
    echo "==> macOS SDK for zig: $SYSROOT"
    # Scope the shim to macOS probes only — the universal xcframework
    # also builds iOS slices, whose SDK probes must reach real xcrun.
    # No --sysroot: ghostty's build prefixes b.sysroot onto the paths
    # it also discovers via xcrun, doubling them.
    SHIM="$PWD/$WORK/.sdk-shim"
    mkdir -p "$SHIM"
    cat > "$SHIM/xcrun" <<EOF
#!/bin/sh
case "\$*" in
  *--sdk\ iphone*) exec /usr/bin/xcrun "\$@";;
  *--show-sdk-path*) echo "$SYSROOT"; exit 0;;
esac
exec /usr/bin/xcrun "\$@"
EOF
    chmod +x "$SHIM/xcrun"
    export PATH="$SHIM:$PATH"
fi

echo "==> zig build (ReleaseFast, universal xcframework) — this takes a while"
(cd "$WORK" && zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
    -Dxcframework-target=universal -Demit-macos-app=false -Demit-themes=true)

normalize_lib_prefix "$OUT"
# Prefix match: the hash suffix's width varies with git's abbreviation,
# so `…-+24c5671` and `…-+24c56716f` are the same pin.
FOUND="$(kit_version "$OUT")"
if [[ "$FOUND" == "$GHOSTTY_KIT_VERSION"* || "$GHOSTTY_KIT_VERSION" == "$FOUND"* ]]; then
    echo "OK: built ${FOUND} at ${OUT}"
else
    echo "ERROR: built '${FOUND:-unknown}', pin expects '${GHOSTTY_KIT_VERSION}'." >&2
    echo "ERROR: the pin constants live in scripts/ghostty-pin.sh — update them together." >&2
    exit 1
fi

if [[ "${1:-}" == "install" ]]; then
    rm -rf GhosttyKit.xcframework
    cp -R "$OUT" GhosttyKit.xcframework
    mkdir -p archive
    tar czf "archive/GhosttyKit-${GHOSTTY_KIT_TAG}-local.tar.gz" GhosttyKit.xcframework
    echo "OK: installed ./GhosttyKit.xcframework + archive/GhosttyKit-${GHOSTTY_KIT_TAG}-local.tar.gz"
fi

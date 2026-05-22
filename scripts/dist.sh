#!/usr/bin/env bash
# Builds Conterm.app and packages it into a shareable zip. Use this
# zip instead of a plain `zip -r` — `ditto -c -k` preserves the
# bundle's extended attributes / signature so the recipient doesn't
# get a corrupted .app.
set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/build.sh

VERSION=$(grep -A1 "CFBundleShortVersionString" Resources/Info.plist \
    | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
OUT="dist/Conterm-${VERSION}.zip"

mkdir -p dist
rm -f "$OUT"

ditto -c -k --keepParent Conterm.app "$OUT"
SIZE=$(du -sh "$OUT" | cut -f1)

cat <<EOF
==================================================
  Packaged: $OUT  ($SIZE)
==================================================

Share that .zip file. Tell the recipient to:
  1. Double-click the zip → Conterm.app appears
  2. Drag Conterm.app to /Applications/
  3. First launch: right-click Conterm.app → Open
     (because we're ad-hoc signed; macOS Gatekeeper
      warns "unidentified developer" until accepted)

For non-technical testers, give them this one-liner
to skip the right-click dance:

  xattr -dr com.apple.quarantine /Applications/Conterm.app

Then double-clicking just works.

EOF

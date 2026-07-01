#!/usr/bin/env bash
# Runs the test suite. With full Xcode installed, plain `swift test`
# works as-is. The Command Line Tools toolchain ships Testing.framework
# outside the compiler's default search paths and omits the Foundation
# cross-import overlay's swiftmodule, so point the build at the
# framework directory and disable cross-import overlay loading.
set -euo pipefail
cd "$(dirname "$0")/.."

FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FW/Testing.framework" \
      && ! -d "$FW/_Testing_Foundation.framework/Modules/_Testing_Foundation.swiftmodule" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        "$@"
fi
exec swift test "$@"

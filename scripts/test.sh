#!/usr/bin/env bash
# Runs the test suite. The suite is pure swift-testing; XCTest bundle
# discovery is disabled because the full-Xcode toolchain preflights the
# .xctest bundle through an x86_64 loader and fails the run with every
# test green. The Command Line Tools toolchain additionally ships
# Testing.framework outside the compiler's default search paths and
# omits the Foundation cross-import overlay's swiftmodule, so point the
# build at the framework directory and disable cross-import overlays.
set -euo pipefail
cd "$(dirname "$0")/.."

FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FW/Testing.framework" \
      && ! -d "$FW/_Testing_Foundation.framework/Modules/_Testing_Foundation.swiftmodule" ]]; then
    exec swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        "$@"
fi
exec swift test --disable-xctest "$@"

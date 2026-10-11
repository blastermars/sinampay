#!/bin/bash
# Runs the tests. Xcode is optional: the Command Line Tools ship Swift
# Testing (not XCTest) in a folder SwiftPM does not search on its own.
# Usage: scripts/test.sh [swift test options]
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
if [ "$(xcode-select -p)" = "$CLT" ]; then
  FRAMEWORKS="$CLT/Library/Developer/Frameworks"
  exec swift test -Xswiftc -F"$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" "$@"
fi
exec swift test "$@"

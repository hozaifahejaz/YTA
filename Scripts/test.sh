#!/bin/bash
# Runs the tests with the Command Line Tools alone. SwiftPM there doesn't always pass the
# Swift Testing macro plugin to the compiler, so this adds its folder when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check-control-coverage.py
plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"

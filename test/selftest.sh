#!/bin/bash
# Round-trips the plist writing against real launchd, using a scratch agent that is
# removed at the end. Worth running before touching PlistWriter: it is the only part
# of the app that changes state outside itself.
#
#   ./test/selftest.sh
#
# It compiles the shipping sources - not a copy of them - alongside a main that drives
# the writer. Only the non-UI files are needed, and naming them explicitly means adding
# a view can never quietly change what is under test. This used to slice the single
# source file by line number, which tied the test to where things happened to sit.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(src/Model.swift src/Agents.swift src/PlistWriter.swift)
for f in "${SOURCES[@]}"; do
  [ -f "$f" ] || { echo "missing $f - did the sources move?" >&2; exit 1; }
done

# Swift only allows top-level statements in a file called main.swift, so the driver
# gets copied under that name rather than being stuck with it in the repo.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp test/selftest-main.swift "$WORK/main.swift"

swiftc -swift-version 5 -o "$WORK/selftest" "${SOURCES[@]}" "$WORK/main.swift"
"$WORK/selftest"

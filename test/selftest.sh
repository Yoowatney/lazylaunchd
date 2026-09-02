#!/bin/bash
# Round-trips the plist writing against real launchd, using a scratch agent that is
# removed at the end. Worth running before touching PlistWriter: it is the only part
# of the app that changes state outside itself.
#
#   ./test/selftest.sh
#
# The model and writer are taken from the app source (everything above the Views
# section) so the test always exercises the shipping code, not a copy of it.
set -euo pipefail
cd "$(dirname "$0")/.."

VIEWS=$(grep -n '^// MARK: - Views' src/LazyLaunchd.swift | cut -d: -f1)
head -n $((VIEWS - 1)) src/LazyLaunchd.swift > /tmp/lr-selftest.swift
cat test/selftest-main.swift >> /tmp/lr-selftest.swift

swiftc -swift-version 5 -o /tmp/lr-selftest-bin /tmp/lr-selftest.swift
/tmp/lr-selftest-bin
rm -f /tmp/lr-selftest.swift /tmp/lr-selftest-bin

#!/bin/bash
# Regenerate icon.icns. Only needed when changing the icon design.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o /tmp/make-icon make-icon.swift
/tmp/make-icon ./icon.iconset
iconutil -c icns icon.iconset -o icon.icns
rm -rf icon.iconset /tmp/make-icon
echo "wrote $(pwd)/icon.icns"

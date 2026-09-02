#!/bin/bash
# Rebuild icon.icns from source-icon.png. Only needed when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o /tmp/make-icon make-icon.swift
/tmp/make-icon ./source-icon.png ./icon.iconset
iconutil -c icns icon.iconset -o icon.icns
rm -rf icon.iconset /tmp/make-icon
echo "wrote $(pwd)/icon.icns"

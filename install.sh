#!/bin/bash
# Build LazyLaunchd.app and install it into ~/Applications.
#
# Needs the Swift compiler, which comes with the Xcode Command Line Tools:
#   xcode-select --install
# Nothing else - SwiftUI ships with macOS, so the built app has no dependencies.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="LazyLaunchd"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

echo "==> Building"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -parse-as-library: the file uses @main rather than top-level statements.
# -swift-version 5: keeps Swift 6's strict concurrency checking out of a UI app
#    that is single-actor by construction.
swiftc -parse-as-library -swift-version 5 -O \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$SRC_DIR/src/$APP_NAME.swift"

echo "==> Writing bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>lazylaunchd</string>
  <key>CFBundleIdentifier</key><string>io.github.lazylaunchd</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

if [ -f "$SRC_DIR/assets/icon.icns" ]; then
  cp "$SRC_DIR/assets/icon.icns" "$APP/Contents/Resources/icon.icns"
fi

# Ad-hoc signature. Without it macOS refuses to launch a freshly built bundle on
# Apple silicon, and the app keeps no state that a stable identity would protect.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Tell Launch Services about it so Spotlight finds it without a logout.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "==> Installed: $APP"
echo "    Open it from Spotlight (⌘Space, \"launchd\") or drag it to the Dock."

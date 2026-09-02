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
# release.sh sets this from the tag; a plain build just says 1.0.
VERSION="${VERSION:-1.0}"

# Declared once and used for BOTH the compiler target and LSMinimumSystemVersion.
# They were separate before, and swiftc defaults its target to whatever the build
# machine runs - so the app claimed macOS 14 while the binary demanded macOS 26, and
# would have refused to launch for everyone who took the claim at face value.
MIN_MACOS="13.0"

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

echo "==> Building (universal, macOS $MIN_MACOS+)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -parse-as-library: the sources use @main rather than top-level statements.
# -swift-version 5: keeps Swift 6's strict concurrency checking out of a UI app
#    that is single-actor by construction.
# Built for both architectures and merged: an arm64-only build simply does not run
# on the Intel Macs that are a good part of the machines still on macOS 13.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
for arch in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -o "$STAGE/$arch" \
    "$SRC_DIR"/src/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$STAGE/arm64" "$STAGE/x86_64"

echo "==> Writing bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>lazylaunchd</string>
  <key>CFBundleIdentifier</key><string>io.github.lazylaunchd</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
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

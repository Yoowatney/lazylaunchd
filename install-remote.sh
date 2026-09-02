#!/bin/bash
# One-line installer. Downloads the latest release and puts the app in ~/Applications:
#
#   curl -fsSL https://raw.githubusercontent.com/Yoowatney/lazylaunchd/main/install-remote.sh | bash
#
# It does not need git, Xcode, or Homebrew - just curl and a Mac.
#
# It also clears the quarantine flag on the downloaded app. That is what normally
# triggers "the developer cannot be verified", and skipping it is the difference
# between this working and sending you into System Settings. It is only reasonable
# because you ran this command on purpose; nothing here touches anything else.
set -euo pipefail

REPO="Yoowatney/lazylaunchd"
APP_NAME="LazyLaunchd"
DEST="${LAZYLAUNCHD_DEST:-$HOME/Applications}"
URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.zip"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only - launchd is a macOS thing."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] 2>/dev/null || die "needs macOS 14 or newer (found $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading the latest release"
curl -fsSL --retry 2 -o "$TMP/$APP_NAME.zip" "$URL" \
  || die "could not download $URL — is there a published release yet?"

say "Unpacking"
# ditto, matching how the zip was made; plain unzip mangles the bundle.
ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/out" || die "the download looks corrupt."
[ -d "$TMP/out/$APP_NAME.app" ] || die "unexpected archive layout."

# Downloaded files carry com.apple.quarantine. Clearing it is the whole point of
# installing this way rather than by hand.
xattr -dr com.apple.quarantine "$TMP/out/$APP_NAME.app" 2>/dev/null || true

say "Installing to $DEST"
mkdir -p "$DEST"
if [ -e "$DEST/$APP_NAME.app" ]; then
  # Replacing a running app leaves it in a strange state, so close it first.
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST/$APP_NAME.app"
fi
mv "$TMP/out/$APP_NAME.app" "$DEST/$APP_NAME.app"

# So Spotlight finds it without a logout.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/$APP_NAME.app" 2>/dev/null || true

version=$(plutil -extract CFBundleShortVersionString raw "$DEST/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "?")
say "Installed lazylaunchd $version to $DEST/$APP_NAME.app"
echo "    Open it with:  open -a $APP_NAME"
echo "    Or from Spotlight: ⌘Space, \"lazylaunchd\""

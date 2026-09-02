#!/bin/bash
# Build a release zip and publish it as a GitHub Release.
#
#   ./release.sh v1.0.0
#   ./release.sh v1.0.0 --draft     # stage it without publishing
#
# The zip holds the built .app so people can download and run it without the Xcode
# tools. It is ad-hoc signed, not notarized, so macOS will ask the downloader to
# approve it once - see the Download section of the README.
set -euo pipefail

cd "$(dirname "$0")"
TAG="${1:-}"
shift || true

if [ -z "$TAG" ]; then
  echo "usage: $0 <tag> [gh release create flags]" >&2
  echo "  e.g. $0 v1.0.0" >&2
  exit 2
fi
case "$TAG" in
  v[0-9]*) ;;
  *) echo "tag should look like v1.0.0, got '$TAG'" >&2; exit 2 ;;
esac

command -v gh >/dev/null || { echo "gh not found: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty - commit before releasing" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists" >&2
  exit 1
fi

VERSION_NUM="${TAG#v}"
BUILD="build"
# Deliberately unversioned: it makes /releases/latest/download/LazyLaunchd.zip a
# stable URL, which is what install-remote.sh and the README one-liner rely on.
ZIP="$BUILD/LazyLaunchd.zip"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Checking it still passes its own tests"
./test/selftest.sh >/dev/null

echo "==> Building $TAG"
VERSION="$VERSION_NUM" ./install.sh "$(pwd)/$BUILD" >/dev/null

# v1.0.1 shipped claiming macOS 14 while the binary was built for the machine that
# compiled it, so it would not have launched anywhere but that machine. Nothing about
# that is visible without looking, hence looking.
echo "==> Checking the binary matches what the bundle claims"
BIN="$BUILD/LazyLaunchd.app/Contents/MacOS/LazyLaunchd"
CLAIMED=$(plutil -extract LSMinimumSystemVersion raw "$BUILD/LazyLaunchd.app/Contents/Info.plist")
ACTUAL=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}' | sort -u)
[ "$(echo "$ACTUAL" | wc -l)" -eq 1 ] || { echo "slices disagree on minos: $ACTUAL" >&2; exit 1; }
[ "$CLAIMED" = "$ACTUAL" ] || {
  echo "Info.plist says macOS $CLAIMED but the binary needs $ACTUAL" >&2; exit 1; }
ARCHS=$(lipo -archs "$BIN")
case "$ARCHS" in
  *arm64*) ;;
  *) echo "no arm64 slice: $ARCHS" >&2; exit 1 ;;
esac
case "$ARCHS" in
  *x86_64*) ;;
  *) echo "no x86_64 slice — Intel Macs could not run this: $ARCHS" >&2; exit 1 ;;
esac
echo "    macOS $CLAIMED+, $ARCHS"

# ditto, not zip: it preserves the bundle's resource forks and symlinks, which a
# plain zip mangles badly enough that the downloaded app refuses to launch.
echo "==> Packing"
ditto -c -k --sequesterRsrc --keepParent "$BUILD/LazyLaunchd.app" "$ZIP"
echo "    $ZIP  ($(du -h "$ZIP" | cut -f1))"

echo "==> Tagging and publishing"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
  --title "$TAG" \
  --notes "### Install

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/Yoowatney/lazylaunchd/main/install-remote.sh | bash
\`\`\`

Or download \`LazyLaunchd.zip\` below, unzip it, and drag **LazyLaunchd.app** to your
Applications folder. Downloading by hand means macOS blocks the first launch, since the
app is ad-hoc signed rather than notarized — open **System Settings → Privacy & Security**,
scroll down, and press **Open Anyway**. The script above avoids that by clearing the
quarantine flag on something you explicitly asked to install.

Prefer to build it yourself? \`./install.sh\` needs only the Xcode Command Line Tools." \
  "$@"

echo "==> Done: $(gh release view "$TAG" --json url --jq .url)"

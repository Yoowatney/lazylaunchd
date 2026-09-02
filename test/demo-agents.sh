#!/bin/bash
# Sets up a folder of sample agents and opens the app against it, so a screenshot
# shows plausible jobs instead of whatever is really installed on your machine.
#
#   ./test/demo-agents.sh          set up and launch
#   ./test/demo-agents.sh clean    unload and remove everything
#
# Nothing here touches ~/Library/LaunchAgents. The samples are bootstrapped from
# the demo folder, so their status dots and exit codes are real rather than faked.
set -euo pipefail

DEMO="${TMPDIR:-/tmp}/lazylaunchd-demo"
UID_="$(id -u)"
LABELS=(
  com.example.backup-photos
  com.example.sync-notes
  com.example.rotate-logs
  com.example.fetch-feeds
  com.example.reindex-search
)

unload_all() {
  for l in "${LABELS[@]}"; do
    launchctl bootout "gui/$UID_/$l" 2>/dev/null || true
  done
}

if [ "${1:-}" = "clean" ]; then
  unload_all
  rm -rf "$DEMO"
  echo "removed $DEMO and unloaded the sample agents"
  exit 0
fi

unload_all
rm -rf "$DEMO"
mkdir -p "$DEMO"

# One script behind all of them; each is invoked with its own message and exit code.
cat > "$DEMO/task.sh" <<'TASK'
#!/bin/bash
# $1 = message, $2 = exit code
echo "$(date '+%H:%M:%S')  starting ${LABEL:-task}"
sleep 1
echo "$(date '+%H:%M:%S')  $1"
sleep 1
echo "$(date '+%H:%M:%S')  done (exit ${2:-0})"
exit "${2:-0}"
TASK
chmod +x "$DEMO/task.sh"

# label | schedule-xml | message | exit code
make_agent() {
  local label="$1" sched="$2" msg="$3" code="$4"
  cat > "$DEMO/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEMO/task.sh</string>
    <string>$msg</string>
    <string>$code</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>LABEL</key><string>$label</string></dict>
  <key>StandardOutPath</key><string>$DEMO/$label.log</string>
  <key>StandardErrorPath</key><string>$DEMO/$label.log</string>
$sched
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$UID_" "$DEMO/$label.plist" 2>/dev/null || true
}

daily() { printf '  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>%s</integer><key>Minute</key><integer>%s</integer></dict>' "$1" "$2"; }
every() { printf '  <key>StartInterval</key><integer>%s</integer>' "$1"; }

make_agent com.example.backup-photos  "$(daily 2 0)"    "copied 1,284 new photos to the NAS" 0
make_agent com.example.sync-notes     "$(every 3600)"   "synced 37 notes, no conflicts"      0
make_agent com.example.rotate-logs    "$(daily 4 30)"   "rotated 6 logs, freed 214 MB"       0
make_agent com.example.fetch-feeds    "$(every 21600)"  "feed timed out after 30s"           1
make_agent com.example.reindex-search ""                "rebuilt index over 9,412 files"     0

# Run two of them so the list shows real exit codes - one clean, one failing.
launchctl start com.example.backup-photos 2>/dev/null || true
launchctl start com.example.fetch-feeds 2>/dev/null || true
sleep 4

echo "sample agents in $DEMO"
launchctl list | grep example || true
echo
echo "Launching the app against the demo folder."
echo "Select an agent and press Run, then take the screenshot."
echo "When you're done:  ./test/demo-agents.sh clean"

APP="$HOME/Applications/LazyLaunchd.app/Contents/MacOS/LazyLaunchd"
[ -x "$APP" ] || { echo "build it first: ./install.sh" >&2; exit 1; }
LAZYLAUNCHD_AGENTS_DIR="$DEMO" "$APP" &

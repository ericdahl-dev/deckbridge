#!/bin/bash
# Launch smoke check for the firmware updater (#734): the built app starts with nothing plugged in, logs its first
# look and quits cleanly. With --smoke the app quits on its own right after its first look. The check passes when
# it quits with status 0 within the timeout, and the log lines it wrote in this run are exactly its first look,
# "deck panel not found, LC6000 not found". A device line from the finder would mean it found, and maybe opened, a
# device.
#
# Usage: scripts/updater_smoke.sh ["path/to/DeckBridge Firmware Updater.app"]
# Default app: the Release ad-hoc build from .github/workflows/ci.yml (Apps/FirmwareUpdater/build).
#
# It needs nothing plugged in: it reads the USB device list (ioreg) first, and stops without starting the app if a
# deck panel or an LC6000 is there, since the app's first look would open a panel's serial port. It never lists or
# opens a serial port itself.
#   UPDATER_SMOKE_TIMEOUT  seconds to wait for the app to quit (default 60)
#   UPDATER_LOG            the app's log (default ~/Library/Logs/FirmwareUpdater/updater.log)
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-Apps/FirmwareUpdater/build/Build/Products/Release/DeckBridge Firmware Updater.app}"
# The binary has the app's name (#763: PRODUCT_NAME names both).
binary="$app/Contents/MacOS/$(basename "$app" .app)"
[ -x "$binary" ] || { echo "No app at $app. Build it first (see .github/workflows/ci.yml)."; exit 2; }
log="${UPDATER_LOG:-$HOME/Library/Logs/FirmwareUpdater/updater.log}"
timeout="${UPDATER_SMOKE_TIMEOUT:-60}"
expected="first look: deck panel not found, LC6000 not found"

# USB vendors the app looks for: 0x1A86 the panel's CH340 serial chip, 0x303A Espressif (the ESP32-S3's own USB),
# 0x15E4 inMusic (the LC6000), 0x0483 ST (an LC6000 chip in update mode). ioreg prints them in decimal.
if ioreg -p IOUSB -l -w0 | grep -Eq '"idVendor" = (6790|12346|5604|1155)$'; then
  echo "This check needs nothing plugged in: a deck panel or an LC6000 is on USB. Unplug it, or let CI run it."
  exit 2
fi

before=0
[ -f "$log" ] && before=$(wc -c < "$log")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Its own output goes to a file, printed on a failure, so nothing it leaves running holds this script's output open.
"$binary" --smoke > "$work/app.out" 2>&1 &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge $((timeout * 10)) ]; then
    kill "$pid" 2>/dev/null || true
    echo "The updater didn't quit within ${timeout} s of starting with --smoke."; cat "$work/app.out"
    exit 1
  fi
  sleep 0.1
  waited=$((waited + 1))
done
status=0
wait "$pid" || status=$?
[ "$status" -eq 0 ] || { echo "The updater quit with status $status."; cat "$work/app.out"; exit 1; }

written=""
[ -f "$log" ] && written="$(tail -c +$((before + 1)) "$log")"
echo "Log lines from this run:"
echo "$written"
# Each line is "<timestamp> <text>": exactly one line, and it's the first look with nothing found.
texts="$(sed -E 's/^[^ ]+ //' <<<"$written")"
[ "$texts" = "$expected" ] || { echo "Expected only: $expected"; exit 1; }
echo "ok: the updater started, logged its first look with nothing found, and quit cleanly."

#!/bin/sh
# Renders the Mac App Store screenshots (#29) from the current checkout: builds the Debug app, renders its snapshots in
# dark mode (panels at 8x, windows at 4x), and frames each with its caption at 2880×1800 and 1440×900, flat RGB.
# The layout and colors are AppStoreFrame's (tested in ControllerBridgeRenderTests); this only runs the steps.
#   scripts/appstore_screenshots.sh <out-dir>
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(cd "${1:?Usage: scripts/appstore_screenshots.sh <out-dir>}" 2>/dev/null && pwd || { mkdir -p "$1" && cd "$1" && pwd; })"
cd "$root"

xcodegen generate -q
xcodebuild -project ControllerBridge.xcodeproj -scheme ControllerBridge -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY=- build -quiet
app="build/Build/Products/Debug/ControllerBridge.app/Contents/MacOS/ControllerBridge"
shots="$HOME/Library/Containers/dev.ericdahl.ControllerBridge/Data/tmp"
rm -rf "$shots/appstore-8x" "$shots/appstore-4x"
SNAPSHOT_APPEARANCE=dark SNAPSHOT_SCALE=8 "$app" --render-snapshots appstore-8x >/dev/null
SNAPSHOT_APPEARANCE=dark SNAPSHOT_SCALE=4 "$app" --render-snapshots appstore-4x >/dev/null

frames="swift run --quiet --package-path Packages/ControllerBridgeKit appstore-frames"
frame() { $frames "$shots/$1" "$2" "$3" "$out/$4" >/dev/null; echo "$4"; }
frame appstore-8x/panel-connected.png "Your controller in Syndicate" \
  "Jog, 14-bit pitch, hot cues in their colors, and LEDs that follow every deck." 1-panel
frame appstore-4x/diagnostics-midi-monitor.png "Check every control" \
  "Every MIDI message, and what goes to and from Syndicate." 2-diagnostics
frame appstore-4x/setup-guide-connected.png "Set up Syndicate in four steps" \
  "A guide walks you through Syndicate's OSC settings." 3-setup
frame appstore-8x/panel-demo.png "Try it with no hardware" \
  "A built-in demo controller shows the bridge at work." 4-demo
frame appstore-4x/settings-decks.png "Set it up your way" \
  "Deck colors and ring colors, in Settings." 5-settings
frame appstore-4x/diagnostics-jog-display-demo.png "See what your jog display shows" \
  "Diagnostics previews the LC6000's jog screen, live, for each deck." 6-jog-display

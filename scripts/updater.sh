#!/usr/bin/env bash
# Builds the firmware updater (Apps/FirmwareUpdater, #685) and opens it: XcodeGen, then a Debug xcodebuild.
# `scripts/updater.sh build` builds without opening. It shares nothing at runtime with DeckBridge.
set -euo pipefail
cd "$(dirname "$0")/../Apps/FirmwareUpdater"
command -v xcodegen >/dev/null || { echo "Needs XcodeGen: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q
xcodebuild -project FirmwareUpdater.xcodeproj -scheme FirmwareUpdater -configuration Debug -derivedDataPath build \
    -quiet build
app=build/Build/Products/Debug/FirmwareUpdater.app
[[ "${1:-}" == build ]] || open "$app"
echo "$app"

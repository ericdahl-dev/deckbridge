#!/bin/sh
# Checks what App Store Connect refuses a Mac build for, before any upload: the bundle id and display name, version and build numbers, the export
# compliance and category keys, no Dock icon, the privacy manifest, the app icon, and the sandbox entitlements (network, and the serial port for the deck panel's cable).
# Ported from ShowRecorder's preflight, Mac only.
#   scripts/preflight.sh path/to/ControllerBridge.xcarchive   (or path/to/ControllerBridge.app)
# Tested by scripts/test-preflight.sh.
set -eu

target="${1:?usage: scripts/preflight.sh <app or xcarchive>}"
fail=0
bad() { echo "FAIL: $1"; fail=1; }
ok() { echo "ok:   $1"; }

case "$target" in
  *.xcarchive) app=$(ls -d "$target"/Products/Applications/*.app 2>/dev/null | head -n 1) ;;
  *) app="$target" ;;
esac
[ -n "$app" ] && [ -f "$app/Contents/Info.plist" ] || { echo "No Mac app found at $target"; exit 2; }
echo "== Checking $app"

plist="$app/Contents/Info.plist"
resources="$app/Contents/Resources"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

# The App Store Connect record is for this bundle id; the release workflow passes the same one as BUNDLE_ID.
expected_id="${BUNDLE_ID:-dev.ericdahl.ControllerBridge}"
bundle_id=$(read_key CFBundleIdentifier)
[ "$bundle_id" = "$expected_id" ] && ok "bundle id $bundle_id" || bad "CFBundleIdentifier is '$bundle_id', not $expected_id"

# The name people see (DeckBridge, #29); the product and the .app stay ControllerBridge.
display_name=$(read_key CFBundleDisplayName)
case "$display_name" in ''|*'$('*) bad "CFBundleDisplayName is '$display_name'" ;; *) ok "display name $display_name" ;; esac

version=$(read_key CFBundleShortVersionString)
build=$(read_key CFBundleVersion)
case "$version" in ''|*'$('*) bad "CFBundleShortVersionString is '$version'" ;; *) ok "version $version" ;; esac
if echo "$build" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then ok "build number $build"
else bad "CFBundleVersion is '$build' (must be 1 to 3 dot-separated whole numbers)"; fi

compliance=$(read_key ITSAppUsesNonExemptEncryption)
case "$compliance" in true|false) ok "ITSAppUsesNonExemptEncryption = $compliance" ;;
  *) bad "ITSAppUsesNonExemptEncryption is missing from Info.plist" ;; esac

category=$(read_key LSApplicationCategoryType)
[ -n "$category" ] && ok "LSApplicationCategoryType = $category" || bad "LSApplicationCategoryType is missing (the Mac App Store needs it)"

# The Local Network prompt's words (#19, #618): macOS 15 and later ask before the feedback listener on all networks or
# the display feed to a deck panel can reach the LAN; without them the sends are refused.
[ -n "$(read_key NSLocalNetworkUsageDescription)" ] && ok "NSLocalNetworkUsageDescription is set" \
  || bad "NSLocalNetworkUsageDescription is missing (macOS can't ask for local network access)"

# A menu-bar app: no Dock icon.
[ "$(read_key LSUIElement)" = true ] && ok "LSUIElement = true" || bad "LSUIElement is not true (the app would show in the Dock)"

manifest="$resources/PrivacyInfo.xcprivacy"
if [ -f "$manifest" ]; then
  plutil -lint "$manifest" >/dev/null && ok "privacy manifest is valid" || bad "PrivacyInfo.xcprivacy is not a valid plist"
  # The app tracks nothing and collects nothing, and its one required-reason API is UserDefaults, for its own settings.
  read_manifest() { /usr/libexec/PlistBuddy -c "Print :$1" "$manifest" 2>/dev/null || true; }
  [ "$(read_manifest NSPrivacyTracking)" = false ] && ok "privacy manifest: no tracking" \
    || bad "NSPrivacyTracking must be false (the app tracks nobody)"
  [ -z "$(read_manifest NSPrivacyCollectedDataTypes:0)" ] && ok "privacy manifest: no collected data" \
    || bad "NSPrivacyCollectedDataTypes must be empty (the app collects nothing)"
  if plutil -convert xml1 -o - "$manifest" | tr -d ' \t\n' \
    | grep -q '<string>NSPrivacyAccessedAPICategoryUserDefaults</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string>'; then
    ok "privacy manifest: UserDefaults with reason CA92.1"
  else
    bad "the privacy manifest must declare UserDefaults with reason CA92.1 (the app's own settings)"
  fi
else
  bad "PrivacyInfo.xcprivacy is not in the app bundle"
fi

# The UI fonts (#171), Geist and Geist Mono under SIL OFL 1.1: a missing one would fall back to the system font
# silently, and the license must ship with them.
fonts="$resources/Fonts"
for font in Geist-Regular.ttf Geist-Medium.ttf Geist-SemiBold.ttf Geist-Bold.ttf GeistMono-Regular.ttf GeistMono-Medium.ttf GeistMono-SemiBold.ttf Geist-OFL.txt; do
  [ -f "$fonts/$font" ] && ok "bundled $font" || bad "Fonts/$font is not in the app bundle"
done

if [ -n "$(read_key CFBundleIconName)" ] && [ -f "$resources/Assets.car" ]; then ok "app icon compiled into Assets.car"
else bad "no compiled app icon (CFBundleIconName or Assets.car missing)"; fi

# The Mac App Store refuses an app without the sandbox; the bridge needs to send OSC and to listen for feedback.
# A signed bundle is sealed (_CodeSignature); an executable signed on its own, as the linker does, isn't enough.
if [ -d "$app/Contents/_CodeSignature" ] && codesign -d "$app" >/dev/null 2>&1; then
  entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
  # device.serial: the display feed over the USB cable opens the deck panel's serial port (#667).
  for key in app-sandbox network.client network.server device.serial; do
    printf '%s' "$entitlements" | grep -q "com.apple.security.$key</key><true/>" \
      && ok "signed with com.apple.security.$key" || bad "signed without com.apple.security.$key"
  done
else
  bad "the app is not signed, so its entitlements can't be checked"
fi

[ "$fail" = 0 ] && echo "== Preflight passed" || { echo "== Preflight failed"; exit 1; }

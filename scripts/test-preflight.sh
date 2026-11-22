#!/bin/sh
# Tests scripts/preflight.sh against fake Mac app bundles: a good one passes, and each thing App Store Connect would
# refuse fails with its own FAIL line. No Xcode build and no network.
#   scripts/test-preflight.sh
set -eu
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# A Mac app that passes: version and build, the compliance and category keys, no Dock icon, a privacy manifest, a
# compiled icon, and an ad hoc signature with the sandbox and network entitlements.
make_app() {
  app="$work/$1/ControllerBridge.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /usr/bin/true "$app/Contents/MacOS/ControllerBridge"
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.ericdahl.ControllerBridge" \
    -c "Add :CFBundleExecutable string ControllerBridge" \
    -c "Add :CFBundleShortVersionString string 1.0.0" \
    -c "Add :CFBundleVersion string 12.1" \
    -c "Add :ITSAppUsesNonExemptEncryption bool false" \
    -c "Add :LSApplicationCategoryType string public.app-category.music" \
    -c "Add :LSUIElement bool true" \
    -c "Add :CFBundleDisplayName string DeckBridge" \
    -c "Add :NSLocalNetworkUsageDescription string 'DeckBridge sends to a deck panel on your network.'" \
    -c "Add :CFBundleIconName string AppIcon" "$plist" >/dev/null
  cp App/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
  echo icon > "$app/Contents/Resources/Assets.car"
  mkdir -p "$app/Contents/Resources/Fonts"
  for font in Geist-Regular Geist-Medium Geist-SemiBold Geist-Bold GeistMono-Regular GeistMono-Medium GeistMono-SemiBold; do
    echo font > "$app/Contents/Resources/Fonts/$font.ttf"; done
  echo license > "$app/Contents/Resources/Fonts/Geist-OFL.txt"
  cat > "$work/$1.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.device.serial</key><true/>
</dict></plist>
PLIST
  echo "$app"
}

sign() { codesign -f -s - --entitlements "$2" "$1" 2>/dev/null; }

# expect_pass NAME APP / expect_fail NAME APP "text a FAIL line must contain"
expect_pass() {
  if out="$(scripts/preflight.sh "$2" 2>&1)"; then echo "ok:   $1"; else
    echo "FAIL: $1: preflight failed on a good app"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1)); fi
}
expect_fail() {
  if out="$(scripts/preflight.sh "$2" 2>&1)"; then
    echo "FAIL: $1: preflight passed"; failures=$((failures + 1))
  elif printf '%s\n' "$out" | grep '^FAIL: ' | grep -qF "$3"; then echo "ok:   $1"
  else echo "FAIL: $1: no FAIL line naming '$3'"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1)); fi
}

app=$(make_app good); sign "$app" "$work/good.entitlements"
expect_pass "a good app passes" "$app"

app=$(make_app version); /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString $(MARKETING_VERSION)' "$app/Contents/Info.plist"
sign "$app" "$work/version.entitlements"
expect_fail "an unexpanded version fails" "$app" "CFBundleShortVersionString"

app=$(make_app build); /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 12.1-dirty' "$app/Contents/Info.plist"
sign "$app" "$work/build.entitlements"
expect_fail "a build number that isn't numbers fails" "$app" "CFBundleVersion"

app=$(make_app bundleid); /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.ericdahl.DeckBridge' "$app/Contents/Info.plist"
sign "$app" "$work/bundleid.entitlements"
expect_fail "a bundle id App Store Connect doesn't know fails" "$app" "CFBundleIdentifier"

for key in ITSAppUsesNonExemptEncryption LSApplicationCategoryType LSUIElement CFBundleDisplayName NSLocalNetworkUsageDescription; do
  app=$(make_app "$key"); /usr/libexec/PlistBuddy -c "Delete :$key" "$app/Contents/Info.plist"
  sign "$app" "$work/$key.entitlements"
  expect_fail "a missing $key fails" "$app" "$key"
done

# The UI fonts (#171): a missing one would fall back to the system font without a word.
app=$(make_app font); rm "$app/Contents/Resources/Fonts/GeistMono-Medium.ttf"; sign "$app" "$work/font.entitlements"
expect_fail "a missing bundled font fails" "$app" "GeistMono-Medium.ttf"

app=$(make_app fontbold); rm "$app/Contents/Resources/Fonts/Geist-Bold.ttf"; sign "$app" "$work/fontbold.entitlements"
expect_fail "a missing bold weight fails" "$app" "Geist-Bold.ttf"

app=$(make_app fontlicense); rm "$app/Contents/Resources/Fonts/Geist-OFL.txt"; sign "$app" "$work/fontlicense.entitlements"
expect_fail "fonts without their license fail" "$app" "Geist-OFL.txt"

app=$(make_app manifest); rm "$app/Contents/Resources/PrivacyInfo.xcprivacy"; sign "$app" "$work/manifest.entitlements"
expect_fail "a missing privacy manifest fails" "$app" "PrivacyInfo.xcprivacy"

# The manifest's content (#29): no tracking, no collected data, and the UserDefaults reason the app needs.
manifest_of() { echo "$1/Contents/Resources/PrivacyInfo.xcprivacy"; }
app=$(make_app tracking); plutil -replace NSPrivacyTracking -bool true "$(manifest_of "$app")"; sign "$app" "$work/tracking.entitlements"
expect_fail "a manifest that declares tracking fails" "$app" "NSPrivacyTracking"

app=$(make_app collected); plutil -insert NSPrivacyCollectedDataTypes.0 -xml '<dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeOtherUsageData</string></dict>' "$(manifest_of "$app")"
sign "$app" "$work/collected.entitlements"
expect_fail "a manifest that declares collected data fails" "$app" "NSPrivacyCollectedDataTypes"

app=$(make_app defaults); plutil -replace NSPrivacyAccessedAPITypes -xml '<array/>' "$(manifest_of "$app")"; sign "$app" "$work/defaults.entitlements"
expect_fail "a manifest without the UserDefaults reason fails" "$app" "UserDefaults"

app=$(make_app icon); rm "$app/Contents/Resources/Assets.car"; sign "$app" "$work/icon.entitlements"
expect_fail "a missing compiled icon fails" "$app" "app icon"

# The display feed over the USB cable (#667) opens the deck panel's serial port, which the sandbox refuses without it.
for entitlement in app-sandbox network.client network.server device.serial; do
  name="no-${entitlement}"
  app=$(make_app "$name")
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.$entitlement" "$work/$name.entitlements"
  sign "$app" "$work/$name.entitlements"
  expect_fail "signed without $entitlement fails" "$app" "com.apple.security.$entitlement"
done

app=$(make_app unsigned)
expect_fail "an unsigned app fails (the entitlements can't be checked)" "$app" "not signed"

# An archive is checked through the app inside it.
archive="$work/ControllerBridge.xcarchive"; mkdir -p "$archive/Products/Applications"
app=$(make_app archived); sign "$app" "$work/archived.entitlements"; mv "$app" "$archive/Products/Applications/"
expect_pass "an .xcarchive is checked through its app" "$archive"

[ "$failures" = 0 ] && echo "== preflight tests passed" || { echo "== $failures preflight test(s) failed"; exit 1; }

#!/usr/bin/env bash
# Build the native companion with working Keychain entitlements.
# Simulator: bash scripts/build-companion.sh simulator <simulator-udid>
# Device: TAPLYNE_DEVELOPMENT_TEAM=<team> bash scripts/build-companion.sh device <device-udid>
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-simulator}"
DEVICE="${2:-}"
xcodegen generate --quiet
if [[ "$MODE" == simulator ]]; then
  DESTINATION='generic/platform=iOS Simulator'
  [[ -z "$DEVICE" ]] || DESTINATION="platform=iOS Simulator,id=$DEVICE"
  xcodebuild -project Taplyne.xcodeproj -scheme TaplyneCompanion -configuration Debug \
    -destination "$DESTINATION" -derivedDataPath .build/Companion -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
  echo "$PWD/.build/Companion/Build/Products/Debug-iphonesimulator/TaplyneCompanion.app"
elif [[ "$MODE" == device ]]; then
  : "${TAPLYNE_DEVELOPMENT_TEAM:?Set TAPLYNE_DEVELOPMENT_TEAM to your Apple development team.}"
  : "${DEVICE:?Pass the paired physical device UDID.}"
  xcodebuild -project Taplyne.xcodeproj -scheme TaplyneCompanion -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath .build/CompanionDevice -quiet \
    "DEVELOPMENT_TEAM=$TAPLYNE_DEVELOPMENT_TEAM" -allowProvisioningUpdates build
  echo "$PWD/.build/CompanionDevice/Build/Products/Debug-iphoneos/TaplyneCompanion.app"
else
  echo 'Use simulator or device.' >&2
  exit 2
fi

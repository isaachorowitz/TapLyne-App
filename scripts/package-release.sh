#!/usr/bin/env bash
# Package an already built universal Release app. Notarize and staple before publication.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$HOME/Assets/taplyne/files/release}"
mkdir -p "$RELEASE_OUTPUT_DIR"
APP="$RELEASE_OUTPUT_DIR/Taplyne.app"
ditto .build/DerivedData/Build/Products/Release/Taplyne.app "$APP"
# Remove local compiler/module paths while retaining runtime symbols.
xcrun strip -S "$APP/Contents/MacOS/Taplyne"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
printf '%s\n' 'Source: https://github.com/isaachorowitz/taplyne-mac' 'License: AGPL-3.0-only' > "$APP/Contents/Resources/SOURCE.txt"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements Taplyne/Taplyne.entitlements "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_OUTPUT_DIR/Taplyne-notary.zip"
printf '%s\n' "$RELEASE_OUTPUT_DIR/Taplyne-notary.zip"

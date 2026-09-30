#!/usr/bin/env bash
# Builds Taplyne.app into ./build/ and prints its path.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
shift "$(( $# > 0 ? 1 : 0 ))"
xcodegen generate --quiet
xcodebuild \
    -project Taplyne.xcodeproj \
    -scheme Taplyne \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath .build/DerivedData \
    -quiet \
    "$@" \
    build
APP=".build/DerivedData/Build/Products/$CONFIG/Taplyne.app"
mkdir -p build
rm -rf "build/Taplyne.app"
cp -R "$APP" build/
codesign --verify --strict build/Taplyne.app
echo "$(pwd)/build/Taplyne.app"

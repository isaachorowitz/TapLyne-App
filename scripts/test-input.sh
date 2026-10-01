#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path Packages/TaplyneServer --quiet
BINARY_PATH="$(swift build --package-path Packages/TaplyneServer --show-bin-path)"
LINK=()
MODULE_PATH="$BINARY_PATH/Modules"
if [[ -f "$BINARY_PATH/libTaplyneServer.a" ]]; then
  MODULE_PATH="$BINARY_PATH"
  LINK+=("$BINARY_PATH/libTaplyneServer.a")
else
  while IFS= read -r object; do LINK+=("$object"); done < <(find "$BINARY_PATH/TaplyneServer.build" -name '*.swift.o' -type f)
fi
mkdir -p .build/input-tests
swiftc -parse-as-library -I "$MODULE_PATH" \
  Taplyne/Bluetooth/HIDReports.swift Taplyne/Bluetooth/HIDProfile.swift \
  Taplyne/Control/KeyMap.swift Taplyne/Control/PointerLocator.swift \
  Taplyne/Control/PhoneDriver.swift Taplyne/Control/PhoneTextInput.swift \
  Taplyne/Control/PhoneNavigationInput.swift Taplyne/Control/ClipboardBridge.swift Taplyne/Control/WebDriverConnection.swift \
  Tests/Control/InputSafetyTests.swift "${LINK[@]}" \
  -o .build/input-tests/input-safety
.build/input-tests/input-safety

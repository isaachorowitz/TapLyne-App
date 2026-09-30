#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/bluetooth-tests
swiftc Taplyne/Bluetooth/HIDReports.swift Taplyne/Bluetooth/HIDProfile.swift \
  Taplyne/Bluetooth/HIDSession.swift Taplyne/Bluetooth/SDPRecord.swift Tests/Bluetooth/HIDSessionTests.swift \
  -o .build/bluetooth-tests/hid-session
.build/bluetooth-tests/hid-session
clang -fobjc-arc -framework Foundation -I Taplyne/Bluetooth \
  Taplyne/Bluetooth/ClassicChannels.m Tests/Bluetooth/ClassicChannelsTests.m \
  -o .build/bluetooth-tests/classic-channels
.build/bluetooth-tests/classic-channels
swiftc Taplyne/Control/PointerLocator.swift Tests/Control/PointerLocatorTests.swift \
  -o .build/bluetooth-tests/pointer-locator
.build/bluetooth-tests/pointer-locator

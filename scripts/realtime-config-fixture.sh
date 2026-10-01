#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/voice-tests
xcrun swiftc -parse-as-library Shared/VoicePolicies.swift Shared/RealtimeTurnFence.swift Shared/RealtimeVoice.swift Tests/Voice/RealtimeConfigFixture.swift -o .build/voice-tests/realtime-config-fixture
exec .build/voice-tests/realtime-config-fixture "$@"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/voice-tests
xcrun swiftc -parse-as-library Shared/VoicePolicies.swift Shared/RealtimeTurnFence.swift Tests/Voice/VoiceStateTests.swift -o .build/voice-tests/voice-state-tests
.build/voice-tests/voice-state-tests
xcrun swiftc -typecheck Shared/VoicePolicies.swift Shared/RealtimeTurnFence.swift Shared/ConversationSpeech.swift Shared/RealtimeVoice.swift

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/relay-tests
swiftc -parse-as-library Shared/RelayProtocol.swift Shared/RelayCipher.swift Shared/RelayPeer.swift Shared/RelayRPC.swift \
  Companion/CompanionConnection.swift Packages/TaplyneServer/Sources/TaplyneServer/EndpointPolicy.swift Tests/Remote/RelayTests.swift -o .build/relay-tests/relay-tests
node Relay/test/swift-integration.mjs "$PWD/.build/relay-tests/relay-tests"

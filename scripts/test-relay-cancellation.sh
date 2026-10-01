#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/relay-cancellation-tests
swiftc -parse-as-library Shared/RelayProtocol.swift Shared/RelayCipher.swift Shared/RelayPeer.swift Shared/RelayRPC.swift \
  Tests/Remote/RelayCancellationTests.swift -o .build/relay-cancellation-tests/relay-cancellation-tests
.build/relay-cancellation-tests/relay-cancellation-tests

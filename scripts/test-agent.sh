#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path Packages/TaplyneServer --quiet
BINARY_PATH="$(swift build --package-path Packages/TaplyneServer --show-bin-path)"
MODULE_PATH="$BINARY_PATH/Modules"
LINK=()
if [[ -f "$BINARY_PATH/libTaplyneServer.a" ]]; then
  MODULE_PATH="$BINARY_PATH"
  LINK+=("$BINARY_PATH/libTaplyneServer.a")
else
  while IFS= read -r object; do LINK+=("$object"); done < <(find "$BINARY_PATH/TaplyneServer.build" -name '*.swift.o' -type f)
fi
mkdir -p .build/agent-tests
swiftc -parse-as-library -I "$MODULE_PATH" Taplyne/Agent/AgentChat.swift \
  Tests/Agent/AgentChatTests.swift "${LINK[@]}" -o .build/agent-tests/agent-chat
.build/agent-tests/agent-chat

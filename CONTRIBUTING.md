# Contributing

Build with `scripts/build.sh`. Run the server tests, `scripts/test-bluetooth.sh` and `scripts/test-input.sh` for changes to input or automation. Run `npm run check --prefix site` for website changes.

Describe the observed problem, the expected behavior and the smallest reproduction. Remove keys, device identifiers and personal screen content. State the macOS and iOS versions when reporting compatibility.

Keep input cancellation, frame freshness and explicit verification intact. A success result must identify what was checked. Never add automatic replay of an uncertain send or submission. Public source and release files must contain no local credentials or device data.

Contributions are licensed under AGPL-3.0-only.

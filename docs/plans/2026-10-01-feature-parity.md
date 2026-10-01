# Conversation and remote control expansion

Implemented and tested on October 1 and 2, 2026. The Mac app and native iPhone/iPad companion build successfully. Simulator integration works. The physical iPad passed encrypted screenshot and Home control after USB removal and after switching to an iPhone cellular hotspot while the Mac stayed on its existing Wi-Fi. On that cellular connection, the companion sent a screen-reading request to the Mac and displayed the completed OpenAI reply. Exact Hebrew and emoji field readback passed, and Isaac confirmed a spoken reply and voice interruption. Live ChatGPT consent remains a separate check.

## Implemented behavior

Taplyne retains its USB/Bluetooth path and adds encrypted device-specific conversations, live steering, saved workflows with reusable inputs and run history, native dictation and spoken replies, and an OpenAI Realtime voice option. Agent choices include the existing Claude Code login, an OpenAI API key and a direct ChatGPT sign-in flow. Direct agents receive only device-scoped phone tools.

The companion supports text and voice, device selection, QR/deep-link pairing, Keychain credentials, polling, interruption and reconnect without command replay. Its separate per-device credential cannot access another device or the general control API. Voice-controlled runs have a renewable lease and pause after connection loss.

The WebDriverAgent transport supplies remote capture, coordinate-aware input and verified Unicode entry. Integrated setup fetches a pinned runner, builds and signs it with Xcode, checks profile expiry, installs and pairs it privately, then launches it in the background through RemoteXPC. The launcher closes its Mac channel after startup. A self-hosted WSS relay carries independent encrypted runner and companion channels without public Mac ports. Relay deployment is a separate release action.

## Acceptance matrix

| Area | Result | Evidence and limitation |
| --- | --- | --- |
| macOS app | PASS, local | Final Debug build and signing verification. Latest preview launched and showed remote device Online. |
| Native companion | PASS, simulator and physical installation | Signed simulator build installed and launched. Signed physical builds installed on the iPhone and iPad. The iPad setup screen was inspected through accessibility and a fresh screenshot. |
| Companion request to Mac | PASS, simulator and physical cellular connection | Simulator companion submitted a screen-reading request and displayed Claude's reply. The physical iPad companion reconnected over the cellular hotspot, sent a request, and displayed the Mac agent's tool call and completed OpenAI reply. |
| Pairing and reconnect | PASS, simulator and physical relay | Valid deep link populated setup; invalid short key was rejected; reconnect used persisted Keychain credentials and reached Ready. The physical iPad companion paired through the public encrypted relay and reached Ready. Stopping the Mac preview returned the simulator companion to setup with the connection-loss notice. Camera scanning itself remains unverified on hardware. |
| Workflows | PASS, local | Input substitution, isolation and run-history tests passed. UI creation and loading the resolved prompt into the draft passed. |
| Persistence and steering | PASS, local | Encrypted history, owner-only files, interrupted-run recovery, Unicode, deduplication, pause/resume and cancellation tests passed. |
| Device authorization | PASS, local | Server suite passed 43 tests, including companion authorization, device-scoped MCP capabilities, command validation and voice lease behavior. |
| Emergency controls | PASS, local | Production service tests cover storage-independent stop, delayed revoked send and stale voice-pause rejection. |
| Remote input | PASS, simulator and physical iPad | Real XCTest screenshot, tap and exact Hebrew/emoji field readback passed, including the physical companion's focused draft field over the public relay. Tests cover scaling, bounds, exact Unicode/multiline entry, transport failure and session recovery, plus endpoint policy. |
| Existing Bluetooth/input contracts | PASS, local | HID framing, negotiation, malformed requests, per-phone isolation, disconnect, pointer ownership and cancellation checks passed. |
| ChatGPT sign-in | PASS, contract; UNVERIFIED, live | Signed OIDC identity, nonce, audience, expiry, signature and incomplete-stream tests passed. User consent and plan inference have not been exercised. |
| Bring your own OpenAI key | PASS, provider, local contracts and physical remote inspection | Key validation, removal, shared reasoning/voice configuration, optional voice override and account isolation tests passed. A bounded provider fixture completed with HTTP 200 and 19 total tokens. Hardware QA found that Foundation's line iterator discarded SSE separators; the production parser now consumes raw bytes. After rebuilding, the Mac agent inspected the cellular-connected iPad and completed its reply. |
| OpenAI Realtime voice | PASS, provider protocol and physical foreground/background conversation | After fixing an audio-engine restart loop, the normally launched physical companion captured speech with USB disconnected and the iPad on the cellular hotspot. Isaac confirmed that a spoken Home command went Home and that a subsequent question received an audible reply while the companion was in the background. Earlier audible reply and interruption checks also passed. Live replies now default to English on explicit user preference; the updated provider fixture returned an English transcript and audio. External audio route changes and echo behavior remain unmeasured. |
| Physical iPhone | PASS, production launcher and relay control | On iOS 27, the production `run-runner.sh --background` path built, signed, installed and paired its own runner, then launched it and exited. A separate encrypted relay room returned status 200, a fresh JPEG screenshot and Home 200. The final signed companion installed and launched; its setup screen was confirmed by screenshot and accessibility. The task's iPhone runner process was stopped and its temporary Mac pairing files removed afterward. |
| Physical iPad runner | PASS, public TLS relay and secure bootstrap | Signed production runner returned status 200, a bounded JPEG screenshot and Home 200 over encrypted WSS. The bootstrap file was removed from Documents. Restarting XCTest without another bootstrap repeated all three requests, proving Keychain persistence. |
| Cellular away from Mac | PASS, physical iPad through cellular hotspot | Native RemoteXPC launched the runner and exited. Fresh encrypted status, screenshot and Home requests passed repeatedly after USB removal. Isaac then connected the iPad to his iPhone's cellular hotspot while keeping the Mac on its existing Wi-Fi; fresh Settings capture, Home control and the resulting SpringBoard capture passed through the public relay. This proves an active runner across those networks. Relaunch after an OS kill or reboot is not established. |
| Remote setup and relay | PASS, local contracts, builds and physical relay | Mac setup controls inspected, signed-runner pipeline implemented, native encrypted peers and production companion exercised through a real local relay. A temporary public TLS test relay was explicitly authorized and exercised by the signed physical iPad runner. Permanent deployment has not been performed. |

## Reproduce local checks

```sh
bash scripts/build.sh Debug
bash scripts/build-companion.sh simulator
swift test --package-path Packages/TaplyneServer
bash scripts/test-agent.sh
bash scripts/test-input.sh
bash scripts/test-bluetooth.sh
bash scripts/test-relay.sh
bash scripts/test-relay-cancellation.sh
bash scripts/test-voice.sh
(cd Relay && npm ci && npm run check && npm test)
```

The optional integration input test uses `TAPLYNE_WDA_TEST_ENDPOINT` with a task-owned runner and an editable test field. It enters test text; do not point it at a personal application.

Local build artifacts are `build/Taplyne.app`, `.build/Companion/Build/Products/Debug-iphonesimulator/TaplyneCompanion.app` and `.build/CompanionDevice/Build/Products/Debug-iphoneos/TaplyneCompanion.app`. Detailed session evidence is under `~/Assets/taplyne/files/`: `final-verification.log`, `lease-verified.log`, `service-tests.log`, `remote-checks.log` and `bluetooth-tests.log`. The final builds passed in `final-english-mac-build.log`, `final-english-simulator-build.log` and `english-final-companion-build.log`. The final physical companion was installed on both devices. Physical cellular navigation and companion evidence is in `final-cellular-open-companion.json` and `final-cellular-companion-reply.json`. Older failed attempts in that directory are superseded by the final build and focused passing checks.

## Continuation verification

The encrypted relay passes native handshake, role/scope binding, tamper and replay rejection, exact sequence and deadline enforcement, reconnect epoch, authenticated role replacement, exact conversation-route isolation and QR round-trip checks. A replaced endpoint stops reconnecting automatically. Other disconnects use a capped backoff that resets after a healthy session. Production `CompanionConnection` connects through the real local Node relay, saves its pairing and completes a command. Native dictation also uses the renewable voice lease, waits for an in-flight send before a correction, releases the lease and speaks its final result exactly once. A runner screenshot exceeded the original transport cap during simulator testing; screenshot forwarding now converts to bounded JPEG with a 2048-pixel longest edge and preserves aspect ratio for native coordinate mapping. The conversion test passes.

The Mac settings screen displays the signing team, relay endpoint, enrollment token, install/renew flow, certificate expiry and revocation controls. Existing private endpoints are still supported. Both latest native application builds pass. The current build embeds runner setup tools so the installed app can prepare its own source and build cache under Application Support. Setup validates the selected device, signing team and bundled tools before changing pairing. Companion key rotation replaces the entire conversation relay channel and fences already accepted old commands, while retaining runner pairing.

Conversation commands carry a client ID, increasing sequence, current phone control generation and issue time. The server rejects old or delayed commands; a Stop increments the phone generation so an earlier Send cannot restart work afterward. Snapshot pause state reflects the real input queue. The service and its voice watchdogs survive local HTTP server restarts. The 43 server tests and the production service regression harness pass after these changes.

An isolated simulator XCTest artifact completed encrypted runner-owned status, bounded screenshot and Home requests. That QA artifact bypassed a simulator test-host Keychain entitlement failure in memory only. Production runner source keeps strict Keychain storage, so this simulator result does not establish production bootstrap. Physical provisioning, Keychain bootstrap and TLS relay results are being recorded separately.

Physical signing succeeded for the companion and runner. Production runner bootstrap and Keychain persistence passed on the iPad through the temporary TLS relay. Provider fixtures passed for streamed text and bidirectional Realtime audio. The physical companion paired, passed exact Unicode field readback and started live voice. Isaac confirmed an audible reply and successful spoken interruption. The companion Stop control ended voice and paused the Mac; its own pending automation receipt was canceled, and a fresh observation confirmed the resulting state.

Mac conversations now include a server session identifier. Restarting the Mac rejects delayed commands from its previous session, and the companion accepts the new session's initial generation without replaying work. Relay requests are encrypted only when their ordered send slot runs; cancellation cannot consume a sequence number or close a newer connection. Playback completion callbacks carry an epoch and item identifier so a callback released by interruption cannot change accounting for new audio. Focused regression tests cover these cases.

Physical cellular QA found two navigation issues. Slow captures could exhaust the settling deadline before it collected three matching frames, and the icon detector excluded the smaller icons on the iPad Home Screen. The fixes retain freshness, layout, ambiguity and control-ownership checks. All 28 focused tests passed, including moving and stale captures; the rebuilt Mac successfully opened the physical companion over the cellular hotspot. The companion now uses Taplyne's existing icon and declares all iPad orientations.

Hardware voice QA found that initial voice-processing configuration stopped the iPad audio engine before its first buffer. Recreating the engine repeated that negotiation. Recovery now reuses the configured engine, refreshes the tap and converter, and has a bounded watchdog. Route notifications are checked against the actual route and capture state; stale engine callbacks are rejected. The companion displays microphone state, input level and the selected input. A bounded development trace showed one recovery followed by a nonzero buffer and a running engine. A normal launch without the diagnostic console then reached Microphone connected again. Isaac subsequently confirmed unplugged voice-driven Home navigation and an audible background reply on the hotspot. Evidence is in `microphone-engine-reuse-console.log`, `microphone-engine-reuse-success.json`, `microphone-detached-companion-ready.json` and `final-unplugged-voice-state.json` under the session's Assets directory.

## Remaining acceptance

The initial tethered XCTest unplug test failed. The replacement RemoteXPC background launch passed unplugged and cellular-hotspot control on iPadOS 26.2. Remote relaunch after iOS terminates the runner or the device reboots remains unverified and requires local reconnection. A permanent public relay needs an authorized host, domain and deployment. Live ChatGPT access needs the user's sign-in consent. Echo behavior and external audio route changes still need device acceptance; background voice passed on the iPad.

These features are included in the 0.3.0 release. The release adds a universal Developer ID signed Mac build and a getting-started guide. The companion and relay are distributed as source. The temporary test relay and physical test runners were stopped after acceptance; users deploy their own relay for remote mode.

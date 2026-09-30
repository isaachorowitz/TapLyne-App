# Phone control improvements

Requested 30 September 2026: pointer accuracy and stale-screen prevention; screen descriptions, tap by label and scroll to an item; verified outcomes; dependable English, Hebrew, emoji and forms; navigation; manual takeover, pause and resume; investigate Argent integration.

## Design

Keep the current USB capture and Bluetooth HID transport. Put local screen recognition, frame references, expected-result verification and higher-level navigation in the shared server package so REST, MCP and the embedded agent use the same contract. OCR describes visible text; it does not claim to be the native iOS accessibility tree.

Coordinate actions must reference an observed frame. Validate its phone, geometry, age, control generation and content again while holding the phone's action queue. Invalidate references after input. Closed-loop pointer aiming must see the actual pointer and stop before clicking when aiming is uncertain.

Every action returns fresh evidence and a verification status. Only a checked expectation or exact text readback can be reported as verified. An unchanged screen, unavailable text verification, ambiguous label or uncertain outcome must not cause automatic replay of an external write.

Serialize clipboard operations across phones. Preserve all clipboard representations, detect concurrent user writes, use a unique sentinel for phone-to-Mac text readback, and never submit a form implicitly.

A cancellation-aware phone queue owns input. Pause and manual takeover invalidate agent work, cancel active input and release held reports. Resume requires fresh observation and resumes the conversation without reusing old coordinates.

Argent investigation is bounded to its supported physical-device transport and available integration surface. Do not modify the installed Argent package or pretend an adapter is native Argent support. Expose transport-independent tools that an Argent integration could call.

## Verification

Run focused package tests for stale references, geometry changes, ambiguity, verification predicates, bounded scrolling, queue cancellation and takeover. Exercise real local OCR with English and Hebrew fixtures and validate Unicode separately from OCR. Run Bluetooth/pointer regression checks and build the Mac app. Inspect the new UI in an isolated preview. Run safe phone acceptance checks after the rebuilt app can be loaded without interfering with the other checkout.

The subsequent publication request authorizes the scoped commit, push, public repository, Mac release and landing page deployment. Device Developer Mode changes remain outside scope.

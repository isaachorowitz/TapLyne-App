# Taplyne

Give your AI a real iPhone or iPad. Taplyne is a free, open-source Mac app for screen control, agent conversations and live voice, with USB and optional remote modes.

[Download for Mac](https://github.com/isaachorowitz/TapLyne-App/releases/latest/download/Taplyne.dmg) · [Source](https://github.com/isaachorowitz/TapLyne-App) · [Getting started](docs/GETTING-STARTED.md) · [Release notes](https://github.com/isaachorowitz/TapLyne-App/releases)

In USB mode, USB carries the screen and Bluetooth carries mouse and keyboard input. AssistiveTouch turns that input into taps, with nothing installed on the iPhone. Optional remote mode installs a signed XCTest runner and connects through your encrypted relay. Neither mode requires a Taplyne account.

This is an early release. It uses private macOS Bluetooth APIs, and compatibility varies across device and OS versions. The capture and input architecture has no Developer Mode requirement; operation with Developer Mode disabled still needs physical-device validation.

## Start with USB

You need a Mac with macOS 15 or later, an unlocked iPhone or iPad, and a USB data cable. The Mac download supports Apple silicon and Intel. USB mode needs no iPhone app or Apple developer signing. Remote mode has additional setup, described in [the getting-started guide](docs/GETTING-STARTED.md#remote-control-and-phone-voice).


1. Download the DMG, open it, and drag Taplyne to Applications.
2. With [Homebrew](https://brew.sh) installed, run `brew install uv && uv tool install pymobiledevice3` in Terminal.
3. Plug in an unlocked iPhone with a USB data cable. Tap **Trust** on the phone if asked.
4. Open Taplyne and follow its setup card: allow Camera access, prepare Bluetooth pairing, select the Mac in the phone's Bluetooth settings, enable AssistiveTouch, and calibrate the pointer.
5. Open **Settings > Agent** and choose your provider. For OpenAI, choose **OpenAI API key (BYOK)**, save your own key and click **Validate saved key**. Or use an existing Claude Code login.
6. Select the phone and ask **“Describe the screen without tapping anything.”** Check that the reply matches the phone, then try **“Go Home.”**

Camera permission enables the USB screen capture device; Taplyne does not use the Mac's camera. Leave the phone unlocked while it works. Use **Pause** or **Take over** whenever you want to intervene.

Claude Code users should install [Claude Code](https://code.claude.com/docs/en/overview) and complete its login before selecting it in Settings. Other agents can connect through MCP or REST. Taplyne is free; AI provider accounts and usage charges are separate. Live AI voice requires an OpenAI API key even when another provider handles reasoning.

Plain English uses Bluetooth keyboard input and requires an English hardware keyboard layout on the iPhone. Supply a visible-text result condition to verify it. Hebrew, emoji and multiline text use Universal Clipboard, which requires Handoff and the same Apple Account on the Mac and iPhone. Newlines and tabs are never converted to keypresses that could submit a form. Clipboard availability and field readback must be checked on your devices. In the current physical-phone checks, English input passed; Hebrew and emoji paste failed even with Handoff enabled. Treat Unicode paste as experimental and inspect the field before continuing.

For Hebrew screen recognition, install the optional local OCR models from a source checkout:

```sh
scripts/install-ocr.sh
```

The script installs Tesseract if needed and downloads checksum-pinned English and Hebrew models into `~/Library/Application Support/Taplyne/OCR`. Models and screen captures stay outside the source tree. English recognition uses Apple Vision.

## Use

The sidebar lists phones, the center shows the live screen, and the chat panel runs your agent. The gesture toolbar provides tap, double tap, triple tap, hold, flick, drag, hold and drag, and live pointer control.

**Phone tools** adds local screen descriptions, a visible-label tap, field replacement, and navigation to Home, back, the app switcher, notifications and Control Center. OCR describes visible text and bounds; it does not expose iOS's native accessibility tree. Icon-only controls still need a current screenshot.

**Pause** stops automatic input. **Take over** cancels active and queued agent actions so you can work manually. **Resume** invalidates old frames and lets the built-in agent continue its conversation with a fresh screen description. It checks what already happened before continuing.

Every automated action returns a fresh screen and a result:

| Status | Meaning |
|---|---|
| `verified` | The supplied visible condition passed, or text readback matched. |
| `unverified` | Input may have arrived, but its intended result was not established. Inspect it before continuing. |
| `failed` | The condition failed or the action was rejected. Check `input_delivered` before deciding what to do next. |

A changed screen alone does not prove a task succeeded. A condition already true before input also remains unverified. Supply a result condition for actions such as opening a screen. Never automatically repeat an uncertain send, purchase or submission. Form filling stops at the first uncertain field and does not submit. A targeted field needs visible focus evidence in its own row before pasting. If focus is unclear, select the field manually and use `fill_field` with `text` and a fresh `frame_id`. It never dismisses a keyboard or form implicitly.

Pointer aiming measures the visible pointer and corrects its position before a click. It waits for an icon's hover animation to settle and uses the calibrated error tolerance, capped at 30 native pixels. App captions in a recognized icon grid resolve to the associated icon. If the screen moves, the pointer cannot be located, or the target is stale, the action stops. Home remains available on animated screens. The driver releases held mouse and keyboard reports on cancellation.

## Connect an agent

Settings > Connect AI shows commands with your local API key. The server defaults to `127.0.0.1:7788`.

```sh
claude mcp add --scope user --transport http taplyne \
  http://127.0.0.1:7788/mcp --header "X-API-Key: <your-local-key>"
```

The [agent skill](skills/taplyne/SKILL.md) describes the observation and action loop. Keep the local API key private. Enabling network access exposes phone control to that network; use a trusted network and protected transport.

### MCP

| Task | Tools |
|---|---|
| Observe | `list_phones`, `get_phone_status`, `screenshot`, `describe_screen`, `list_apps` |
| Find | `tap_label`, `scroll_to_item`, `wait_for_text` |
| Point | `tap`, `double_tap`, `triple_tap`, `long_press`, `flick`, `drag`, `hold_and_drag` |
| Text | `type_text`, `fill_field`, `fill_form`, `press_key` |
| Navigate | `press_home`, `navigate`, `open_app` |
| Control | `control_phone` |

Start with `list_phones`, then `describe_screen`. Coordinate actions, typing, key presses, field replacement and `tap_label` require the current `frame_id`. Coordinates are pixels in the returned image, whose longest edge is at most 1344 pixels. A frame belongs to one phone and one control revision and is consumed by input. Only the person at the Mac can resume automation after pause or takeover. Remote `control_phone` accepts pause and stop. Failed actions include `delivery` (`not_delivered`, `delivered`, or `unknown`) and `completed_steps`; `input_delivered` is a boolean or the string `unknown`. Old clients must adopt this contract; version 0.2 is not a drop-in replacement for earlier coordinate calls.

A label must match one visible OCR element. Duplicate labels require an `element_id`. `scroll_to_item` has a fixed limit and stops when the screen no longer moves; it does not tap the result.

To verify a tap, include an expectation:

```json
{
  "phone_id": "<phone-id>",
  "frame_id": "<current-frame-id>",
  "label": "Settings",
  "expect": { "text_present": "General" }
}
```

Expectations support `text_present`, `text_absent` and `screen_changed`. Text checks inspect visible OCR, so hidden content, secure fields and unsupported layouts can remain unverified. `fill_field` replaces a value and checks exact clipboard readback; `type_text` checks that the exact fragment appears, without claiming its insertion position.

### REST

Base URL: `http://127.0.0.1:7788/v1`. Authenticate with `X-API-Key`.

| Route | Purpose |
|---|---|
| `GET /phones` | IDs and readiness |
| `GET /phones/{id}/status` | Readiness and control state |
| `GET /phones/{id}/describe` | Native-pixel OCR bounds and frame reference |
| `GET /phones/{id}/screenshot` | Native PNG with `X-Taplyne-Frame-Id` |
| `GET /phones/{id}/apps` | Installed applications |
| `POST /phones/{id}/control` | `pause`, `stop`; resume and takeover use the Mac UI |
| `POST /phones/{id}/tap-label` | Unique label or element tap |
| `POST /phones/{id}/scroll-to-item` | Bounded scrolling |
| `POST /phones/{id}/wait-for-text` | Observe a text condition without input |
| `POST /phones/{id}/fill-field` | Replace one field |
| `POST /phones/{id}/fill-form` | Fill fields sequentially |
| `POST /phones/{id}/navigate` | Navigation command |
| `POST /phones/{id}/open-app` | Open by visible application name |
| `POST /phones/{id}/{tap,double-tap,triple-tap,tap-and-hold,flick,drag,hold-and-drag,type,keypress,home}` | Direct input |
| `GET /jobs/{id}` | Job state and result |
| `GET /jobs/{id}/download` | Result JSON or screenshot |

REST coordinates use native screen pixels. Coordinate, typing and keypress requests include `frame_id`. Add `?async=true` to action routes for a job ID. A completed job means the operation finished; inspect the separate verification result to establish success.

The local live-view dashboard is `http://127.0.0.1:7788/?key=<your-local-key>`. Treat that URL as a credential.

### Argent

Taplyne exposes a separate transport through MCP and REST. An agent can use Taplyne alongside Argent, choosing Taplyne for this USB and Bluetooth path and Argent for its supported app-testing devices. The current Argent distribution cannot select Taplyne as a native device backend. That requires an Argent transport extension. [Integration details](docs/argent-integration.md).

## Privacy and security

Screen capture, pointer feedback and OCR run locally. Taplyne has no built-in analytics. Optional remote mode forwards encrypted screen and control traffic through your relay. An agent can transmit screen content to its AI provider. Conversations and workflow history are encrypted on the Mac; phone settings and calibration live in Application Support. Server, provider and pairing credentials live in Keychain.

Clipboard transactions preserve rich content and reject concurrent clipboard changes before pasting. Original clipboard content is restored only while Taplyne still owns the clipboard; a subsequent phone or user copy is preserved. Universal Clipboard is a shared OS facility: text readback cannot establish which device produced a concurrent clipboard update. Inspect uncertain outcomes, especially on secure fields.

Use the phone's own unlock, password and authentication interfaces. Avoid exposing screenshots or server keys in bug reports. See [SECURITY.md](SECURITY.md) for reporting instructions.

## Build from source

Install Xcode and XcodeGen (`brew install xcodegen`). No developer account or personal signing certificate is needed for a local ad hoc Mac build. Installing the iOS companion or remote runner requires Apple signing.

```sh
git clone https://github.com/isaachorowitz/TapLyne-App.git
cd TapLyne-App
scripts/build.sh
open build/Taplyne.app
```

Use `scripts/build.sh Release ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` for a universal release build. `Taplyne.xcodeproj` is generated from `project.yml`. Local ad hoc builds do not carry distribution notarization.

```sh
swift test --package-path Packages/TaplyneServer
bash scripts/test-bluetooth.sh
bash scripts/test-input.sh
bash scripts/test-agent.sh
```

The server tests cover stale and cross-phone frames, queue cancellation, ambiguity, result verification, bounded scrolling, form uncertainty, REST, MCP and real OCR fixtures. Input tests cover clipboard preservation and cancellation releasing held reports. These checks do not establish physical-device compatibility.

Debug preview: `TAPLYNE_PREVIEW=ready build/Taplyne.app/Contents/MacOS/Taplyne`. Available states are `setup`, `ready`, `empty`, `calibrating` and `agent`. These visual preview states start no capture, server or Bluetooth and do not read or write the server key. Dedicated remote QA preview hooks are separate and can start connections when explicitly configured.

The one-page website lives in `site/`. Run `npm ci --prefix site`, `npm run check --prefix site`, and `npm run dev --prefix site`. It serves static files through Cloudflare Workers. Fonts are self-hosted with their licenses.

## Troubleshooting

- **Phone not found:** unlock it, accept Trust, and check the data cable. `pymobiledevice3 usbmux list` should list the phone.
- **Black screen:** unlock the phone. If capture stays unavailable, use Restart iPhone in the setup card.
- **Bluetooth unavailable:** prepare pairing again, then select this Mac from the iPhone's Bluetooth settings. This setup action also enables AssistiveTouch. Both HID channels must connect.
- **Uncertain pointer:** calibrate again on the Home Screen. Avoid touching the phone while aiming.
- **Text unverified:** check Handoff, the Apple Account and whether the field supports selection and copy. Inspect the value before pasting again.
- **Hebrew labels missing:** install the optional OCR models and describe the current screen again.
- **AssistiveTouch menu in the way:** disable Always Show Menu in iPhone Settings > Accessibility > Touch > AssistiveTouch. Keep AssistiveTouch itself enabled.

## License and credits

Taplyne is licensed under **AGPL-3.0-only**. The Bluetooth HID stack includes work from [jqssun/darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote), under the same license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE). This project is independent of TapKit and Apple.

## Conversations, voice and companion

Taplyne includes encrypted conversations per device, live steering, saved workflows with `{{inputs}}`, and a recent-run log. Workflow results report the agent's evidence; finishing a run is not proof every requested action succeeded. An interrupted run is never replayed automatically.

Settings > Agent lets you choose your own OpenAI API key, Claude Code login or Sign in with ChatGPT. New installations initially select Claude Code; choose OpenAI explicitly to use an API key. Live ChatGPT sign-in still needs acceptance testing; use OpenAI or an existing Claude Code login for the verified setup path. Taplyne stores API keys in the Mac Keychain, can validate or remove them from Settings, and never bundles a provider key. Your requests and screen evidence go to the provider you select.

Sign in with ChatGPT uses OpenAI's public-client dynamic registration, PKCE, a stable installation host ID, and a separate Keychain credential record for each account or workspace. Taplyne validates the returned identity, keeps account registrations isolated, serializes rotating-token refreshes, and pins each agent run to the account it started with. It lists the models eligible for the active account and treats only a terminal `response.completed` event as success. It does not read credentials from ChatGPT or another application.

Native dictation and speech work with any reasoning provider. Live AI voice streams microphone audio to OpenAI Realtime and uses the primary OpenAI API key by default, even when ChatGPT or Claude Code handles reasoning. Settings can store a separate voice-only key when voice should bill another OpenAI project. Live replies use English by default and change language when you explicitly request it; spoken input remains multilingual. Voice interruption cancels the current response and pauses device work. Companion voice work uses a renewable lease so a lost connection pauses work on the Mac. Already delivered actions cannot be undone. Spoken replies, interruption and a voice-driven Home command followed by a background reply passed on a physical iPad, including unplugged use through a cellular hotspot. External audio route changes and echo behavior still need separate hardware acceptance.

Build the iPhone/iPad companion with XcodeGen and Xcode:

```sh
bash scripts/build-companion.sh simulator <simulator-udid>
TAPLYNE_DEVELOPMENT_TEAM=<your-team-id> bash scripts/build-companion.sh device <device-udid>
```

The companion is built and installed with Xcode; there is no App Store or TestFlight download in this release. See the [step-by-step setup](docs/GETTING-STARTED.md#install-the-companion). The simulator build includes the entitlements required for Keychain. A physical build needs an Apple development signing profile for `agency.ziplyne.taplyne.companion`. The project includes both iPhone and iPad layouts. Store distribution is not included in this local build.

In Mac Settings > Phone & iPad, select the controlled device, enter the Mac's reachable address, create a companion key, and scan its QR code in the companion. Check the address and tap Connect. Manual address/key entry remains available. The companion key controls that device only and differs from an ordinary MCP key. A new key revokes its predecessor. Histories stay on the Mac; the companion stores its pairing credential in Keychain.

## Remote device setup

Settings > Remote device installs and pairs the signed XCTest runner for the selected USB device. Enter your Apple Developer team ID, a deployed relay's `wss://` address, and its enrollment token. The app bundles the setup tools, fetches the pinned WebDriverAgent source, builds and signs it with Xcode, checks signature and profile expiry, installs it, stages its pairing privately, and launches it in the background through Apple's RemoteXPC services. Xcode must have signing access, `uv` must be installed, and the device needs Developer Mode and an unlocked screen. The launcher closes its Mac connection after startup. Reinstall and renew before the displayed profile expiry. The private runner endpoint option remains available for an existing trusted-network setup.

The Mac, runner and companion connect outward to the included [Relay service](Relay/README.md). Each device has separate runner and conversation channels with independent random credentials, authenticated encrypted handshakes, AES-GCM encryption and replay rejection. The runner's HTTP and screen-stream listeners bind to loopback. No public Mac port or device VPN is needed for the relay traffic. The relay requires an authorized deployment with a domain and TLS; no hosted relay is provisioned by this repository.

After runner setup, open Settings > Phone & iPad, load its relay pairing code and scan it in the native companion. Text and voice can use the conversation relay while the runner independently handles device control. Pairing revocation stops both Mac endpoints and invalidates the companion key. Connection loss fails pending requests and pauses automation; reconnection does not replay actions. The Mac must remain running.

The background runner passed fresh capture and Home control on a physical iPad after USB removal and after switching to an iPhone's cellular hotspot while the Mac stayed on its existing Wi-Fi. The companion also sent a screen-reading request and displayed the completed OpenAI reply over that cellular connection. Keep the device unlocked and the Mac online. If iOS terminates the runner or the device restarts, reconnect locally to launch it again; remote recovery from that state is not established. The explicit tethered `xcodebuild` fallback requires its Mac connection to remain attached. Detailed acceptance results and device versions are in [the verification matrix](docs/plans/2026-10-01-feature-parity.md).

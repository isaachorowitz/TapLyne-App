# Taplyne

Give your AI a real iPhone. Taplyne is a free, open-source Mac app that lets an agent see, tap, scroll and type on an iPhone connected to your Mac.

[Download for Mac](https://github.com/isaachorowitz/taplyne-mac/releases/latest/download/Taplyne.dmg) · [Source](https://github.com/isaachorowitz/taplyne-mac) · [Release notes](https://github.com/isaachorowitz/taplyne-mac/releases)

USB carries the screen. Bluetooth carries mouse and keyboard input. AssistiveTouch turns that input into taps. Nothing is installed on the iPhone, and there is no cloud relay or Taplyne account.

This is an early release. It uses private macOS Bluetooth APIs, and compatibility varies across device and OS versions. The capture and input architecture has no Developer Mode requirement; operation with Developer Mode disabled still needs physical-device validation.

## Install

1. Download the DMG, open it, and drag Taplyne to Applications.
2. Install the USB device helper: `brew install uv && uv tool install pymobiledevice3`.
3. Plug in an unlocked iPhone with a USB data cable. Tap **Trust** on the phone if asked.
4. Open Taplyne and follow the setup card: allow Camera access, pair the Mac from the iPhone's Bluetooth settings, enable AssistiveTouch, and calibrate the pointer.

The Mac needs macOS 15 or later. The release supports Apple silicon and Intel. Camera permission enables the USB screen capture device; Taplyne does not use the Mac's camera. Leave the iPhone unlocked while it works.

For the built-in chat, install [Claude Code](https://code.claude.com/docs/en/overview) and complete its login. Other agents can connect through MCP or REST. AI provider accounts and charges are separate from Taplyne.

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

Screen capture, pointer feedback and OCR run locally. Taplyne has no built-in analytics or cloud screen relay. An agent can transmit screen content to its AI provider. The built-in chat uses Claude Code and keeps conversation data in Claude Code's local storage. Phone settings and calibration live in Application Support; the server key lives in the macOS Keychain.

Clipboard transactions preserve rich content and reject concurrent clipboard changes before pasting. Original clipboard content is restored only while Taplyne still owns the clipboard; a subsequent phone or user copy is preserved. Universal Clipboard is a shared OS facility: text readback cannot establish which device produced a concurrent clipboard update. Inspect uncertain outcomes, especially on secure fields.

Use the phone's own unlock, password and authentication interfaces. Avoid exposing screenshots or server keys in bug reports. See [SECURITY.md](SECURITY.md) for reporting instructions.

## Build from source

Install Xcode and XcodeGen (`brew install xcodegen`). No developer account or personal signing certificate is needed for a local ad hoc build.

```sh
git clone https://github.com/isaachorowitz/taplyne-mac.git
cd taplyne-mac
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

Debug preview: `TAPLYNE_PREVIEW=ready build/Taplyne.app/Contents/MacOS/Taplyne`. Available states are `setup`, `ready`, `empty`, `calibrating` and `agent`. Preview starts no capture, server or Bluetooth and does not read or write the server key. It shares preferences with installed copies, so leave Server settings alone.

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

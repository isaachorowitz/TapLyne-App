# TapLyne setup guide

TapLyne is a free, open-source Mac app that lets an AI agent see, tap, scroll and type on a real iPhone or iPad. This guide is written so a person or an AI agent can follow it step by step. Each step says what to do, then how to check it worked.

Human-readable version: /docs/

Source code: https://github.com/isaachorowitz/TapLyne-App

## Rules for agents following this guide

- Run the terminal commands yourself. Hand the person only the steps that need their hands: tapping Trust on the phone, Bluetooth pairing, AssistiveTouch, granting macOS permissions, signing in to accounts, and anything involving a password, passcode or Face ID.
- Never print, log or paste an API key, enrollment token or pairing code into a chat, issue or file that others can read.
- Deploying a relay to a server is optional and changes infrastructure. Ask the person before doing it.
- After setup, call `list_phones`, then `describe_screen`, before any other action.

## What you need

- A Mac on macOS 15 or later (Apple silicon or Intel).
- An iPhone or iPad and a USB data cable (not a charge-only cable).
- An AI to do the thinking: an OpenAI API key, a ChatGPT account, or Claude Code installed and logged in.
- Homebrew (https://brew.sh) for the USB helper.

Remote mode and the companion app also need Xcode, an Apple Developer account, Developer Mode on the device, and a relay server you control. Skip them if the phone stays plugged into the Mac.

## Part 1: Basic setup (USB + Bluetooth)

### 1. Install the app

Download https://github.com/isaachorowitz/TapLyne-App/releases/download/v0.3.0/Taplyne.dmg, open it, and drag Taplyne to Applications.

Check: `ls /Applications/Taplyne.app` succeeds.

### 2. Install the USB helper

```sh
brew install uv && uv tool install pymobiledevice3
```

Check: `command -v pymobiledevice3` prints a path.

### 3. Plug in the phone

Connect the iPhone with the USB cable and unlock it. If the phone asks "Trust This Computer?", the person taps Trust and enters the passcode.

Check: `pymobiledevice3 usbmux list` lists the phone.

### 4. Finish the setup card

Open Taplyne and select the phone in the sidebar. The setup card walks through four steps. The person does these:

1. Allow Camera access. macOS uses this permission for the phone's screen feed. The Mac's own camera is never turned on.
2. Click Prepare Bluetooth Pairing, then on the iPhone open Settings > Bluetooth, pick this Mac and approve the matching pairing code.
3. Turn on AssistiveTouch (Settings > Accessibility > Touch > AssistiveTouch).
4. With the Home Screen showing, click Calibrate Pointer. Do not touch the phone while it calibrates.

Check: the phone shows as ready in Taplyne's sidebar and its live screen appears in the middle.

### 5. Pick the AI for the built-in chat

Open Taplyne > Settings > Agent and choose a Reasoning provider:

- **OpenAI API key (BYOK):** paste the key, click Save key, then Validate saved key. It is stored in the Mac's Keychain.
- **ChatGPT plan:** click sign in and follow the ChatGPT sign-in steps.
- **Claude Code login:** install Claude Code (https://code.claude.com/docs/en/overview) and log in first. No key needed.

Check: in the chat panel, send "Describe the screen without tapping anything." Compare the reply with the phone, then send "Go Home."

## Part 2: Connect an outside AI agent (MCP or REST)

Taplyne runs a local server at `http://127.0.0.1:7788`. Open Settings > Connect AI to copy the commands with your API key already filled in.

### Claude Code

```sh
claude mcp add --scope user --transport http taplyne \
  http://127.0.0.1:7788/mcp --header "X-API-Key: <your-local-key>"
```

### Any other MCP client

- Transport: Streamable HTTP
- URL: `http://127.0.0.1:7788/mcp`
- Header: `X-API-Key: <your-local-key>`

### REST

```sh
curl -H "X-API-Key: <your-local-key>" http://127.0.0.1:7788/v1/phones
```

Check: the response lists the phone.

### Live dashboard

Open `http://127.0.0.1:7788/?key=<your-local-key>` in a browser. Treat that URL like a password.

### Agent skill

Give your agent the TapLyne skill so it knows the look, act, check loop: https://github.com/isaachorowitz/TapLyne-App/blob/main/skills/taplyne/SKILL.md

The server listens only on this Mac by default. Settings > Server > "Allow other devices on the network" opens it to your network; use that only on a network you trust.

## Part 3: Optional Hebrew screen reading

English text reading is built in. For Hebrew, from a source checkout:

```sh
git clone https://github.com/isaachorowitz/TapLyne-App.git
cd TapLyne-App
scripts/install-ocr.sh
```

## Part 4: Voice

On the Mac, click Live AI voice in the chat panel for a spoken conversation, or the microphone button for dictation. The companion app has the same options (Part 6). Live voice uses OpenAI Realtime and needs an OpenAI API key saved in Mac Settings > Agent, even when ChatGPT or Claude Code does the reasoning. To bill voice to a different OpenAI project, paste a key into "Optional voice-only OpenAI key" and click Save voice override.

Native dictation also works with whichever AI does the reasoning.

Replies default to English. Ask explicitly to switch languages.

## Part 5: Remote mode (control the phone away from the Mac)

Remote mode installs a small signed helper (an XCTest runner) on the phone. After that, the phone can be unplugged and controlled over Wi-Fi or cellular through an encrypted relay you host. The Mac must stay on and online.

### 5a. Deploy the relay (one time, needs a server)

Ask the person before running this. You need a Linux server with Docker and a domain name pointed at it.

```sh
git clone https://github.com/isaachorowitz/TapLyne-App.git
cd TapLyne-App/Relay
export TAPLYNE_DOMAIN=relay.example.com
export TAPLYNE_ENROLLMENT_TOKEN="$(openssl rand -hex 32)"
docker compose up --build -d
```

Caddy gets the TLS certificate automatically. Save the enrollment token somewhere private; the Mac needs it once.

Full relay details: https://github.com/isaachorowitz/TapLyne-App/blob/main/Relay/README.md

Check: `curl https://relay.example.com/health` returns `{"status":"ok"}`.

### 5b. Prepare the Mac and the phone

- Install Xcode and add the Apple Developer account in Xcode > Settings > Accounts.
- `brew install uv` (already done in Part 1).
- On the phone: Settings > Privacy & Security > Developer Mode > On, then restart when asked.
- Keep the phone plugged in and unlocked for this part.

### 5c. Install the runner

In Taplyne, select the phone in the sidebar, then open Settings > Remote device:

1. Apple team ID: your 10-character team ID (Xcode > Settings > Accounts, or developer.apple.com > Membership).
2. Relay address: `wss://relay.example.com`
3. Relay enrollment token: the token from step 5a.
4. Click Install and pair runner.

Taplyne downloads the pinned runner source, builds and signs it with Xcode, installs it, pairs it and starts it in the background. The signing profile's expiry date appears when it finishes. Click Reinstall and renew runner before that date.

### 5d. Check it before leaving the Mac

1. Check the Device connection and open a fresh screen in Taplyne. A successful install alone does not prove control. If it shows paused, look at the screen and click Resume. Then send "Go Home."
2. Unplug the USB cable and repeat.
3. Switch the phone to cellular or another Wi-Fi network and repeat.

If iOS stops the runner or the phone restarts, plug it back in and run setup again.

Revoke access at any time with Revoke relay and companion pairing.

## Part 6: Companion app (talk to your Mac's AI from the phone)

The companion app for iPhone and iPad sends text and voice requests to the AI on your Mac. It is not on the App Store or TestFlight yet, so it is installed with Xcode.

### 6a. Build and install

Add the Apple account in Xcode > Settings > Accounts, connect the unlocked device, then:

```sh
brew install xcodegen uv
git clone https://github.com/isaachorowitz/TapLyne-App.git
cd TapLyne-App
TAPLYNE_DEVELOPMENT_TEAM=<your-team-id> bash scripts/build-companion.sh device <device-udid>
xcrun devicectl device install app --device <device-udid> .build/CompanionDevice/Build/Products/Debug-iphoneos/TaplyneCompanion.app
xcrun devicectl device process launch --device <device-udid> agency.ziplyne.taplyne.companion
```

Find the device UDID with `xcrun devicectl list devices`. To use Xcode instead, run `xcodegen generate`, open `Taplyne.xcodeproj`, pick the TaplyneCompanion scheme and the device, set your team under Signing & Capabilities, and click Run.

### 6b. Pair

In Taplyne, open Settings > Phone & iPad and select the device to control.

- **Through the relay (works anywhere):** finish Part 5 first, then click Load relay pairing code.
- **On the same private network:** enter the Mac's reachable address and click Create a new companion key.

Open the companion on the phone, tap Scan pairing code, check the address and tap Connect.

Check: send "Describe the screen without tapping anything." For voice, choose Live AI voice (API), tap Start live voice and allow microphone access. Wait for Microphone connected and a moving input meter, then say "Go Home."

A companion key can control only the one device it was made for. Making a new key cancels the old one. Keep the QR code private.

## Troubleshooting

- **Phone not found:** unlock it, tap Trust, try another cable. `pymobiledevice3 usbmux list` should list it.
- **Black screen:** unlock the phone. If it stays black, use Restart iPhone in the setup card.
- **Bluetooth not working:** prepare pairing again in Taplyne, then pick this Mac in the iPhone's Bluetooth settings.
- **Taps land in the wrong spot:** calibrate again on the Home Screen without touching the phone.
- **AssistiveTouch menu in the way:** turn off Always Show Menu in Settings > Accessibility > Touch > AssistiveTouch. Keep AssistiveTouch on.
- **Typed text not verified:** check that Handoff is on and the Mac and phone use the same Apple Account.
- **Remote device offline:** make sure the Mac is awake and online and the phone is unlocked. Check the relay address. If the runner stopped, plug in and run setup again.
- **Runner signing failed:** open Xcode, confirm the account, team and device signing access, and check Developer Mode. Then retry setup.
- **Voice cannot start:** validate the OpenAI key in Mac Settings > Agent and allow microphone access on the device.
- **Voice shows Recovering:** let it finish. If it fails, end voice and start again.

## How results work

Every action returns a fresh screenshot and one of three results:

- `verified`: the expected result is on screen.
- `unverified`: input may have arrived, but the result is not proven. Look before continuing.
- `failed`: it did not work. Check `input_delivered` before trying again.

Never automatically repeat an uncertain send, purchase or form submission.

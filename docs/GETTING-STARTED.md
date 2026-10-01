# Getting started with Taplyne

[Download Taplyne for Mac](https://github.com/isaachorowitz/TapLyne-App/releases/latest/download/Taplyne.dmg). Taplyne is free and open source. Your chosen AI provider bills its own usage.

## First run over USB

You need macOS 15 or later, an unlocked iPhone or iPad, and a USB data cable. This mode uses Bluetooth for input and installs nothing on the phone.

1. Open the downloaded DMG and drag **Taplyne** to **Applications**.
2. Install [Homebrew](https://brew.sh) if needed. In Terminal, run `brew install uv && uv tool install pymobiledevice3`.
3. Plug in the phone, unlock it and accept **Trust This Computer**. Open Taplyne and select the device in the sidebar.
4. Follow the setup card. Allow **Camera** access for the phone's screen, choose **Prepare Bluetooth Pairing**, then select your Mac under **Settings > Bluetooth** on the phone. Approve the matching pairing code. Enable **AssistiveTouch** and choose **Calibrate Pointer** while the Home Screen is visible.
5. Open **Taplyne > Settings > Agent**. Choose **OpenAI API key (BYOK)**, enter your own key, click **Save key**, then **Validate saved key**. If you already use Claude Code, you can select **Claude Code login** instead.
6. Ask **“Describe the screen without tapping anything.”** Check the reply against the phone, then try **“Go Home.”**

Keep the phone unlocked. **Pause** stops automatic input; **Take over** gives you manual control. **Resume** lets the agent inspect the current screen before continuing. Inspect any action reported as unverified before repeating it.

Camera permission is used to receive the phone's USB screen. Taplyne does not use the Mac's camera. English typing needs an English hardware keyboard layout on the phone; Unicode paste in USB mode remains experimental.

## Remote control and phone voice

Remote mode lets the Mac keep doing the work while the phone uses another network. The Mac must stay running and online. It has three setup requirements beyond USB mode:

- **Apple development tools:** Xcode, an Apple account with signing access, your ten-character Apple Team ID, and Developer Mode enabled on the device. The app displays the runner's signing expiry; renew it before expiry.
- **Your own relay:** a server with a domain and TLS, running the included [Relay service](../Relay/README.md#tls-deployment). You supply its `wss://` address and enrollment token. Taplyne does not include a hosted relay account.
- **The native companion:** install it with Xcode using the steps below. It is not yet available through the App Store or TestFlight.

### Install the companion

Install Xcode and add your Apple account in **Xcode > Settings > Accounts**. With Homebrew installed, prepare the source project:

```sh
brew install xcodegen uv
git clone https://github.com/isaachorowitz/TapLyne-App.git
cd TapLyne-App
xcodegen generate
open Taplyne.xcodeproj
```

In Xcode, select the **TaplyneCompanion** scheme and your connected iPhone or iPad as the run destination. In the companion target's **Signing & Capabilities**, select your development team and automatic signing. Unlock the device, enable Developer Mode if prompted, then click **Run**. Complete Apple's trust or signing prompts on your own device.

### Pair and verify

1. In the Mac app, select the USB-connected device. Open **Settings > Remote device**.
2. Enter your Apple Team ID, relay `wss://` address and enrollment token. Click **Install and pair runner**. Keep the device connected and unlocked until setup finishes.
3. Check the **Device** connection and open a fresh screen in Taplyne. A successful install alone does not establish control. If paused, inspect the screen and click **Resume**, then try **Go Home**.
4. Open **Settings > Phone & iPad** and click **Load relay pairing code**. In the companion, tap **Scan pairing code**, check the relay address and tap **Connect**. Keep the pairing code private.
5. Send **“Describe the screen without tapping anything.”** Verify the reply. For voice, choose **Live AI voice (API)**, tap **Start live voice** and allow microphone access. Watch for **Microphone connected** and a moving input meter, then say **“Go Home.”**
6. Unplug USB and repeat the harmless check. Test again after changing networks before relying on remote access.

Live voice requires an OpenAI API key configured on the Mac, including when Claude Code handles reasoning. It uses separately billed OpenAI API access. Replies default to English; ask explicitly to switch languages. **Native dictation** is also available with your selected reasoning provider.

The physical iPad passed capture, Home control, companion chat and spoken replies with USB disconnected and the iPad on an iPhone cellular hotspot while the Mac stayed on Wi-Fi. This verifies that tested network path. Direct cellular operation on every phone, external audio routes and recovery after the OS kills the runner are not established. If the device restarts or iOS stops the runner, reconnect locally and run setup again. See the [verification matrix](plans/2026-10-01-feature-parity.md) for tested devices and remaining checks.

## If something stops setup

| What you see | What to do |
| --- | --- |
| No phone in the sidebar | Unlock it, accept Trust and use a USB data cable. Check that `pymobiledevice3 usbmux list` lists it. |
| No screen | Allow Camera access and unlock the phone. The USB setup card offers Restart iPhone if capture remains unavailable. |
| Bluetooth still waiting | Choose Prepare Bluetooth Pairing again and pair from the phone's Bluetooth settings. Keep AssistiveTouch enabled. |
| Runner signing failed | Open Xcode, confirm your account/team and device signing access, and check Developer Mode. Retry setup after resolving Xcode's message. |
| Remote device offline | Keep both endpoints online and the device unlocked. Check your relay address. Relaunch the runner locally if it has stopped. |
| Voice cannot start | Validate the OpenAI API key in Mac Settings > Agent and allow microphone access on the device. |
| Voice shows Recovering | Let its bounded recovery finish. If it reports failure, end voice and start again; check microphone permission and input route. |

For external agents, open **Settings > Connect AI** and copy the MCP configuration. More API details and known limitations are in the [README](../README.md).

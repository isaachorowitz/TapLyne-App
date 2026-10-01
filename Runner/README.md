# Taplyne XCTest runner

Taplyne runs an encrypted outgoing relay peer **inside** the WebDriverAgent XCTest process. The runner calls `TLRunnerRelay.start()` before WDA starts its local HTTP server. A small second patch makes WDA's MJPEG listener honor the same `USE_IP` binding as its HTTP listener. The peer accepts the exact routes in `RelayWDAProxy` and forwards them to `127.0.0.1:8100` on the device. The relay cannot choose another destination, header, or path. WebDriverAgent is pinned to [Appium v16.13.6](https://github.com/appium/WebDriverAgent/releases/tag/v16.13.6), commit `9d1d17ddb59e6097ddc3324b23ca9f4174507b12`; its BSD license remains in the generated checkout.

From the repository root, prepare a reproducible checkout with:

```sh
python3 scripts/prepare-runner.py --source /path/to/clean/WebDriverAgent-v16.13.6
```

Without `--source`, the script clones the pinned tag from Appium GitHub. It checks the exact commit and a clean source tree, archives that commit into the ignored `.build/runner/wda` path, adds the bridge and the four shared relay Swift files to the runner target, and checks prepared-file integrity on reuse. It does not edit the upstream checkout. The generated project uses XML property-list syntax, which Xcode accepts.

To build and stage a runner for a connected device with Developer Mode and a valid Apple signing team:

```sh
scripts/run-runner.sh --udid DEVICE_UDID --team APPLE_TEAM_ID --build-only
scripts/run-runner.sh --udid DEVICE_UDID --team APPLE_TEAM_ID --install-only
```

For a device that supports Apple's native RemoteXPC tunnel, build, install, pair, and launch the runner in the background with:

```sh
scripts/run-runner.sh --udid DEVICE_UDID --team APPLE_TEAM_ID --bootstrap /private/path/taplyne-relay.json --background
```

The background route uses `uv` and pinned `pymobiledevice3==11.19.4` to ask the device's RemoteXPC process control service to launch the signed XCTest host with `ActivateSuspended`. It closes the Mac-side launch channel and exits after the launch request succeeds. Exit status zero means the request was accepted; verify the encrypted relay and a fresh WDA status or screenshot before treating the runner as ready. The device owns its lifetime and may stop it later. `--run-only --background` relaunches an already installed build without restaging a pairing. Both WDA listeners are pinned to `127.0.0.1`; the background launch supplies `USE_IP` and `USE_PORT`, while the foreground route pins them in `.xctestrun`.

The explicit foreground XCTest route remains available for a device where native RemoteXPC is unsupported:

```sh
scripts/run-runner.sh --udid DEVICE_UDID --team APPLE_TEAM_ID
```

This route uses `xcodebuild test-without-building` and requires its Mac-side XCTest channel to remain attached. It cannot prove off-cable use. Run it under the caller's registered task process group and stop that exact group when the session ends. `--bootstrap /private/path/taplyne-relay.json` stages a new runner pairing during install or run, before launch. Both routes build with `xcodebuild build-for-testing`, check the app signature and provisioning expiry, and install with `devicectl`. Build and launch logs are private under `.build/runner/logs`; they can contain device data and should not be copied to a public issue.

The companion setup path stages a JSON-encoded `RelayConfiguration` with `role: "device"` and `scope: "runner"` at `Documents/taplyne-relay.json` in the runner app's data container, through `devicectl device copy to --domain-type appDataContainer --domain-identifier agency.ziplyne.taplyne.wda.xctrunner`. On the next XCTest start, the bridge validates the exact file, saves it to the runner's own Keychain, and removes the bootstrap file. The bundle and build logs never contain pairing secrets. Reinstalling the same app retains its data container and Keychain item, while uninstalling requires staging the pairing again. The runner neither reads the companion's Keychain nor needs a shared Keychain entitlement.

The current [Appium guide](https://appium.github.io/appium-xcuitest-driver/latest/guides/run-preinstalled-wda/) describes native RemoteXPC launch for preinstalled WDA and warns that a plain `devicectl` app launch is unreliable on recent iOS. A signed install alone does not prove the runner is serving. Provisioning and physical-device behavior must be checked on the intended phone. Apple may require its normal developer trust and device preparation steps.

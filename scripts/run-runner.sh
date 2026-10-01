#!/usr/bin/env bash
# Build, install, and enter the actual XCTest runner on one selected device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/runner"
SOURCE="$WORK/wda"
DERIVED="$WORK/DerivedData"
LOGS="$WORK/logs"
BUNDLE_ID="agency.ziplyne.taplyne.wda.xctrunner"
UDID=""
TEAM=""
MODE="all"
BACKGROUND=0
UPSTREAM=""
BOOTSTRAP=""

usage() {
  cat <<'USAGE'
Usage: scripts/run-runner.sh --udid DEVICE_UDID --team APPLE_TEAM_ID [options]
  --source PATH    Clean, exact WebDriverAgent v16.13.6 checkout
  --bootstrap PATH Private JSON RelayConfiguration to stage in runner Documents
  --build-only     Prepare and build for testing, with no device installation
  --install-only   Reinstall an existing build on the selected device
  --run-only       Relaunch an already installed, signed runner
  --background     Launch the installed runner through native RemoteXPC and exit

Without --background, the full command stays attached while XCTest runs and
requires the Mac's device connection. Stop its exact task-owned process group
to end it. The background route needs uv, closes its Mac-side launch channel,
and does not guarantee the device will keep the runner alive indefinitely.
All build and launch logs stay in .build/runner/logs with private permissions.
USAGE
}

while (($#)); do
  case "$1" in
    --udid|--team|--source|--bootstrap)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --udid) UDID="$2" ;;
        --team) TEAM="$2" ;;
        --source) UPSTREAM="$2" ;;
        --bootstrap) BOOTSTRAP="$2" ;;
      esac
      shift 2 ;;
    --build-only) MODE="build"; shift ;;
    --install-only) MODE="install"; shift ;;
    --run-only) MODE="run"; shift ;;
    --background) BACKGROUND=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$UDID" =~ ^[A-Za-z0-9-]+$ ]] || { echo 'Provide a specific device UDID.' >&2; exit 2; }
[[ "$TEAM" =~ ^[A-Za-z0-9]+$ ]] || { echo 'Provide an Apple Developer team ID.' >&2; exit 2; }
[[ "$BACKGROUND" == 0 || "$MODE" == all || "$MODE" == run ]] || { echo '--background requires a run stage.' >&2; exit 2; }
mkdir -p "$LOGS"
chmod 700 "$LOGS"
umask 077

status() { printf '{"event":"%s","detail":"%s"}\n' "$1" "$2"; }
fail() {
  status runner_error "$1"
  echo "Runner command failed; inspect the private log at $2. Check pairing, Developer Mode, signing team and provisioning profile." >&2
  exit 1
}
run_logged() {
  local phase="$1"; shift
  local logfile="$LOGS/$phase.log"
  status "$phase" started
  if ! "$@" >"$logfile" 2>&1; then fail "$phase" "$logfile"; fi
  status "$phase" complete
}

prepare() {
  if [[ -n "$UPSTREAM" ]]; then
    run_logged prepare python3 "$ROOT/scripts/prepare-runner.py" --source "$UPSTREAM"
  else
    run_logged prepare python3 "$ROOT/scripts/prepare-runner.py"
  fi
}

verify_build() {
  local runner="$DERIVED/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
  [[ -d "$runner" ]] || fail missing_runner "$LOGS/build.log"
  /usr/bin/codesign --verify --deep --strict "$runner" >"$LOGS/signature.log" 2>&1 || fail invalid_signature "$LOGS/signature.log"
  python3 - "$runner" <<'PY'
import datetime, pathlib, plistlib, subprocess, sys
bundle = pathlib.Path(sys.argv[1])
identifier = plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleIdentifier']
if identifier != 'agency.ziplyne.taplyne.wda.xctrunner':
    raise SystemExit('Unexpected signed runner identifier')
profile = bundle / 'embedded.mobileprovision'
if not profile.exists():
    raise SystemExit('Signed runner has no provisioning profile')
raw = subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)], stderr=subprocess.DEVNULL)
expiry = plistlib.loads(raw)['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if expiry <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('Runner provisioning profile expired')
print('{"event":"runner_signature","detail":"valid","profileExpires":"' + expiry.date().isoformat() + '"}')
PY
}

pin_xctest_network() {
  local runs=("$DERIVED"/Build/Products/*.xctestrun)
  [[ ${#runs[@]} == 1 && -f "${runs[0]}" ]] || fail missing_xctestrun "$LOGS/build.log"
  python3 - "${runs[0]}" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
run = plistlib.loads(path.read_bytes())
targets = [v for k, v in run.items() if isinstance(v, dict) and 'WebDriverAgentRunner' in k]
if len(targets) != 1:
    raise SystemExit('Expected exactly one WDA XCTest target in xctestrun')
environment = targets[0].setdefault('EnvironmentVariables', {})
environment['USE_IP'] = '127.0.0.1'
environment['USE_PORT'] = '8100'
with path.open('wb') as output:
    plistlib.dump(run, output)
PY
  status runner_network loopback_only
}

if [[ "$MODE" == all || "$MODE" == build ]]; then
  prepare
  run_logged build xcodebuild -quiet build-for-testing \
    -project "$SOURCE/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner \
    -destination "platform=iOS,id=$UDID" -destination-timeout 30 \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic GCC_TREAT_WARNINGS_AS_ERRORS=NO
  verify_build
  pin_xctest_network
fi

if [[ "$MODE" == all || "$MODE" == install ]]; then
  verify_build
  run_logged install xcrun devicectl device install app --device "$UDID" \
    "$DERIVED/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
  status runner_installed "$BUNDLE_ID"
fi

if [[ -n "$BOOTSTRAP" ]]; then
  [[ "$MODE" != build ]] || { echo '--bootstrap requires install or run stage.' >&2; exit 2; }
  [[ -f "$BOOTSTRAP" && ! -L "$BOOTSTRAP" ]] || fail invalid_bootstrap "$LOGS/bootstrap.log"
  if [[ $(stat -f %z "$BOOTSTRAP") -gt 4096 ]]; then fail invalid_bootstrap "$LOGS/bootstrap.log"; fi
  python3 - "$BOOTSTRAP" <<'PY'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(config, dict) or config.get('role') != 'device' or config.get('scope') != 'runner':
    raise SystemExit('Runner bootstrap must be a device-role runner-scope pairing')
PY
  run_logged bootstrap xcrun devicectl device copy to --device "$UDID" \
    --source "$BOOTSTRAP" --destination Documents/taplyne-relay.json \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID"
fi

if [[ "$MODE" == all || "$MODE" == run ]]; then
  [[ -d "$SOURCE/WebDriverAgent.xcodeproj" ]] || fail missing_source "$LOGS/prepare.log"
  [[ -d "$DERIVED/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app" ]] || fail missing_runner "$LOGS/build.log"
  verify_build
  if [[ "$BACKGROUND" == 1 ]]; then
    UV="$(command -v uv || true)"
    if [[ -z "$UV" && -x "$HOME/.local/bin/uv" ]]; then UV="$HOME/.local/bin/uv"; fi
    [[ -n "$UV" ]] || fail missing_uv "$LOGS/background-launch.log"
    status runner_background started
    if ! UV_NO_PROGRESS=1 "$UV" run --no-project --with pymobiledevice3==11.19.4 \
      python3 "$ROOT/Runner/launch-background.py" --udid "$UDID" \
      >"$LOGS/background-launch.log" 2>&1; then
      fail runner_background "$LOGS/background-launch.log"
    fi
    status runner_background launched
  else
    pin_xctest_network
    runs=("$DERIVED"/Build/Products/*.xctestrun)
    status runner_xctest attached
    # The Xcode XCTest route is the explicit tethered fallback when native
    # RemoteXPC is unsupported; its lifetime follows this foreground command.
    if ! xcodebuild -quiet test-without-building \
      -xctestrun "${runs[0]}" \
      -destination "platform=iOS,id=$UDID" -destination-timeout 30 \
      -derivedDataPath "$DERIVED" -only-testing:WebDriverAgentRunner/UITestingUITests/testRunner \
      DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic GCC_TREAT_WARNINGS_AS_ERRORS=NO >"$LOGS/xctest.log" 2>&1; then
      fail xctest "$LOGS/xctest.log"
    fi
    status runner_xctest exited
  fi
fi

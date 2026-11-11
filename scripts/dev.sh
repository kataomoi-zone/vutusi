#!/usr/bin/env bash
# Build a signed Debug vutusi.app, install it to /Applications, and launch it.
#
# The app activates its Camera Extension on launch, and sysextd replaces the
# installed extension only when CFBundleVersion differs. The version is the
# newest modification time among the extension's files, so a run replaces the
# extension exactly when it changed.
#
# A running process keeps the CoreMediaIO device list it saw at launch, so the
# app that replaced the extension never sees the new device. Once the new
# version is active, the app is launched again to pick it up.
#
# The script exits after launch instead of tailing logs so it can run from a
# non-interactive shell; it prints recent logs and the extension state, and
# `scripts/logs.sh` tails the rest.
#
# Required environment (see .envrc.sample; .envrc is sourced when present):
#   VUTUSI_ASC_KEY_PATH  App Store Connect API .p8 path (Admin role)
#   VUTUSI_ASC_KEY_ID    API key ID
#   VUTUSI_ASC_ISSUER    Issuer ID

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

require_asc_key
xcodegen_generate

scripts/build-web.sh

mkdir -p build
log_file=build/xcodebuild.log
# Derived from the extension's own files, so the installed extension is replaced only
# when it changed: video apps that are open keep a stale device list after a replacement
# and lose the camera until they restart.
# project.yml is left out because app-only edits there are common; after changing the
# extension target's build settings, touch a file under Resources/CameraExtension.
# macOS's own stat by path: a GNU stat earlier on PATH takes other flags.
version="$(find Sources/CameraExtension Sources/Shared Resources/CameraExtension -type f -exec /usr/bin/stat -f %m {} + | sort -n | tail -1)"
echo "dev.sh: building (full log: $log_file)"
if ! xcodebuild \
  -project vutusi.xcodeproj -scheme vutusi -configuration Debug \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$VUTUSI_ASC_KEY_PATH" \
  -authenticationKeyID "$VUTUSI_ASC_KEY_ID" \
  -authenticationKeyIssuerID "$VUTUSI_ASC_ISSUER" \
  CURRENT_PROJECT_VERSION="$version" \
  build > "$log_file" 2>&1; then
  grep -E "error:|BUILD FAILED" "$log_file" | sort -u >&2 || tail -30 "$log_file" >&2
  exit 1
fi

app=/Applications/vutusi.app
# LaunchServices fails with -600 when asked to open an app whose old process is still
# exiting, so wait for it to be gone.
quit_app() {
  pkill -x vutusi || true
  while pgrep -x vutusi > /dev/null; do sleep 0.2; done
}

quit_app
rm -rf "$app"
ditto build/DerivedData/Build/Products/Debug/vutusi.app "$app"
open "$app"

extension_id=com.kawarimidoll.vutusi.CameraExtension
# Compared as a string: `grep -q` at the end of the pipe stops reading early, and under
# pipefail the SIGPIPE it leaves the earlier commands with reads as "not active".
extension_active() {
  [[ "$(systemextensionsctl list | grep -F "$extension_id (" | grep -F "/$version)")" == *"[activated enabled]"* ]]
}
for _ in $(seq 1 30); do
  extension_active && break
  sleep 1
done
if extension_active; then
  quit_app
  open "$app"
else
  echo "dev.sh: extension $version is not active yet (approve it in System Settings, then relaunch vutusi)"
fi

sleep 3
log show --last 40s --info --style compact --predicate 'subsystem == "com.kawarimidoll.vutusi"'
systemextensionsctl list | grep -F com.kawarimidoll.vutusi || echo "dev.sh: extension not listed yet"

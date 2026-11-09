#!/usr/bin/env bash
# Build a signed Debug vutusi.app, install it to /Applications, and launch it.
#
# The app activates its Camera Extension on launch, so one run replaces the
# installed extension with the freshly built one. CFBundleVersion is bumped to
# the current epoch on every build because sysextd skips the replacement when
# the version is unchanged.
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

if [[ -z "${VUTUSI_ASC_KEY_ID:-}" && -f .envrc ]]; then
  # shellcheck disable=SC1091
  source .envrc
fi
missing=()
for v in VUTUSI_ASC_KEY_PATH VUTUSI_ASC_KEY_ID VUTUSI_ASC_ISSUER; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if (( ${#missing[@]} > 0 )); then
  echo "dev.sh: missing env: ${missing[*]} (see .envrc.sample)" >&2
  exit 1
fi

if command -v xcodegen > /dev/null; then
  xcodegen generate --quiet
else
  nix shell nixpkgs#xcodegen -c xcodegen generate --quiet
fi

mkdir -p build
log_file=build/xcodebuild.log
version="$(date +%s)"
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
pkill -x vutusi || true
rm -rf "$app"
ditto build/DerivedData/Build/Products/Debug/vutusi.app "$app"
open "$app"

extension_id=com.kawarimidoll.vutusi.CameraExtension
for _ in $(seq 1 30); do
  systemextensionsctl list | grep -F "$extension_id (" | grep -F "/$version)" | grep -qF "[activated enabled]" && break
  sleep 1
done
if systemextensionsctl list | grep -F "/$version)" | grep -qF "[activated enabled]"; then
  pkill -x vutusi || true
  sleep 1
  open "$app"
else
  echo "dev.sh: extension $version is not active yet (approve it in System Settings, then relaunch vutusi)"
fi

sleep 3
log show --last 40s --info --style compact --predicate 'subsystem == "com.kawarimidoll.vutusi"'
systemextensionsctl list | grep -F com.kawarimidoll.vutusi || echo "dev.sh: extension not listed yet"

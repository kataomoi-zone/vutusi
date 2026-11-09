#!/usr/bin/env bash
# Build the Spike B app and run it through each configuration, appending JSON
# lines to the log (default: z-ai/spike-b/run-<time>.log at the repo root).
#
# Run from a normal terminal (not inside Claude Code's sandbox). The first run
# shows the camera permission prompt; allow it within 30 seconds.
set -euo pipefail

cd "$(dirname "$0")"
root="$(cd ../.. && pwd -P)"
log="${1:-$root/z-ai/spike-b/run-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$log")"

[[ -f web/vendor/holistic_landmarker.task ]] || ./fetch-vendor.sh
if command -v xcodegen > /dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
xcodebuild -project webtracking.xcodeproj -scheme webtracking -configuration Release \
  -derivedDataPath .build/dd build > .build.log 2>&1 || { grep -E "error:" .build.log >&2; exit 1; }
app=.build/dd/Build/Products/Release/webtracking.app

run() {
  local serve=$1 mode=$2 query=$3 duration=$4
  echo "run.sh: $serve $mode $query (${duration}s)"
  open -W -n "$app" --args --serve "$serve" --mode "$mode" --query "$query" --duration "$duration" --log "$log"
}

# Run 1 (run-20261109-144837.log) showed vutusi:// is a secure context, and that
# getUserMedia never resolves while the page has no visible window (detached,
# offscreen). This run tries windows that are on screen but invisible.

# Visible baselines first; the first one also waits for the permission prompt.
run scheme visible "driver=raf&worker=1" 30
run scheme visible "driver=raf&worker=0" 20

for mode in transparent alpha0; do
  for driver in raf timeout; do
    run scheme "$mode" "driver=$driver&worker=1" 20
  done
done

echo "run.sh: done -> $log"

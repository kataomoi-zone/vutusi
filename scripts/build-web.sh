#!/usr/bin/env bash
# Prepare web/, the tracking page bundled into the app as is: download MediaPipe
# (once) into web/vendor/ and compile web-src/worker.ts with animovi's solvers into
# web/worker.js. Both outputs are gitignored. The MediaPipe version and model match
# animovi's (src/lib/mediapipe/constants.ts) so tracking behaves the same.
#
# Sources stay in web-src/ so that only what the page loads ships in the app; the
# animovi license ships as web/LICENSE-animovi.txt, since worker.js contains its code.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=0.10.35
vendor=web/vendor
if [[ ! -f "$vendor/holistic_landmarker.task" ]]; then
  mkdir -p "$vendor/wasm"
  npm_base="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@$VERSION"
  curl -fsSL -o "$vendor/vision_bundle.mjs" "$npm_base/vision_bundle.mjs"
  for f in vision_wasm_internal.js vision_wasm_internal.wasm vision_wasm_nosimd_internal.js vision_wasm_nosimd_internal.wasm; do
    curl -fsSL -o "$vendor/wasm/$f" "$npm_base/wasm/$f"
  done
  curl -fsSL -o "$vendor/holistic_landmarker.task" \
    https://storage.googleapis.com/mediapipe-models/holistic_landmarker/holistic_landmarker/float16/1/holistic_landmarker.task
fi

esbuild_args=(web-src/worker.ts --bundle --format=esm --external:./vendor/* --outfile=web/worker.js --log-level=warning)
if command -v esbuild > /dev/null; then
  esbuild "${esbuild_args[@]}"
else
  nix shell nixpkgs#esbuild -c esbuild "${esbuild_args[@]}"
fi

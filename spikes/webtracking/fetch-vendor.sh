#!/usr/bin/env bash
# Download MediaPipe tasks-vision and the holistic model into web/vendor/,
# pinned to the release animovi uses (src/lib/mediapipe/constants.ts).
set -euo pipefail

VERSION=0.10.35
cd "$(dirname "$0")"
dest=web/vendor
mkdir -p "$dest/wasm"

npm_base="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@$VERSION"
curl -fsSL -o "$dest/vision_bundle.mjs" "$npm_base/vision_bundle.mjs"
for f in vision_wasm_internal.js vision_wasm_internal.wasm vision_wasm_nosimd_internal.js vision_wasm_nosimd_internal.wasm; do
  curl -fsSL -o "$dest/wasm/$f" "$npm_base/wasm/$f"
done
curl -fsSL -o "$dest/holistic_landmarker.task" \
  https://storage.googleapis.com/mediapipe-models/holistic_landmarker/holistic_landmarker/float16/1/holistic_landmarker.task

ls -l "$dest" "$dest/wasm"

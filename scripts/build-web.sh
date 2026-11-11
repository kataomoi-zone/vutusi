#!/usr/bin/env bash
# Prepare web/, the tracking page bundled into the app as is: download MediaPipe
# into web/vendor/ and compile web-src/worker.ts with animovi's solvers into
# web/worker.js. Both outputs are gitignored. The MediaPipe version and model match
# animovi's (src/lib/mediapipe/constants.ts) so tracking behaves the same.
#
# Sources stay in web-src/ so that only what the page loads ships in the app; the
# animovi license ships as web/LICENSE-animovi.txt, since worker.js contains its code.
set -euo pipefail

cd "$(dirname "$0")/.."

MEDIAPIPE_VERSION=0.10.35
# The downloads ship inside the signed app, so one that differs from these stops the
# build. Update them together with the version or the model URL.
checksums="\
55d7ab624fbb70dcc5adc4ae6d7ea9cfcb569139d3dbfbf2b1deafcb966bc0fe  vision_bundle.mjs
e7fd9858e8e8f221d9b96eddc11f8e077f263e0b7bbd79d3cbe882b134274f8c  wasm/vision_wasm_internal.js
6a5c64584c2ab61c763b6e204afbdbc7ce1caf7f5216187322bca8df94f646bc  wasm/vision_wasm_internal.wasm
438d1fe8ff7f4d946025bc211c291543c037d8a3785ed4eee60f1f521b236296  wasm/vision_wasm_nosimd_internal.js
8a3092d34c79d3f57e6ba8592105e8a90f6b07c27891ffecd14cca428bfd3e31  wasm/vision_wasm_nosimd_internal.wasm
e2dab61191e2dcd0a15f943d8e3ed1dce13c82dfa597b9dd39f562975a50c3f8  holistic_landmarker.task"
vendor=web/vendor
if [[ "$(cat "$vendor/VERSION" 2> /dev/null)" != "$MEDIAPIPE_VERSION" ]]; then
  rm -rf "$vendor"
  mkdir -p "$vendor/wasm"
  npm_base="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@$MEDIAPIPE_VERSION"
  curl -fsSL -o "$vendor/vision_bundle.mjs" "$npm_base/vision_bundle.mjs"
  for f in vision_wasm_internal.js vision_wasm_internal.wasm vision_wasm_nosimd_internal.js vision_wasm_nosimd_internal.wasm; do
    curl -fsSL -o "$vendor/wasm/$f" "$npm_base/wasm/$f"
  done
  curl -fsSL -o "$vendor/holistic_landmarker.task" \
    https://storage.googleapis.com/mediapipe-models/holistic_landmarker/holistic_landmarker/float16/1/holistic_landmarker.task
  # Written last, so an interrupted download is fetched again next time.
  echo "$MEDIAPIPE_VERSION" > "$vendor/VERSION"
fi
# Checked on every build, so a copy changed after its download is caught too.
(cd "$vendor" && shasum -a 256 -c - <<< "$checksums" > /dev/null) || {
  echo "build-web.sh: checksum mismatch in $vendor (delete it to download again)" >&2
  exit 1
}

esbuild_args=(web-src/worker.ts --bundle --format=esm --external:./vendor/* --outfile=web/worker.js --log-level=warning)
if command -v esbuild > /dev/null; then
  esbuild "${esbuild_args[@]}"
else
  nix shell nixpkgs#esbuild -c esbuild "${esbuild_args[@]}"
fi

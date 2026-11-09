// Tracking worker: MediaPipe HolisticLandmarker plus animovi's solvers, as in
// animovi's src/lib/worker/tracking.worker.ts. Posts the solver output only;
// smoothing and posing happen in Swift (TrackingApplier).

import { FilesetResolver, HolisticLandmarker } from './vendor/vision_bundle.mjs'
import { solveHolistic } from './animovi/solver/holistic-solver'

let landmarker: HolisticLandmarker | null = null

async function init() {
  // MediaPipe loads its Emscripten loader with import() in a module worker, which
  // keeps `var ModuleFactory` module-scoped and fails with "ModuleFactory not set.".
  // Evaluating the loader as global code first defines it on `self`.
  const loaderURL = new URL('vendor/wasm/vision_wasm_internal.js', import.meta.url)
  ;(0, eval)(await (await fetch(loaderURL)).text())

  const vision = await FilesetResolver.forVisionTasks(new URL('vendor/wasm', import.meta.url).href)
  landmarker = await HolisticLandmarker.createFromOptions(vision, {
    baseOptions: {
      modelAssetPath: new URL('vendor/holistic_landmarker.task', import.meta.url).href,
      delegate: 'GPU',
    },
    runningMode: 'VIDEO',
  })
}

init().then(
  () => self.postMessage({ type: 'ready' }),
  (e) => self.postMessage({ type: 'error', message: `init: ${e?.stack ?? e}` }),
)

self.onmessage = (e: MessageEvent<{ bitmap: ImageBitmap; timestamp: number }>) => {
  const { bitmap, timestamp } = e.data
  try {
    if (!landmarker) return
    const r = landmarker.detectForVideo(bitmap, timestamp)
    const result = solveHolistic({
      face: r.faceLandmarks[0] ?? [],
      pose: r.poseLandmarks[0] ?? [],
      poseWorld: r.poseWorldLandmarks?.[0] ?? [],
      leftHand: r.leftHandLandmarks[0] ?? [],
      rightHand: r.rightHandLandmarks[0] ?? [],
    })
    self.postMessage({ type: 'result', result, timestamp })
  } catch (err) {
    self.postMessage({ type: 'error', message: `detect: ${err}`, timestamp })
  } finally {
    bitmap.close()
  }
}

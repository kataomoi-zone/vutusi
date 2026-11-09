// Tracking worker: MediaPipe HolisticLandmarker plus animovi's solvers, as in
// animovi's src/lib/worker/tracking.worker.ts. Posts the solver output, plus face
// metrics animovi does not compute (one-eye blinks and rounded mouths); smoothing and
// posing happen in Swift (TrackingApplier).
//
// MediaPipe's face blendshapes would give these directly, but their model fails on
// WebKit's WebGL backend ("UNIMPLEMENTED" in ml_drift/gl30), so the metrics come from
// the landmarks instead.

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

type Landmark = { x: number; y: number; z: number }

// Face mesh indices; "left" is the subject's left, as in animovi's face-solver.ts.
const LEFT_EYE = { upper: 386, lower: 374, outer: 263, inner: 362 }
const RIGHT_EYE = { upper: 159, lower: 145, outer: 33, inner: 133 }
const UPPER_LIP = 13, LOWER_LIP = 14, MOUTH_LEFT = 291, MOUTH_RIGHT = 61

/**
 * Ratios that do not change with the distance to the camera: each eye's opening over
 * its own width, and the mouth's opening and width over the distance between the outer
 * eye corners. Distances are 3D in pixels (z is in x's units), so turning the head
 * shrinks the width and the gap alike.
 */
function faceMetrics(face: Landmark[], width: number, height: number): Record<string, number> {
  const dist = (a: number, b: number) =>
    Math.hypot((face[a].x - face[b].x) * width, (face[a].y - face[b].y) * height, (face[a].z - face[b].z) * width)
  const eye = (e: typeof LEFT_EYE) => dist(e.upper, e.lower) / dist(e.outer, e.inner)
  const interocular = dist(LEFT_EYE.outer, RIGHT_EYE.outer)
  return {
    eyeLeft: eye(LEFT_EYE),
    eyeRight: eye(RIGHT_EYE),
    mouthOpen: dist(UPPER_LIP, LOWER_LIP) / interocular,
    mouthWidth: dist(MOUTH_LEFT, MOUTH_RIGHT) / interocular,
  }
}

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
    // Kept apart so that a failure here never costs the tracking result.
    let metrics: Record<string, number> = {}
    try {
      if (r.faceLandmarks[0]?.length) metrics = faceMetrics(r.faceLandmarks[0], bitmap.width, bitmap.height)
    } catch (err) {
      self.postMessage({ type: 'error', message: `face metrics: ${err}` })
    }
    self.postMessage({ type: 'result', result, faceMetrics: metrics, timestamp })
  } catch (err) {
    self.postMessage({ type: 'error', message: `detect: ${err}`, timestamp })
  } finally {
    bitmap.close()
  }
}

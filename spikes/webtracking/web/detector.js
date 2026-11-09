import { FilesetResolver, HolisticLandmarker } from './vendor/vision_bundle.mjs'

const base = new URL('.', import.meta.url)

export async function createHolistic() {
  const vision = await FilesetResolver.forVisionTasks(new URL('vendor/wasm', base).href)
  return HolisticLandmarker.createFromOptions(vision, {
    baseOptions: {
      modelAssetPath: new URL('vendor/holistic_landmarker.task', base).href,
      delegate: 'GPU',
    },
    runningMode: 'VIDEO',
  })
}

export function detect(landmarker, image, timestamp) {
  const t0 = performance.now()
  const r = landmarker.detectForVideo(image, timestamp)
  return {
    inferMs: performance.now() - t0,
    face: (r.faceLandmarks[0]?.length ?? 0) > 0,
    pose: (r.poseLandmarks[0]?.length ?? 0) > 0,
    left: (r.leftHandLandmarks[0]?.length ?? 0) > 0,
    right: (r.rightHandLandmarks[0]?.length ?? 0) > 0,
  }
}

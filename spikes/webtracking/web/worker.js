import { createHolistic, detect } from './detector.js'

let landmarker = null

try {
  // MediaPipe loads its Emscripten loader with import() in a module worker, which keeps
  // `var ModuleFactory` module-scoped, then fails with "ModuleFactory not set.".
  // Evaluating the loader as global code first defines it on `self`.
  const loader = await fetch(new URL('vendor/wasm/vision_wasm_internal.js', import.meta.url))
  ;(0, eval)(await loader.text())

  landmarker = await createHolistic()
  self.postMessage({ type: 'ready' })
} catch (e) {
  self.postMessage({ type: 'error', message: `worker init: ${e?.stack ?? e}` })
}

self.onmessage = (e) => {
  const { bitmap, timestamp } = e.data
  try {
    self.postMessage({ type: 'result', ...detect(landmarker, bitmap, timestamp) })
  } catch (err) {
    self.postMessage({ type: 'error', message: `detect: ${err}` })
  } finally {
    bitmap.close()
  }
}

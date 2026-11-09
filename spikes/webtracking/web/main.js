// Spike B: run MediaPipe HolisticLandmarker the way animovi does (one frame in
// flight, ImageBitmap to a module Worker) and report rates to Swift every second.
// Query: driver=raf|rvfc|timeout, worker=1|0

const params = new URLSearchParams(location.search)
const driver = params.get('driver') ?? 'raf'
const useWorker = params.get('worker') !== '0'
const targetInterval = 1000 / 30

const report = (msg) => window.webkit.messageHandlers.spike.postMessage(msg)
window.addEventListener('error', (e) => report({ type: 'error', message: `${e.message} @ ${e.filename}:${e.lineno}` }))
window.addEventListener('unhandledrejection', (e) => report({ type: 'error', message: String(e.reason) }))

report({
  type: 'env',
  href: location.href,
  isSecureContext: window.isSecureContext,
  hasMediaDevices: !!navigator.mediaDevices,
  hasOffscreenCanvas: typeof OffscreenCanvas !== 'undefined',
  userAgent: navigator.userAgent,
  driver,
  useWorker,
})

const stats = { ticks: 0, sent: 0, results: 0, face: 0, pose: 0, left: 0, right: 0, inferMs: 0 }
setInterval(() => {
  report({ type: 'stats', visibility: document.visibilityState, ...stats, inferMs: stats.results ? stats.inferMs / stats.results : 0 })
  for (const k in stats) stats[k] = 0
}, 1000)

let busy = false
function onResult(r) {
  busy = false
  stats.results++
  stats.inferMs += r.inferMs
  if (r.face) stats.face++
  if (r.pose) stats.pose++
  if (r.left) stats.left++
  if (r.right) stats.right++
}

async function setUpDetector() {
  if (useWorker) {
    const worker = new Worker('worker.js', { type: 'module' })
    await new Promise((resolve, reject) => {
      worker.onmessage = (e) => {
        if (e.data.type === 'ready') resolve()
        else if (e.data.type === 'error') reject(new Error(e.data.message))
      }
      worker.onerror = (e) => reject(new Error(`worker: ${e.message}`))
    })
    worker.onmessage = (e) => (e.data.type === 'result' ? onResult(e.data) : report(e.data))
    return async (video, timestamp) => {
      const bitmap = await createImageBitmap(video)
      worker.postMessage({ type: 'frame', bitmap, timestamp }, [bitmap])
    }
  }
  const { createHolistic, detect } = await import('./detector.js')
  const landmarker = await createHolistic()
  return async (video, timestamp) => onResult(detect(landmarker, video, timestamp))
}

async function main() {
  const video = document.getElementById('video')
  video.srcObject = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 } })
  await video.play()
  report({ type: 'camera', width: video.videoWidth, height: video.videoHeight })

  const t0 = performance.now()
  const send = await setUpDetector()
  report({ type: 'ready', initMs: Math.round(performance.now() - t0) })

  let last = 0
  const tick = (now) => {
    stats.ticks++
    if (now - last >= targetInterval && !busy && video.readyState >= 2) {
      last = now
      busy = true
      stats.sent++
      send(video, now).catch((e) => {
        busy = false
        report({ type: 'error', message: String(e) })
      })
    }
    schedule()
  }
  const schedule = {
    raf: () => requestAnimationFrame(tick),
    rvfc: () => video.requestVideoFrameCallback((now) => tick(now)),
    timeout: () => setTimeout(() => tick(performance.now()), 5),
  }[driver]
  schedule()
}

main().catch((e) => report({ type: 'error', message: `main: ${e}` }))

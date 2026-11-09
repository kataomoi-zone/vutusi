// Runs in an invisible WKWebView (WebTracker.swift). Captures the camera, feeds one
// frame at a time to the worker, and hands each result to Swift as a JSON string.
// Swift calls vutusi.start() / vutusi.stop() as the camera becomes needed or not.

const TARGET_INTERVAL_MS = 1000 / 25 // plan: tracking at 25fps, rendering at 30fps

const post = (msg) => window.webkit.messageHandlers.tracking.postMessage(JSON.stringify(msg))
window.addEventListener('error', (e) => post({ type: 'error', message: `${e.message} @ ${e.filename}:${e.lineno}` }))
window.addEventListener('unhandledrejection', (e) => post({ type: 'error', message: String(e.reason) }))

const video = document.getElementById('video')
const worker = new Worker('worker.js', { type: 'module' })
let workerReady = false
let running = false
let busy = false
let timer = null
let last = 0

worker.onmessage = (e) => {
  const msg = e.data
  if (msg.type === 'ready') {
    workerReady = true
    post({ type: 'ready' })
  } else if (msg.type === 'result') {
    busy = false
    // Capture to result, on the page's clock; Swift adds its own part.
    post({ type: 'result', result: msg.result, jsLatencyMs: performance.now() - msg.timestamp })
  } else {
    busy = false
    post(msg)
  }
}

function tick() {
  if (!running) return
  const now = performance.now()
  if (workerReady && !busy && video.readyState >= 2 && now - last >= TARGET_INTERVAL_MS) {
    last = now
    busy = true
    createImageBitmap(video).then(
      (bitmap) => worker.postMessage({ bitmap, timestamp: now }, [bitmap]),
      () => { busy = false },
    )
  }
  // setTimeout rather than requestAnimationFrame: rAF ran at 22fps here in Spike B, this at 25.
  timer = setTimeout(tick, 5)
}

// The default camera can be vutusi Camera itself, which then tracks the avatar's own
// image. Device labels are only exposed after a first getUserMedia in the page.
// LIMITATION: takes the first other camera; Phase 4 adds a camera setting.
async function physicalCameraId() {
  const find = async () =>
    (await navigator.mediaDevices.enumerateDevices()).find(
      (d) => d.kind === 'videoinput' && d.label && !d.label.startsWith('vutusi'),
    )
  let device = await find()
  if (!device) {
    const probe = await navigator.mediaDevices.getUserMedia({ video: true })
    probe.getTracks().forEach((t) => t.stop())
    device = await find()
  }
  if (!device) throw new Error('no camera other than vutusi Camera')
  return device.deviceId
}

window.vutusi = {
  async start() {
    if (running) return
    running = true
    try {
      const deviceId = await physicalCameraId()
      video.srcObject = await navigator.mediaDevices.getUserMedia({
        video: { deviceId: { exact: deviceId }, width: 640, height: 480 },
      })
      post({ type: 'camera', label: video.srcObject.getVideoTracks()[0]?.label })
      await video.play()
      post({ type: 'camera', on: true })
      tick()
    } catch (e) {
      running = false
      post({ type: 'error', message: `camera: ${e}` })
    }
  },
  stop() {
    running = false
    clearTimeout(timer)
    video.srcObject?.getTracks().forEach((t) => t.stop())
    video.srcObject = null
    busy = false
    post({ type: 'camera', on: false })
  },
}
post({ type: 'loaded' })

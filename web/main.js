// Runs in an invisible WKWebView (WebTracker.swift). Captures the camera, feeds one
// frame at a time to the worker, and hands each result to Swift as a JSON string.
// Swift calls vutusi.start() / vutusi.stop() as the camera becomes needed or not.

const TARGET_INTERVAL_MS = 1000 / 25 // tracking at 25fps, under the 30fps rendering

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
    post({ type: 'result', result: msg.result, faceMetrics: msg.faceMetrics, jsLatencyMs: performance.now() - msg.timestamp })
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
  // setTimeout rather than requestAnimationFrame: rAF ran at 22fps here in spikes/webtracking, this at 25.
  timer = setTimeout(tick, 5)
}

// The camera chosen in the settings, matched by name (Swift lists cameras with
// AVFoundation, whose names WebKit uses as labels), else the first camera that is not
// vutusi Camera: the default can be vutusi Camera itself, which then tracks the
// avatar's own image. Labels are only exposed after a first getUserMedia in the page.
let preferredCamera = ''
async function physicalCameraId() {
  const find = async () => {
    const cameras = (await navigator.mediaDevices.enumerateDevices()).filter(
      (d) => d.kind === 'videoinput' && d.label && !d.label.startsWith('vutusi Camera'),
    )
    return cameras.find((d) => d.label === preferredCamera) ?? cameras[0]
  }
  let device = await find()
  if (!device) {
    const probe = await navigator.mediaDevices.getUserMedia({ video: true })
    probe.getTracks().forEach((t) => t.stop())
    device = await find()
  }
  if (!device) throw new Error('no camera other than vutusi Camera')
  return device.deviceId
}

// Each start() takes a new generation; a stop() or a later start() makes an earlier
// one stale, and a stale start() releases the camera it was still opening.
let generation = 0

window.vutusi = {
  async start() {
    if (running) return
    running = true
    const mine = ++generation
    try {
      const deviceId = await physicalCameraId()
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { deviceId: { exact: deviceId }, width: 640, height: 480 },
      })
      if (mine !== generation) {
        stream.getTracks().forEach((t) => t.stop())
        return
      }
      video.srcObject = stream
      // An unplugged camera ends its track; start again, which falls back to another one.
      // stop() below does not fire this event.
      stream.getVideoTracks()[0]?.addEventListener('ended', () => {
        if (mine !== generation) return
        window.vutusi.stop()
        post({ type: 'error', message: 'camera: disconnected' })
        window.vutusi.start()
      })
      post({ type: 'camera', label: stream.getVideoTracks()[0]?.label })
      await video.play()
      if (mine !== generation) return
      post({ type: 'camera', on: true })
      tick()
    } catch (e) {
      if (mine !== generation) return
      // Releases a camera that opened before the failure.
      window.vutusi.stop()
      post({ type: 'error', message: `camera: ${e}` })
    }
  },
  stop() {
    generation++
    running = false
    clearTimeout(timer)
    video.srcObject?.getTracks().forEach((t) => t.stop())
    video.srcObject = null
    busy = false
    post({ type: 'camera', on: false })
  },
  async setCamera(name) {
    preferredCamera = name
    if (running) {
      this.stop()
      await this.start()
    }
  },
}
post({ type: 'loaded' })

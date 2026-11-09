import CoreMediaIO
import Foundation
import os

private let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "VirtualCameraBridge")

/// Sends frames to the Camera Extension's sink stream, and reports whether a video app
/// is showing the camera.
///
/// Whether a video app is watching is inferred in two ways, because the app's own sink
/// stream makes the whole device count as running:
/// - while not sending, kCMIODevicePropertyDeviceIsRunningSomewhere means a video app;
/// - while sending, the extension drains the sink only for a video app, so a sink queue
///   that stays full means nobody is watching any more. Frames that stop coming count as
///   nobody watching too, so a stuck renderer cannot keep the camera "in use" forever.
///
/// LIMITATION: polls once a second instead of listening for changes, so a video app waits
/// up to a second for the first frame.
/// @unchecked: every mutable member is touched only on `queue`.
final class VirtualCameraBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kawarimidoll.vutusi.VirtualCameraBridge", qos: .userInteractive)
    private let onSourceRunningChange: @Sendable (Bool) -> Void

    private var pollTimer: DispatchSourceTimer?
    private var isSending = false
    private var deviceID: CMIOObjectID?
    private var sinkStreamID: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?
    private var sourceRunning = false
    private var stalledFrames = 0
    private var lastFrameAt = ContinuousClock.now
    private var formatDescription: CMVideoFormatDescription?

    init(onSourceRunningChange: @escaping @Sendable (Bool) -> Void) {
        self.onSourceRunningChange = onSourceRunningChange
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    /// Starts or stops the sink stream that `send(_:)` feeds.
    func setSending(_ sending: Bool) {
        queue.async { [self] in sending ? startSending() : stopSending() }
    }

    /// Enqueues one frame; dropped unless sending.
    func send(_ pixelBuffer: CVPixelBuffer) {
        // Only read on `queue`, and the producer does not touch it after handing it over.
        nonisolated(unsafe) let frame = pixelBuffer
        queue.async { [self] in enqueue(frame) }
    }

    private func poll() {
        if deviceID == nil { discover() }
        guard let deviceID else { return }
        guard let runningSomewhere = cmioUInt32(deviceID, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) else {
            // A replaced extension comes back as new CMIO objects; look them up again.
            logger.info("device \(deviceID) went away")
            stopSending()
            self.deviceID = nil
            sinkStreamID = nil
            sinkQueue = nil
            if sourceRunning {
                sourceRunning = false
                onSourceRunningChange(false)
            }
            return
        }
        let running = !isSending
            ? runningSomewhere != 0
            : stalledFrames < Int(CameraIdentifiers.frameRate) / 2 && ContinuousClock.now - lastFrameAt < .seconds(1)
        guard running != sourceRunning else { return }
        sourceRunning = running
        logger.info("source running: \(running)")
        onSourceRunningChange(running)
    }

    private func discover() {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        let devices = cmioArray(system, CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        guard let device = devices.first(where: {
            cmioString($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == CameraIdentifiers.deviceID.uuidString
        }) else {
            logger.debug("device not found among \(devices.count) devices")
            return
        }
        let streams = cmioArray(device, CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        guard let sink = streams.first(where: {
            cmioString($0, CMIOObjectPropertySelector(kCMIOObjectPropertyName)) == CameraIdentifiers.sinkStreamName
        }) else {
            logger.error("sink stream not found among \(streams.count) streams")
            return
        }
        deviceID = device
        sinkStreamID = sink
        logger.info("found device \(device) with sink stream \(sink)")
    }

    private func startSending() {
        guard !isSending else { return }
        if deviceID == nil { discover() }
        guard let deviceID, let sinkStreamID else {
            logger.error("cannot send: device not found")
            return
        }
        if sinkQueue == nil {
            var queueRef: Unmanaged<CMSimpleQueue>?
            let status = CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &queueRef)
            guard status == noErr, let queueRef else {
                logger.error("CMIOStreamCopyBufferQueue failed: \(status)")
                return
            }
            sinkQueue = queueRef.takeRetainedValue()
        }
        let status = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard status == noErr else {
            logger.error("CMIODeviceStartStream failed: \(status)")
            return
        }
        stalledFrames = 0
        lastFrameAt = .now
        isSending = true
        logger.info("sending started")
    }

    private func stopSending() {
        guard isSending else { return }
        isSending = false
        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        logger.info("sending stopped")
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard isSending, let sinkQueue else { return }
        lastFrameAt = .now
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else {
            stalledFrames += 1
            return
        }
        stalledFrames = 0
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CameraIdentifiers.frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription!,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer else { return }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
    }
}

// MARK: - CoreMediaIO property helpers

private func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: selector,
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

/// Device and stream lists, both arrays of `CMIOObjectID`.
private func cmioArray(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
    var address = address(selector)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    let status = values.withUnsafeMutableBytes {
        CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, $0.baseAddress!)
    }
    return status == noErr ? values : []
}

private func cmioString(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
    var address = address(selector)
    guard CMIOObjectHasProperty(object, &address) else { return nil }
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(
        object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func cmioUInt32(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> UInt32? {
    var address = address(selector)
    var value: UInt32 = 0
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(object, &address, 0, nil, 4, &used, &value)
    return status == noErr ? value : nil
}

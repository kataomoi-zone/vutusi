import CoreMediaIO
import Foundation
import IOKit.audio
import os

let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "CameraExtension")

private let frameRate: Int32 = 30
private let width: Int32 = 1280
private let height: Int32 = 720

// Meet / Slack remember the selected camera by these IDs, so they must stay fixed.
private let deviceID = UUID(uuidString: "F34B316E-4D3A-4717-B767-6C57EFDB36F4")!
private let sourceStreamID = UUID(uuidString: "6CF13C9E-9796-4921-B060-53A33A146C14")!

// LIMITATION: test pattern only (a moving white stripe from Apple's template).
// The sink stream that receives frames from the app arrives in Phase 1.
// @unchecked: every mutable member is touched only on `queue`.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: StreamSource!
    private let queue = DispatchQueue(label: "com.kawarimidoll.vutusi.CameraExtension.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingCount = 0
    private var stripeRow = 0
    private var stripeStep = 4

    private var formatDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: width, height: height, extensions: nil, formatDescriptionOut: &formatDescription)
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &bufferPool)

        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil)
        streamSource = StreamSource(
            localizedName: "vutusi Camera.Video", streamID: sourceStreamID, streamFormat: format, device: device)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "vutusi Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        queue.async { [self] in
            streamingCount += 1
            guard timer == nil else { return }
            logger.info("source stream started")
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .nanoseconds(0))
            timer.setEventHandler { [self] in sendFrame() }
            timer.resume()
            self.timer = timer
        }
    }

    func stopStreaming() {
        queue.async { [self] in
            streamingCount = max(0, streamingCount - 1)
            guard streamingCount == 0 else { return }
            logger.info("source stream stopped")
            timer?.cancel()
            timer = nil
        }
    }

    private func sendFrame() {
        var pixelBuffer: CVPixelBuffer?
        let err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pixelBuffer)
        guard err == kCVReturnSuccess, let pixelBuffer else {
            logger.error("out of pixel buffers: \(err)")
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rows = CVPixelBufferGetHeight(pixelBuffer)
        let stripeHeight = 20
        memset(base, 0, rowBytes * rows)
        memset(base + rowBytes * stripeRow, 0xFF, rowBytes * stripeHeight)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        stripeRow += stripeStep
        if stripeRow <= 0 || stripeRow >= rows - stripeHeight {
            stripeStep = -stripeStep
            stripeRow = min(max(stripeRow, 0), rows - stripeHeight)
        }

        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }
        streamSource.stream.send(
            sampleBuffer, discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource.startStreaming() }

    func stopStream() throws { deviceSource.stopStreaming() }

    private var deviceSource: DeviceSource { device.source as! DeviceSource }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "vutusi Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "kawarimidoll"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

import CoreGraphics
@preconcurrency import CoreMediaIO
@preconcurrency import CoreVideo
import CoreText
import Foundation
import IOKit.audio
import os

let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "CameraExtension")

/// Frames from the app arrive on the sink stream and go out unchanged on the source stream.
/// While the app sends nothing, the source shows a static "waiting" frame.
///
/// The sink is drained only while a video app runs the source. The app reads a full sink
/// queue as "nobody is watching" (see VirtualCameraBridge).
/// @unchecked: every mutable member is touched only on `queue`.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CMIOExtensionStream!
    private var sinkStream: CMIOExtensionStream!
    // CMIOExtensionStream holds its source weakly; without these the streams report no formats
    // and AVFoundation hides the device.
    private var streamSources: [StreamSource] = []
    private let queue = DispatchQueue(label: "com.kawarimidoll.vutusi.CameraExtension.frames", qos: .userInteractive)

    private var formatDescription: CMFormatDescription!
    private var waitingFrame: CVPixelBuffer!

    private var sourceClients = 0
    private var sourceTimer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var sinkTimer: DispatchSourceTimer?
    private var lastSinkFrameTime: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName, deviceID: CameraIdentifiers.deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: CameraIdentifiers.width, height: CameraIdentifiers.height, extensions: nil,
            formatDescriptionOut: &formatDescription)
        waitingFrame = makeWaitingFrame()

        let frameDuration = CMTime(value: 1, timescale: CameraIdentifiers.frameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil)
        let source = StreamSource(device: self, format: format, isSink: false)
        let sink = StreamSource(device: self, format: format, isSink: true)
        streamSources = [source, sink]
        sourceStream = CMIOExtensionStream(
            localizedName: CameraIdentifiers.sourceStreamName, streamID: CameraIdentifiers.sourceStreamID,
            direction: .source, clockType: .hostTime, source: source)
        sinkStream = CMIOExtensionStream(
            localizedName: CameraIdentifiers.sinkStreamName, streamID: CameraIdentifiers.sinkStreamID,
            direction: .sink, clockType: .hostTime, source: sink)
        do {
            try device.addStream(sourceStream)
            try device.addStream(sinkStream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = CameraIdentifiers.deviceName
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source (to video apps)

    func startSource() {
        queue.async { [self] in
            sourceClients += 1
            guard sourceTimer == nil else { return }
            logger.info("source stream started")
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(CameraIdentifiers.frameRate), leeway: .nanoseconds(0))
            timer.setEventHandler { [self] in sendWaitingFrameIfIdle() }
            timer.resume()
            sourceTimer = timer
        }
    }

    func stopSource() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            guard sourceClients == 0 else { return }
            logger.info("source stream stopped")
            sourceTimer?.cancel()
            sourceTimer = nil
        }
    }

    private func sendWaitingFrameIfIdle() {
        let now = hostTimeNanoseconds()
        guard now - lastSinkFrameTime > 500_000_000 else { return }
        send(waitingFrame, at: now)
    }

    private func send(_ pixelBuffer: CVPixelBuffer, at hostTime: UInt64) {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CameraIdentifiers.frameRate),
            presentationTimeStamp: CMTime(value: CMTimeValue(hostTime), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }
        sourceStream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }

    // MARK: Sink (from the app)

    func startSink(client: CMIOExtensionClient) {
        queue.async { [self] in
            sinkClient = client
            guard sinkTimer == nil else { return }
            logger.info("sink stream started")
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(CameraIdentifiers.frameRate), leeway: .nanoseconds(0))
            timer.setEventHandler { [self] in consumeSinkFrame() }
            timer.resume()
            sinkTimer = timer
        }
    }

    func stopSink() {
        queue.async { [self] in
            logger.info("sink stream stopped")
            sinkTimer?.cancel()
            sinkTimer = nil
            sinkClient = nil
        }
    }

    private func consumeSinkFrame() {
        guard let sinkClient, sourceClients > 0 else { return }
        sinkStream.consumeSampleBuffer(from: sinkClient) { [self] sampleBuffer, sequenceNumber, _, _, error in
            guard let sampleBuffer, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                if let error { logger.debug("sink: \(error.localizedDescription, privacy: .public)") }
                return
            }
            let now = hostTimeNanoseconds()
            // Handed to `queue` and only read there.
            nonisolated(unsafe) let frame = imageBuffer
            queue.async { [self] in
                lastSinkFrameTime = now
                if sourceClients > 0 { send(frame, at: now) }
            }
            sinkStream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now))
        }
    }

    private func makeWaitingFrame() -> CVPixelBuffer {
        let width = Int(CameraIdentifiers.width), height = Int(CameraIdentifiers.height)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary] as NSDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: "vutusi: waiting for the app", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.7, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, context)
        return buffer
    }
}

private func hostTimeNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private unowned let device: DeviceSource
    private let format: CMIOExtensionStreamFormat
    private let isSink: Bool

    init(device: DeviceSource, format: CMIOExtensionStreamFormat, isSink: Bool) {
        self.device = device
        self.format = format
        self.isSink = isSink
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if isSink {
            properties.formUnion([
                .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
            ])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CameraIdentifiers.frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// The sink has to name the client it consumes from, and only this callback reveals it.
    private var sinkClient: CMIOExtensionClient?

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if isSink { sinkClient = client }
        return true
    }

    func startStream() throws {
        if !isSink {
            device.startSource()
        } else if let sinkClient {
            device.startSink(client: sinkClient)
        }
    }

    func stopStream() throws {
        if isSink { device.stopSink() } else { device.stopSource() }
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: CameraIdentifiers.deviceName)
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

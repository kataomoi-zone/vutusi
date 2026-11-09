import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import RealityKit
import VRMRealityKit
import os

private let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "AvatarRenderer")

/// How much of the model the camera shows.
struct Framing: Equatable {
    /// 1 shows from the top of the model down to the hips; 0.5 about the full body for
    /// grown-up proportions, higher values close in on the face.
    var zoom: Float = 1
    /// Moves the model up (positive) or down in the frame, in frame heights.
    var offset: Float = 0
}

/// Draws the avatar offscreen into IOSurface-backed BGRA pixel buffers, the format the
/// Camera Extension streams, at a fixed rate while running.
@MainActor
final class AvatarRenderer {
    private let device = MTLCreateSystemDefaultDevice()!
    private let renderer: RealityRenderer
    private let camera = Entity()
    private var pool: CVPixelBufferPool!
    private var model: VRMEntity?
    private var applier: TrackingApplier?
    /// 0 (none) to 1; see TrackingApplier.smoothing.
    var smoothing: Float = 0.5 {
        didSet { applier?.smoothing = smoothing }
    }
    private var stats = TrackingStats()
    /// The newest tracking result not yet rendered: when it arrived, and the page's latency.
    private var unrenderedResult: (arrived: ContinuousClock.Instant, pageMs: Double)?
    private var timer: Timer?
    private var frameInFlight = false
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let commandQueue: MTLCommandQueue
    /// The background image scaled to the frame, copied into each frame before the model.
    private var backgroundTexture: MTLTexture?

    var framing = Framing() {
        didSet { if let model { frame(model) } }
    }

    private let width = Int(CameraIdentifiers.width)
    private let height = Int(CameraIdentifiers.height)

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        self.onFrame = onFrame
        commandQueue = device.makeCommandQueue()!
        renderer = try RealityRenderer()
        // Colors as they are: MToon is drawn for the camera image, not a photographic scene.
        renderer.cameraSettings.isToneMappingEnabled = false

        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        camera.components.set(cameraComponent)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
    }

    func load(_ url: URL) async throws {
        let data = try bakeEmissiveStrength(Data(contentsOf: url))
        let model = try await VRMEntityLoader(
            withData: data, rootDirectory: url.deletingLastPathComponent(),
            outputColorSpace: .sRGB, compensatesToneMapping: false
        ).loadEntity()
        model.isAutomaticUpdateEnabled = false
        model.setMToonLightDirection(normalize(-model.frontDirection + SIMD3<Float>(0.3, -0.5, 0)))
        model.update(deltaTime: 0)

        if let old = self.model { renderer.entities.remove(old) }
        renderer.entities.append(model)
        self.model = model
        applier = TrackingApplier(model: model)
        applier?.smoothing = smoothing
        frame(model)
        logger.info("loaded \(url.lastPathComponent, privacy: .public)")
    }

    /// Poses the model from a tracking result; the next rendered frame shows it.
    func apply(_ result: HolisticResult, faceMetrics: [String: Float], jsLatencyMs: Double) {
        applier?.update(result, faceMetrics: faceMetrics)
        unrenderedResult = (.now, jsLatencyMs)
        stats.record(result, faceMetrics: faceMetrics)
    }

    func setRunning(_ running: Bool) {
        guard running != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let interval = 1.0 / Double(CameraIdentifiers.frameRate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame(deltaTime: interval) }
        }
        // Common modes, so frames keep flowing while the menu bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A solid background, as sRGB components.
    func setBackground(red: Float, green: Float, blue: Float) {
        backgroundTexture = nil
        renderer.cameraSettings.colorBackground = .color(Self.background(red: red, green: green, blue: blue))
    }

    /// An image background, scaled to fill the frame and cropped.
    func setBackgroundImage(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
            width: size.width, height: size.height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        backgroundTexture = texture
        // Draw over what the target already holds: the image, copied in each frame.
        renderer.cameraSettings.colorBackground = .outputTexture()
    }

    /// Keeps the top of the model near the top of the frame and scales from the
    /// top-to-hips span. The top comes from the model's bounds, not the head bone, which
    /// sits at the bottom of the head and misses large (chibi) heads.
    private func frame(_ model: VRMEntity) {
        let head = model.humanoid.node(for: .head)?.position(relativeTo: nil) ?? SIMD3<Float>(0, 1.4, 0)
        let hips = model.humanoid.node(for: .hips)?.position(relativeTo: nil) ?? SIMD3<Float>(0, 0.9, 0)
        let top = max(model.visualBounds(relativeTo: nil).max.y, head.y)
        let visibleHeight = max(top - hips.y, 0.1) * 1.2 / max(framing.zoom, 0.1)
        // 5% margin above the top, then the user's offset.
        let target = SIMD3<Float>(
            head.x, top - visibleHeight * 0.45 - framing.offset * visibleHeight, head.z)
        let distance = visibleHeight / 2 / tan(15 * .pi / 180)
        camera.look(at: target, from: target + model.frontDirection * distance, relativeTo: nil)
    }

    private func renderFrame(deltaTime: TimeInterval) {
        guard !frameInFlight else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return }
        if let backgroundTexture, let commands = commandQueue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: backgroundTexture, to: texture)
            blit.endEncoding()
            commands.commit()
            // RealityKit renders on its own queue; a 1280x720 copy is well under a millisecond.
            commands.waitUntilCompleted()
        }

        model?.update(deltaTime: deltaTime)
        frameInFlight = true
        let result = unrenderedResult
        unrenderedResult = nil
        // Handed to the completion handler and not touched here afterwards.
        nonisolated(unsafe) let frame = pixelBuffer
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            try renderer.updateAndRender(deltaTime: deltaTime, cameraOutput: output, onComplete: { [onFrame, weak self] _ in
                onFrame(frame)
                Task { @MainActor in
                    self?.frameInFlight = false
                    if let result { self?.stats.recordLatency(pageMs: result.pageMs, app: .now - result.arrived) }
                }
            })
        } catch {
            frameInFlight = false
            logger.error("render failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// RealityKit writes the background as linear values into the BGRA (non-sRGB) target,
    /// which video apps read as sRGB, so the color is sRGB-encoded once more to come out as given.
    private static func background(red: Float, green: Float, blue: Float) -> CGColor {
        func encode(_ c: Float) -> CGFloat {
            CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        // Tagged Display P3 so RealityKit keeps the numbers (see GLTFOutputColorSpace.sRGB).
        return CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            components: [encode(red), encode(green), encode(blue), 1])!
    }
}

/// Tracking rate, detection rates and latency, logged every few seconds (plan Phase 3).
/// Latency is measured in two parts on their own clocks and added up: the page's
/// (camera frame to result) and the app's (result received to the frame showing it
/// handed to the sink). Results replaced before a frame showed them are not counted.
private struct TrackingStats {
    private var start = ContinuousClock.now
    private var results = 0
    private var face = 0, pose = 0, left = 0, right = 0
    private var totalsMs: [Double] = []
    private var faceMetrics: [String: [Float]] = [:]

    mutating func record(_ result: HolisticResult, faceMetrics metrics: [String: Float]) {
        for (name, value) in metrics { faceMetrics[name, default: []].append(value) }
        results += 1
        if result.face != nil { face += 1 }
        if result.pose != nil { pose += 1 }
        if result.leftHand != nil { left += 1 }
        if result.rightHand != nil { right += 1 }
        flushIfDue()
    }

    mutating func recordLatency(pageMs: Double, app: Duration) {
        totalsMs.append(pageMs + Double(app.components.seconds) * 1000 + Double(app.components.attoseconds) / 1e15)
    }

    private mutating func flushIfDue() {
        let elapsed = ContinuousClock.now - start
        guard elapsed >= .seconds(5) else { return }
        let rate = String(format: "%.1f", Double(results) / Double(elapsed.components.seconds))
        let detected = [face, pose, left, right].map { $0 * 100 / results }
        let sorted = totalsMs.sorted()
        let median = sorted.isEmpty ? 0 : Int(sorted[sorted.count / 2])
        let p95 = sorted.isEmpty ? 0 : Int(sorted[sorted.count * 95 / 100])
        // min / median / max of each face metric, to set TrackingApplier's ranges from.
        let metrics = faceMetrics.keys.sorted().map { name in
            let v = faceMetrics[name]!.sorted()
            return String(format: "%@ %.2f/%.2f/%.2f", name, v.first!, v[v.count / 2], v.last!)
        }.joined(separator: ", ")
        logger.info("""
            tracking \(rate, privacy: .public)/s, detected face \(detected[0])% pose \(detected[1])% \
            left \(detected[2])% right \(detected[3])%, latency median \(median) ms p95 \(p95) ms; \
            \(metrics, privacy: .public)
            """)
        self = TrackingStats()
    }
}

/// VRMKit ignores KHR_materials_emissive_strength, so a material exported as
/// emissiveFactor [1,1,1] with strength 0 (VRM Add-on for Blender) renders solid white.
/// Multiplies the strength into emissiveFactor in the GLB's JSON chunk.
/// Drop this once VRMKit applies the extension itself.
func bakeEmissiveStrength(_ glb: Data) throws -> Data {
    func u32(_ offset: Int) -> Int {
        Int(glb.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
    // GLB: 12-byte header, then the JSON chunk (length, type, payload), then the rest.
    guard glb.count > 20 else { return glb }
    let jsonRange = 20..<20 + u32(12)
    guard var json = try JSONSerialization.jsonObject(with: glb.subdata(in: jsonRange)) as? [String: Any],
          var materials = json["materials"] as? [[String: Any]] else { return glb }
    var changed = false
    for i in materials.indices {
        guard let factor = materials[i]["emissiveFactor"] as? [Double],
              let ext = materials[i]["extensions"] as? [String: Any],
              let strength = (ext["KHR_materials_emissive_strength"] as? [String: Any])?["emissiveStrength"] as? Double
        else { continue }
        materials[i]["emissiveFactor"] = factor.map { $0 * strength }
        changed = true
    }
    guard changed else { return glb }
    json["materials"] = materials
    var newJSON = try JSONSerialization.data(withJSONObject: json)
    newJSON.append(contentsOf: [UInt8](repeating: 0x20, count: (4 - newJSON.count % 4) % 4))

    func le(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    let rest = glb.subdata(in: jsonRange.upperBound..<glb.count)
    var out = glb.subdata(in: 0..<8)  // magic + version
    out += le(12 + 8 + newJSON.count + rest.count)
    out += le(newJSON.count) + glb.subdata(in: 16..<20) + newJSON + rest
    return out
}

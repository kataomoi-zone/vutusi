// Spike A: render a VRM with VRMRealityKit into an IOSurface-backed CVPixelBuffer
// without any window, save PNGs, and time 30fps-style frames.
//
// Usage: swift run offscreen <model.vrm> <out-dir> [label] [camera distance in m]

import CoreImage
import CoreVideo
import Foundation
import Metal
import RealityKit
import VRMRealityKit

let width = 1280
let height = 720

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: offscreen <model.vrm> <out-dir> [label]")
        exit(2)
    }
    let modelURL = URL(fileURLWithPath: args[1])
    let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
    let label = args.count >= 4 ? args[3] : modelURL.deletingPathExtension().lastPathComponent
    let distance = args.count >= 5 ? Float(args[4])! : 1.0
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let device = MTLCreateSystemDefaultDevice()!
    let (pixelBuffer, texture) = makeTarget(device: device)

    for toneMapping in [true, false] {
        let loadStart = Date()
        let model = try await VRMEntityLoader(
            withURL: modelURL, outputColorSpace: .sRGB, compensatesToneMapping: toneMapping
        ).loadEntity()
        print("[\(label)] load: \(ms(since: loadStart)) ms, front: \(model.frontDirection)")
        model.isAutomaticUpdateEnabled = false
        model.setMToonLightDirection(normalize(-model.frontDirection + SIMD3<Float>(0.3, -0.5, 0)))

        let renderer = try RealityRenderer()
        renderer.entities.append(model)
        renderer.cameraSettings.isToneMappingEnabled = toneMapping
        // Tagged Display P3 so RealityKit keeps the sRGB numbers as they are (see GLTFOutputColorSpace.sRGB).
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        renderer.cameraSettings.colorBackground = .color(CGColor(colorSpace: p3, components: [0.2, 0.6, 0.4, 1])!)

        // Bust-up framing: look at the head from the side the model faces.
        model.update(deltaTime: 0)
        let head = model.humanoid.node(for: .head)?.position(relativeTo: nil) ?? SIMD3<Float>(0, 1.4, 0)
        let target = head - SIMD3<Float>(0, 0.08, 0)
        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        let camera = Entity()
        camera.components.set(cameraComponent)
        print("[\(label)] head: \(head)")
        camera.look(at: target, from: target + model.frontDirection * distance, relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        var frameTimes: [Double] = []
        let frameCount = 150
        for frame in 0..<frameCount {
            let start = Date()
            model.update(deltaTime: 1.0 / 30)
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                do {
                    try renderer.updateAndRender(
                        deltaTime: 1.0 / 30, cameraOutput: output, onComplete: { _ in done.resume() })
                } catch {
                    done.resume(throwing: error)
                }
            }
            if frame >= 30 { frameTimes.append(ms(since: start)) }  // skip warm-up
        }
        frameTimes.sort()
        let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let p95 = frameTimes[Int(Double(frameTimes.count) * 0.95)]
        print(String(format: "[%@ tonemap=%@] frame: avg %.2f ms, p95 %.2f ms, max %.2f ms",
                     label, "\(toneMapping)", avg, p95, frameTimes.last!))

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let px = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        print("[\(label)] background BGRA at (0,0): \(px[0]) \(px[1]) \(px[2]) \(px[3]) (expected sRGB RGB 51 153 102)")
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        let png = outDir.appendingPathComponent("\(label)-tonemap-\(toneMapping).png")
        try writePNG(pixelBuffer, to: png)
        print("wrote \(png.path)")
    }
}

/// The same shape the Camera Extension sends: BGRA, IOSurface-backed, no CPU copy.
func makeTarget(device: MTLDevice) -> (CVPixelBuffer, MTLTexture) {
    var pixelBuffer: CVPixelBuffer?
    let attributes: NSDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
    let surface = CVPixelBufferGetIOSurface(pixelBuffer!)!.takeUnretainedValue()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)!
    return (pixelBuffer!, texture)
}

func writePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    try CIContext().writePNGRepresentation(
        of: image, to: url, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

func ms(since start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

try await run()

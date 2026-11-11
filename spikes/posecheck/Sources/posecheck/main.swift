// Known-pose check: feed fixed solver outputs through the app's
// TrackingApplier and render each, so the bone mapping can be checked by eye on
// VRM 0.x and 1.0 models.
//
// Usage: posecheck <out-dir> <model.vrm>...

import CoreImage
import Foundation
import Metal
import RealityKit
import VRMRealityKit

let poses: [(name: String, json: String)] = [
    // Avatar turns its head to its own left (viewer's right), arms down.
    ("head-yaw-left-30", #"{"face":{"head":{"pitch":0,"yaw":0.5236,"roll":0},"eyes":{"leftBlink":0,"rightBlink":0,"gazeX":0,"gazeY":0},"mouth":{"open":0,"smile":0}}}"#),
    // Head tilts back (chin up) and rolls toward the avatar's left shoulder.
    ("head-pitch-up-roll-left", #"{"face":{"head":{"pitch":0.35,"yaw":0,"roll":0.35},"eyes":{"leftBlink":0,"rightBlink":0,"gazeX":0,"gazeY":0},"mouth":{"open":0,"smile":0}}}"#),
    // Right arm straight out sideways (T-pose), left arm down.
    ("right-arm-out", #"{"pose":{"spine":{"pitch":0,"yaw":0,"roll":0},"rightArm":{"shoulder":{"x":0,"y":0,"z":0},"elbow":{"x":0,"y":0,"z":0}}}}"#),
    // Right upper arm out, forearm bent 90° forward (toward the camera).
    ("right-elbow-forward", #"{"pose":{"spine":{"pitch":0,"yaw":0,"roll":0},"rightArm":{"shoulder":{"x":0,"y":0,"z":0},"elbow":{"x":0,"y":1.5708,"z":0}}}}"#),
    // Both arms out, left hand a fist, right hand open.
    ("left-fist", #"{"pose":{"spine":{"pitch":0,"yaw":0,"roll":0},"leftArm":{"shoulder":{"x":0,"y":0,"z":0},"elbow":{"x":0,"y":0,"z":0}},"rightArm":{"shoulder":{"x":0,"y":0,"z":0},"elbow":{"x":0,"y":0,"z":0}}},"leftHand":{"thumb":{"curl":1,"spread":0},"index":{"curl":1,"spread":0},"middle":{"curl":1,"spread":0},"ring":{"curl":1,"spread":0},"pinky":{"curl":1,"spread":0}},"rightHand":{"thumb":{"curl":0,"spread":0},"index":{"curl":0,"spread":0},"middle":{"curl":0,"spread":0},"ring":{"curl":0,"spread":0},"pinky":{"curl":0,"spread":0}}}"#),
    // Avatar's left eye closed, mouth open, gaze toward the avatar's left.
    ("blink-left-mouth-open", #"{"face":{"head":{"pitch":0,"yaw":0,"roll":0},"eyes":{"leftBlink":1,"rightBlink":0,"gazeX":1,"gazeY":0},"mouth":{"open":1,"smile":0}}}"#),
    // Spine turned toward the avatar's left.
    ("spine-yaw-left", #"{"pose":{"spine":{"pitch":0,"yaw":0.5,"roll":0}}}"#),
]

let width = 640, height = 360

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let device = MTLCreateSystemDefaultDevice()!
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared

    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let label = url.deletingPathExtension().lastPathComponent
        for (name, json) in poses {
            let model = try await VRMEntityLoader(withURL: url, outputColorSpace: .sRGB, compensatesToneMapping: false).loadEntity()
            model.isAutomaticUpdateEnabled = false
            model.update(deltaTime: 0)
            let applier = TrackingApplier(model: model)
            applier.smoothing = 0
            let result = try JSONDecoder().decode(HolisticResult.self, from: Data(json.utf8))
            applier.update(result)
            model.update(deltaTime: 1.0 / 30)

            let renderer = try RealityRenderer()
            renderer.cameraSettings.isToneMappingEnabled = false
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.3, alpha: 1))
            renderer.entities.append(model)
            var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 40)
            cameraComponent.fieldOfViewOrientation = .vertical
            let camera = Entity()
            camera.components.set(cameraComponent)
            let hips = model.humanoid.node(for: .hips)?.position(relativeTo: nil) ?? [0, 0.9, 0]
            let top = model.visualBounds(relativeTo: nil).max.y
            let target = SIMD3<Float>(0, (top + hips.y) / 2, 0)
            let distance = (top - hips.y) * 1.6 / 2 / tan(20 * .pi / 180)
            camera.look(at: target, from: target + model.frontDirection * distance, relativeTo: nil)
            renderer.entities.append(camera)
            renderer.activeCamera = camera

            let texture = device.makeTexture(descriptor: descriptor)!
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0 / 30, cameraOutput: output, onComplete: { _ in done.resume() })
                } catch {
                    done.resume(throwing: error)
                }
            }
            let image = CIImage(mtlTexture: texture)!.oriented(.downMirrored)
            let png = outDir.appendingPathComponent("\(label)-\(name).png")
            try CIContext().writePNGRepresentation(
                of: image, to: png, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            print("wrote \(png.lastPathComponent)")
        }
    }
}

try await run()

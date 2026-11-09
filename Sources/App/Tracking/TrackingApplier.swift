// Port of animovi's TrackingBridge (src/lib/vrm/tracking-bridge.ts) from three-vrm
// to VRMKit. Copyright (c) motoki317, MIT License; see web/animovi/LICENSE.

import Foundation
import VRMRealityKit
import simd

/// Poses a VRM from the tracking worker's solver output, smoothing every value.
///
/// The solvers speak in rotations of three-vrm's normalized bones: identity at rest,
/// in the VRM 0.x frame. VRMKit poses the raw nodes in the file's own frame, so each
/// rotation `n` is first turned into the file's frame (VRM 1.0 faces the other way),
/// then re-expressed against the node's rest as `parentRest⁻¹ · n · rest`, as three-vrm
/// and VRMKit's own VRMA retargeting do.
@MainActor
final class TrackingApplier {
    /// 0 (none) to 1. Filter responsiveness is 1 - smoothing, at least 0.1.
    var smoothing: Float = 0.5

    private let model: VRMEntity
    private let facesNegativeZ: Bool
    private var rest: [HumanoidBone: (node: Int, world: simd_quatf, parentWorld: simd_quatf)] = [:]
    private var filters: [String: Float] = [:]
    private var faceActive = false
    private var poseActive = false
    private var handActive = (left: false, right: false)

    // Eye and mouth values ignore the smoothing setting, so they stay responsive.
    private static let fastKeys: Set<String> = ["gazeX", "gazeY", "blinkLeft", "blinkRight", "aa", "oh", "ou", "happy"]
    private static let fastResponsiveness: Float = 0.9
    private static let minResponsiveness: Float = 0.1
    /// Upper-arm roll for the arms-down pose, 72° below horizontal.
    private static let armsDownRoll: Float = .pi / 2.5

    init(model: VRMEntity) {
        self.model = model
        facesNegativeZ = model.frontDirection.z < 0
        guard let pose = model.pose else { return }
        for bone in HumanoidBone.allCases {
            guard let node = model.humanoid.nodeIndex(for: bone) else { continue }
            let parentWorld = pose.parent(ofNode: node).map { pose.worldRotation(ofNode: $0) } ?? pose.rootRotation
            rest[bone] = (node, pose.worldRotation(ofNode: node), parentWorld)
        }
    }

    /// `faceMetrics` are the worker's face ratios by name, empty without a face.
    func update(_ result: HolisticResult, faceMetrics: [String: Float] = [:]) {
        if let face = result.face {
            faceActive = true
            applyFace(face, metrics: faceMetrics)
        } else if faceActive {
            faceActive = false
            resetFilters(prefixes: ["head", "gaze"])
        }

        if let pose = result.pose {
            poseActive = true
            applyPose(pose)
        } else {
            if poseActive {
                poseActive = false
                resetFilters(prefixes: ["spine"])
            }
            // The arm filters stay, so a dropped frame eases the arms down instead of snapping.
            applyDefaultArms(left: true, right: true)
        }

        for (side, hand, arm) in [
            (Side.left, result.leftHand, result.pose?.leftArm),
            (Side.right, result.rightHand, result.pose?.rightArm),
        ] {
            if let hand {
                setHandActive(side, true)
                applyFingers(side, hand)
                if let frame = hand.wristFrame, let arm { applyWrist(side, frame, arm) }
            } else if handActive(side) {
                setHandActive(side, false)
                resetFilters(prefixes: ["\(side.rawValue)Hand", "\(side.rawValue)Finger"])
            }
        }
    }

    // MARK: Face

    private func applyFace(_ face: FaceResult, metrics: [String: Float]) {
        setBone(.head, smooth("head", face.head.euler))
        // Gaze in [-1, 1] turns the eyes at most 30°; +x is toward the avatar's left, +y up.
        let yaw = smooth("gazeX", face.eyes.gazeX) * 30
        let pitch = smooth("gazeY", face.eyes.gazeY) * 30
        model.lookAtTarget = .angles(yaw: yaw, pitch: pitch)
        var weights: [String: Float] = ["happy": face.mouth.smile]
        if metrics.isEmpty {
            weights["blinkLeft"] = face.eyes.leftBlink
            weights["blinkRight"] = face.eyes.rightBlink
            weights["aa"] = face.mouth.open
        } else {
            weights.merge(Self.expressions(from: metrics)) { $1 }
        }
        model.setExpressions(Dictionary(uniqueKeysWithValues: weights.compactMap { name, value in
            ExpressionPreset(rawValue: name).map { (ExpressionKey.preset($0), CGFloat(smooth(name, value))) }
        }))
    }

    /// Blinks and mouth shapes from the worker's face metrics (web/worker.ts), which,
    /// unlike animovi's image-space distances, hold at any distance to the camera and
    /// tell one eye from the other and a rounded mouth from an open one.
    ///
    /// The ranges come from one user holding each state (z-ai/phase3c.log): eyes read
    /// about 0.35 open and 0.20 closed, since the landmarks never meet. The mouth reads
    /// 0.56 wide at rest and 0.32 to 0.42 rounded.
    /// LIMITATION: fixed ranges for every face; adaptive calibration if they prove personal.
    private static func expressions(from metrics: [String: Float]) -> [String: Float] {
        func scale(_ name: String, from low: Float, to high: Float) -> Float {
            min(max(((metrics[name] ?? 0) - low) / (high - low), 0), 1)
        }
        var blinkLeft = 1 - scale("eyeLeft", from: 0.21, to: 0.30)
        var blinkRight = 1 - scale("eyeRight", from: 0.21, to: 0.30)
        // The face model pulls the open eye half shut along with a winking one (0.26
        // against 0.20), so a clear gap between the eyes is read as a wink outright.
        let gap = (metrics["eyeLeft"] ?? 0) - (metrics["eyeRight"] ?? 0)
        if gap > 0.05 {
            (blinkLeft, blinkRight) = (0, 1)
        } else if gap < -0.05 {
            (blinkLeft, blinkRight) = (1, 0)
        }

        let open = scale("mouthOpen", from: 0.05, to: 0.40)
        let round = 1 - scale("mouthWidth", from: 0.40, to: 0.52)
        return [
            "blinkLeft": blinkLeft,
            "blinkRight": blinkRight,
            "aa": open * (1 - round),
            "oh": open * round,
            "ou": (1 - open) * round,
        ]
    }

    // MARK: Body

    private func applyPose(_ pose: PoseResult) {
        setBone(.spine, smooth("spine", pose.spine.euler))
        if let arm = pose.leftArm {
            setBone(.leftUpperArm, smooth("leftUpperArm", arm.shoulder))
            setBone(.leftLowerArm, smooth("leftLowerArm", arm.elbow))
        } else {
            applyDefaultArms(left: true, right: false)
        }
        if let arm = pose.rightArm {
            setBone(.rightUpperArm, smooth("rightUpperArm", arm.shoulder))
            setBone(.rightLowerArm, smooth("rightLowerArm", arm.elbow))
        } else {
            applyDefaultArms(left: false, right: true)
        }
    }

    private func applyDefaultArms(left: Bool, right: Bool) {
        if left {
            setBone(.leftUpperArm, smooth("leftUpperArm", Euler(x: 0, y: 0, z: Self.armsDownRoll)))
            setBone(.leftLowerArm, smooth("leftLowerArm", Euler(x: 0, y: 0, z: 0)))
        }
        if right {
            setBone(.rightUpperArm, smooth("rightUpperArm", Euler(x: 0, y: 0, z: -Self.armsDownRoll)))
            setBone(.rightLowerArm, smooth("rightLowerArm", Euler(x: 0, y: 0, z: 0)))
        }
    }

    // MARK: Hands

    enum Side: String { case left, right }

    private func handActive(_ side: Side) -> Bool { side == .left ? handActive.left : handActive.right }

    private func setHandActive(_ side: Side, _ active: Bool) {
        if side == .left { handActive.left = active } else { handActive.right = active }
    }

    /// Normalized finger bones extend along X, so curl rotates about Z and spread about Y.
    /// Left fingers extend toward +X in the solver frame and right ones toward -X, hence
    /// the side sign. Curl spreads over three joints so a full curl makes a fist.
    private func applyFingers(_ side: Side, _ hand: HandResult) {
        let sideSign: Float = side == .left ? 1 : -1
        let fingers: [(name: String, value: HandResult.Finger, bones: [HumanoidBone?])] = [
            // animovi's three-vrm names the thumb joints Metacarpal/Proximal/Distal and drives
            // Proximal and Distal; it never reaches the pinky, whose bones are named "Little".
            ("thumb", hand.thumb, side == .left
                ? [.leftThumbProximal, nil, .leftThumbDistal] : [.rightThumbProximal, nil, .rightThumbDistal]),
            ("index", hand.index, side == .left
                ? [.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal]
                : [.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal]),
            ("middle", hand.middle, side == .left
                ? [.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal]
                : [.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal]),
            ("ring", hand.ring, side == .left
                ? [.leftRingProximal, .leftRingIntermediate, .leftRingDistal]
                : [.rightRingProximal, .rightRingIntermediate, .rightRingDistal]),
            ("pinky", hand.pinky, side == .left
                ? [.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal]
                : [.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal]),
        ]
        let joints: [(curl: Float, spread: Float)] = [(0.5, 1), (0.5, 0), (0.4, 0)]
        let key = "\(side.rawValue)Finger"
        for finger in fingers {
            let curl = smooth("\(key)\(finger.name)Curl", finger.value.curl)
            let spread = smooth("\(key)\(finger.name)Spread", finger.value.spread)
            for (bone, joint) in zip(finger.bones, joints) {
                guard let bone else { continue }
                setBone(bone, Euler(
                    x: 0,
                    y: sideSign * spread * (.pi / 6) * joint.spread,
                    z: sideSign * curl * .pi * joint.curl))
            }
        }
    }

    /// Turns the T-pose hand frame onto the detected one, then removes the arm chain:
    /// hand local = (shoulder · elbow)⁻¹ · target.
    private func applyWrist(_ side: Side, _ frame: HandResult.WristFrame, _ arm: PoseResult.Arm) {
        let restAxis = SIMD3<Float>(side == .left ? -1 : 1, 0, 0)
        // Palms down at T-pose. A model resting with palms forward or inward needs another axis.
        let restNormal = SIMD3<Float>(0, -1, 0)
        let target = rotation(from: (restAxis, restNormal), to: (frame.handAxis.simd, frame.palmNormal.simd))
        let chain = quat(arm.shoulder) * quat(arm.elbow)
        let local = euler(chain.inverse * target)
        let bone: HumanoidBone = side == .left ? .leftHand : .rightHand
        setBone(bone, smooth("\(side.rawValue)Hand", local))
    }

    // MARK: Writing

    /// Writes a solver-frame normalized rotation onto the bone's node.
    private func setBone(_ bone: HumanoidBone, _ angles: Euler) {
        guard let rest = rest[bone], let pose = model.pose else { return }
        var normalized = quat(angles)
        if !facesNegativeZ {
            // VRM 1.0 faces +Z: the same rotation seen after a half turn about Y.
            normalized = simd_quatf(ix: -normalized.imag.x, iy: normalized.imag.y, iz: -normalized.imag.z, r: normalized.real)
        }
        pose.setLocalRotation(rest.parentWorld.inverse * normalized * rest.world, ofNode: rest.node)
    }

    // MARK: Smoothing

    private func smooth(_ key: String, _ value: Float) -> Float {
        guard let estimate = filters[key] else {
            filters[key] = value
            return value
        }
        let responsiveness = Self.fastKeys.contains(key)
            ? Self.fastResponsiveness
            : max(Self.minResponsiveness, 1 - smoothing)
        let next = estimate + responsiveness * (value - estimate)
        filters[key] = next
        return next
    }

    private func smooth(_ key: String, _ angles: Euler) -> Euler {
        Euler(x: smooth("\(key)_x", angles.x), y: smooth("\(key)_y", angles.y), z: smooth("\(key)_z", angles.z))
    }

    private func resetFilters(prefixes: [String]) {
        filters = filters.filter { key, _ in !prefixes.contains { key.hasPrefix($0) } }
    }
}

// MARK: - Rotation math (animovi src/lib/math/quaternion.ts)

/// ZYX Euler angles (three.js order 'ZYX': x applies first) to a quaternion.
func quat(_ e: Euler) -> simd_quatf {
    simd_quatf(angle: e.z, axis: [0, 0, 1]) * simd_quatf(angle: e.y, axis: [0, 1, 0]) * simd_quatf(angle: e.x, axis: [1, 0, 0])
}

/// A unit quaternion to ZYX Euler angles.
func euler(_ q: simd_quatf) -> Euler {
    let (x, y, z, w) = (q.imag.x, q.imag.y, q.imag.z, q.real)
    let sinY = 2 * (w * y - x * z)
    if abs(sinY) >= 0.9999999 {
        return Euler(x: 0, y: (.pi / 2) * (sinY < 0 ? -1 : 1), z: atan2(-(2 * (x * y - w * z)), 1 - 2 * (x * x + z * z)))
    }
    return Euler(
        x: atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)),
        y: asin(sinY),
        z: atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
}

/// The rotation taking the orthonormal pair `from` onto `to` (same handedness).
func rotation(from: (SIMD3<Float>, SIMD3<Float>), to: (SIMD3<Float>, SIMD3<Float>)) -> simd_quatf {
    let local = simd_float3x3(from.0, from.1, cross(from.0, from.1))
    let world = simd_float3x3(to.0, to.1, cross(to.0, to.1))
    return simd_quatf(world * local.transpose)
}

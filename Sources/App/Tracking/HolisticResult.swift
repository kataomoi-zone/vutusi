// The tracking worker's output (web/worker.ts), decoded from JSON.
// Shapes follow animovi's solvers (web/animovi/solver/*.ts): angles are radians in
// "solver space", the native frame of a VRM 0.x avatar (Y up, facing -Z, left arm
// along -X), as ZYX Euler angles (x applies first).

struct HolisticResult: Decodable, Sendable {
    var face: FaceResult?
    var pose: PoseResult?
    var leftHand: HandResult?
    var rightHand: HandResult?
}

struct Euler: Decodable, Sendable {
    var x: Float
    var y: Float
    var z: Float
}

struct PitchYawRoll: Decodable, Sendable {
    var pitch: Float
    var yaw: Float
    var roll: Float

    var euler: Euler { Euler(x: pitch, y: yaw, z: roll) }
}

struct FaceResult: Decodable, Sendable {
    struct Eyes: Decodable, Sendable {
        var leftBlink: Float
        var rightBlink: Float
        var gazeX: Float
        var gazeY: Float
    }
    struct Mouth: Decodable, Sendable {
        var open: Float
        var smile: Float
    }
    var head: PitchYawRoll
    var eyes: Eyes
    var mouth: Mouth
}

struct PoseResult: Decodable, Sendable {
    struct Arm: Decodable, Sendable {
        var shoulder: Euler
        var elbow: Euler
    }
    var spine: PitchYawRoll
    var leftArm: Arm?
    var rightArm: Arm?
}

struct HandResult: Decodable, Sendable {
    struct Finger: Decodable, Sendable {
        var curl: Float
        var spread: Float
    }
    struct Vector: Decodable, Sendable {
        var x: Float
        var y: Float
        var z: Float

        var simd: SIMD3<Float> { SIMD3(x, y, z) }
    }
    struct WristFrame: Decodable, Sendable {
        var handAxis: Vector
        var palmNormal: Vector
    }
    var thumb: Finger
    var index: Finger
    var middle: Finger
    var ring: Finger
    var pinky: Finger
    var wristFrame: WristFrame?
}

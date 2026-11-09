import { solveArmDirect, clampArmRotation } from '../math/arm-solver'
import type { Vector3 } from '../math/vector'

export interface PoseLandmark {
  x: number
  y: number
  z: number
  visibility?: number
}

export type PoseLandmarks = PoseLandmark[]

export interface ArmResult {
  shoulder: { x: number; y: number; z: number }
  elbow: { x: number; y: number; z: number }
}

export interface PoseResult {
  /** Solver-space bone rotation in radians: pitch about X, yaw about Y, roll about Z, with ZYX order. See toSolverSpace. */
  spine: {
    pitch: number
    yaw: number
    roll: number
  }
  leftArm: ArmResult | null
  rightArm: ArmResult | null
}

const LEFT_SHOULDER = 11
const RIGHT_SHOULDER = 12
const LEFT_ELBOW = 13
const RIGHT_ELBOW = 14
const LEFT_WRIST = 15
const RIGHT_WRIST = 16
const VISIBILITY_THRESHOLD = 0.5

// The shoulder landmarks also shift when the head turns or a hand rises. No
// shoulder-only formula separates that from a real torso turn, so the gain
// scales wanted and unwanted response alike. 0.5 was calibrated on real
// footage and trades torso-turn response for less head coupling and jitter.
export const SPINE_YAW_GAIN = 0.5
// Caps |spine yaw| at π/4, the output for a 90° (profile) turn. Past profile,
// the shoulder-line angle heads for its atan2 wrap at 180°. A seated VTuber
// stays well inside this range.
export const SPINE_YAW_CLAMP = Math.PI / 4

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v))

/**
 * Maps a normalized MediaPipe landmark into solver space: the native frame of
 * a VRM 0.x avatar. Y is up, the avatar faces -Z, and its left arm rests along -X.
 *
 * In real footage the left shoulder (11) has the larger x, so x flips about the
 * image center. y flips because MediaPipe y grows downward. z keeps its sign,
 * because MediaPipe z decreases toward the camera, which is the avatar's front.
 *
 * TrackingBridge.boneSign explains how both VRM versions carry solver space
 * into three.js world space.
 */
export function toSolverSpace(p: Vector3): Vector3 {
  return {
    x: -(p.x - 0.5),
    y: -p.y,
    z: p.z,
  }
}

function solveArm(
  shoulder: PoseLandmark,
  elbow: PoseLandmark,
  wrist: PoseLandmark,
  isLeft: boolean
): ArmResult | null {
  if (
    (elbow.visibility ?? 0) < VISIBILITY_THRESHOLD ||
    (wrist.visibility ?? 0) < VISIBILITY_THRESHOLD
  ) {
    return null
  }

  const shoulderVRM = toSolverSpace(shoulder)
  const elbowVRM = toSolverSpace(elbow)
  const wristVRM = toSolverSpace(wrist)

  const result = clampArmRotation(solveArmDirect({
    shoulder: shoulderVRM,
    elbow: elbowVRM,
    wrist: wristVRM,
    isLeft,
  }))

  return {
    shoulder: result.shoulder,
    elbow: result.elbow,
  }
}

export function solvePose(
  landmarks: PoseLandmarks,
  // MediaPipe poseWorldLandmarks, in meters. Only spine yaw uses them, because
  // normalized z was too unreliable for it. Arms and roll use `landmarks`.
  worldLandmarks?: PoseLandmarks,
): PoseResult | null {
  if (landmarks.length === 0) {
    return null
  }

  const leftShoulder = landmarks[LEFT_SHOULDER]
  const rightShoulder = landmarks[RIGHT_SHOULDER]
  const leftElbow = landmarks[LEFT_ELBOW]
  const rightElbow = landmarks[RIGHT_ELBOW]
  const leftWrist = landmarks[LEFT_WRIST]
  const rightWrist = landmarks[RIGHT_WRIST]

  if (
    (leftShoulder.visibility ?? 0) < VISIBILITY_THRESHOLD ||
    (rightShoulder.visibility ?? 0) < VISIBILITY_THRESHOLD
  ) {
    return null
  }

  // Positive bone yaw turns the avatar to its left, so a turn to the subject's
  // right needs negative yaw. That turn moves the right shoulder away from
  // the camera (larger z). When the subject faces the camera, the vector from
  // their left shoulder to their right shoulder points along MediaPipe world -X.
  // atan2(Δz, -Δx) then reads 0, far from its ±180° branch cut.
  // Shoulder spacing does not affect the angle.
  const lShoulderW = worldLandmarks?.[LEFT_SHOULDER]
  const rShoulderW = worldLandmarks?.[RIGHT_SHOULDER]
  let spineYaw: number
  if (lShoulderW && rShoulderW) {
    const dz = rShoulderW.z - lShoulderW.z
    const dx = rShoulderW.x - lShoulderW.x
    spineYaw = clamp(-Math.atan2(dz, -dx) * SPINE_YAW_GAIN, -SPINE_YAW_CLAMP, SPINE_YAW_CLAMP)
  } else {
    // Callers without world landmarks (tests and fixtures) use normalized z.
    spineYaw = (leftShoulder.z - rightShoulder.z) * 3
  }

  // A lean to the subject's right lowers the right shoulder in the image
  // (larger y) and needs negative bone roll in solver space.
  const spineRoll = (leftShoulder.y - rightShoulder.y) * 2

  // Pitch stays 0. The shoulder-to-hip z offset gave a constant bias that bowed
  // the avatar while the user stood straight.
  // TODO: Calibrate a neutral pose, or track relative motion.
  const spinePitch = 0

  const leftArmResult = solveArm(leftShoulder, leftElbow, leftWrist, true)
  const rightArmResult = solveArm(rightShoulder, rightElbow, rightWrist, false)

  return {
    spine: { pitch: spinePitch, yaw: spineYaw, roll: spineRoll },
    leftArm: leftArmResult,
    rightArm: rightArmResult,
  }
}

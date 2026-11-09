/**
 * Arm rotations in solver space (see toSolverSpace in pose-solver.ts): Y up,
 * the avatar faces -Z, and the arms rest along ±X.
 */
import { cross, dot, length, normalize, sub, type Vector3 } from './vector'
import { quaternionToEulerZYX, rotationFromTwoPairs, type EulerZYX } from './quaternion'

export interface ArmRotation {
  /** x twists the upper arm about its own axis, because the arm rests along ±X. */
  shoulder: EulerZYX
  /** A hinge about the bone-local Y axis. x and z are always 0. */
  elbow: EulerZYX
}

export interface DirectArmInput {
  shoulder: Vector3
  elbow: Vector3
  wrist: Vector3
  isLeft: boolean
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value))
}

/**
 * ZYX Euler angles of the shortest-arc rotation from `from` to `to`. The
 * antiparallel case turns π about Y. That is correct only when `from` is
 * perpendicular to Y, as the ±X rest directions are.
 */
function directionToEulerZYX(from: Vector3, to: Vector3): EulerZYX {
  const fromNorm = normalize(from)
  const toNorm = normalize(to)

  if (length(fromNorm) < 0.001 || length(toNorm) < 0.001) {
    return { x: 0, y: 0, z: 0 }
  }

  const d = dot(fromNorm, toNorm)
  const c = cross(fromNorm, toNorm)
  const crossLen = length(c)

  if (crossLen < 0.001) {
    return d > 0 ? { x: 0, y: 0, z: 0 } : { x: 0, y: Math.PI, z: 0 }
  }

  const axis = normalize(c)
  const halfAngle = Math.acos(clamp(d, -1, 1)) / 2
  const s = Math.sin(halfAngle)
  return quaternionToEulerZYX([axis.x * s, axis.y * s, axis.z * s, Math.cos(halfAngle)])
}

/**
 * Upper-arm and elbow rotations from shoulder, elbow, and wrist positions in
 * solver space.
 *
 * A minimal-arc shoulder rotation cannot express upper-arm roll. So the
 * shoulder takes the full 3DOF rotation: it points the bone along
 * shoulder→elbow and rolls it until the elbow hinge axis matches upper × forearm.
 * The elbow is then a 1DOF hinge, so the bend stays on one Euler axis.
 */
export function solveArmDirect(input: DirectArmInput): ArmRotation {
  const { shoulder, elbow, wrist, isLeft } = input

  const tposeDir: Vector3 = isLeft ? { x: -1, y: 0, z: 0 } : { x: 1, y: 0, z: 0 }
  // The hinge axis flips sign per side, so symmetric poses give mirrored
  // Eulers with no 180° upper-arm twist.
  const hingeLocal: Vector3 = isLeft ? { x: 0, y: -1, z: 0 } : { x: 0, y: 1, z: 0 }

  const upperArmDir = sub(elbow, shoulder)
  const forearmDir = sub(wrist, elbow)
  const upperLen = length(upperArmDir)
  const forearmLen = length(forearmDir)

  if (upperLen < 0.001) {
    return { shoulder: { x: 0, y: 0, z: 0 }, elbow: { x: 0, y: 0, z: 0 } }
  }

  const u = normalize(upperArmDir)

  if (forearmLen < 0.001) {
    return { shoulder: directionToEulerZYX(tposeDir, u), elbow: { x: 0, y: 0, z: 0 } }
  }

  const f = normalize(forearmDir)
  const bendAngle = Math.acos(clamp(dot(u, f), -1, 1))

  const hingeWorld = cross(u, f)
  const hingeLen = length(hingeWorld)

  // |u × f| is the sine of the bend, so below 0.01 the arm is within 0.6° of
  // straight. A straight arm defines no hinge plane, and its roll is unknown.
  if (hingeLen < 0.01) {
    return { shoulder: directionToEulerZYX(tposeDir, u), elbow: { x: 0, y: 0, z: 0 } }
  }

  const nWorld: Vector3 = {
    x: hingeWorld.x / hingeLen,
    y: hingeWorld.y / hingeLen,
    z: hingeWorld.z / hingeLen,
  }

  const shoulderEuler = quaternionToEulerZYX(rotationFromTwoPairs(tposeDir, hingeLocal, u, nWorld))

  // The left hinge axis is -Y, so its bend is a Y rotation of -bendAngle.
  const elbowY = isLeft ? -bendAngle : bendAngle

  return {
    shoulder: shoulderEuler,
    elbow: { x: 0, y: elbowY, z: 0 },
  }
}

const MAX_ELBOW_FLEX = 2.6 // rad, about 149°

/**
 * Limits elbow flexion to an anatomical maximum. The other angles need no
 * clamp: solveArmDirect keeps the shoulder angles within [-π, π] and the
 * elbow x and z at 0.
 */
export function clampArmRotation(result: ArmRotation): ArmRotation {
  return {
    shoulder: result.shoulder,
    elbow: { ...result.elbow, y: clamp(result.elbow.y, -MAX_ELBOW_FLEX, MAX_ELBOW_FLEX) },
  }
}

/**
 * Quaternions are [x, y, z, w]. Euler angles are radians in three.js order
 * 'ZYX', so the matrix is Rz · Ry · Rx and the X rotation applies first.
 */
import { cross, type Vector3 } from './vector'

export type Quat = [number, number, number, number]

export interface EulerZYX {
  x: number
  y: number
  z: number
}

export function eulerZYXToQuat(e: EulerZYX): Quat {
  const cx = Math.cos(e.x * 0.5), sx = Math.sin(e.x * 0.5)
  const cy = Math.cos(e.y * 0.5), sy = Math.sin(e.y * 0.5)
  const cz = Math.cos(e.z * 0.5), sz = Math.sin(e.z * 0.5)
  return [
    sx * cy * cz - cx * sy * sz,
    cx * sy * cz + sx * cy * sz,
    -sx * sy * cz + cx * cy * sz,
    cx * cy * cz + sx * sy * sz,
  ]
}

/** Unit quaternion to Euler angles. */
export function quaternionToEulerZYX(q: Quat): EulerZYX {
  const [qx, qy, qz, qw] = q
  const sinY = 2 * (qw * qy - qx * qz)
  if (Math.abs(sinY) >= 0.9999999) {
    return {
      x: 0,
      y: (Math.PI / 2) * Math.sign(sinY),
      z: Math.atan2(-(2 * (qx * qy - qw * qz)), 1 - 2 * (qx * qx + qz * qz)),
    }
  }
  return {
    x: Math.atan2(2 * (qw * qx + qy * qz), 1 - 2 * (qx * qx + qy * qy)),
    y: Math.asin(sinY),
    z: Math.atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qy * qy + qz * qz)),
  }
}

/** a · b, so b applies first. */
export function quatMul(a: Quat, b: Quat): Quat {
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ]
}

/**
 * The rotation R with R · uLocal = uWorld and R · nLocal = nWorld. Each pair
 * must be orthonormal, and both pairs must have the same handedness.
 */
export function rotationFromTwoPairs(
  uLocal: Vector3,
  nLocal: Vector3,
  uWorld: Vector3,
  nWorld: Vector3
): Quat {
  const tLocal = cross(uLocal, nLocal)
  const tWorld = cross(uWorld, nWorld)

  // R maps the local frame (u, n, t) to the world frame. The frames are
  // orthonormal, so R = world · localᵀ:
  //   R[i][j] = uWorld[i]·uLocal[j] + nWorld[i]·nLocal[j] + tWorld[i]·tLocal[j]
  const m00 = uWorld.x * uLocal.x + nWorld.x * nLocal.x + tWorld.x * tLocal.x
  const m01 = uWorld.x * uLocal.y + nWorld.x * nLocal.y + tWorld.x * tLocal.y
  const m02 = uWorld.x * uLocal.z + nWorld.x * nLocal.z + tWorld.x * tLocal.z
  const m10 = uWorld.y * uLocal.x + nWorld.y * nLocal.x + tWorld.y * tLocal.x
  const m11 = uWorld.y * uLocal.y + nWorld.y * nLocal.y + tWorld.y * tLocal.y
  const m12 = uWorld.y * uLocal.z + nWorld.y * nLocal.z + tWorld.y * tLocal.z
  const m20 = uWorld.z * uLocal.x + nWorld.z * nLocal.x + tWorld.z * tLocal.x
  const m21 = uWorld.z * uLocal.y + nWorld.z * nLocal.y + tWorld.z * tLocal.y
  const m22 = uWorld.z * uLocal.z + nWorld.z * nLocal.z + tWorld.z * tLocal.z

  // Matrix to quaternion (Shepperd / Shoemake). If the trace is not positive,
  // the largest diagonal element picks the branch, which keeps the divisor away from 0.
  const trace = m00 + m11 + m22
  let qx: number, qy: number, qz: number, qw: number
  if (trace > 0) {
    const s = Math.sqrt(trace + 1) * 2
    qw = 0.25 * s
    qx = (m21 - m12) / s
    qy = (m02 - m20) / s
    qz = (m10 - m01) / s
  } else if (m00 > m11 && m00 > m22) {
    const s = Math.sqrt(1 + m00 - m11 - m22) * 2
    qw = (m21 - m12) / s
    qx = 0.25 * s
    qy = (m01 + m10) / s
    qz = (m02 + m20) / s
  } else if (m11 > m22) {
    const s = Math.sqrt(1 + m11 - m00 - m22) * 2
    qw = (m02 - m20) / s
    qx = (m01 + m10) / s
    qy = 0.25 * s
    qz = (m12 + m21) / s
  } else {
    const s = Math.sqrt(1 + m22 - m00 - m11) * 2
    qw = (m10 - m01) / s
    qx = (m02 + m20) / s
    qy = (m12 + m21) / s
    qz = 0.25 * s
  }
  return [qx, qy, qz, qw]
}

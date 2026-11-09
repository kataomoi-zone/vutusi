export interface Vector3 {
  x: number
  y: number
  z: number
}

export function sub(a: Vector3, b: Vector3): Vector3 {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }
}

export function scale(v: Vector3, s: number): Vector3 {
  return { x: v.x * s, y: v.y * s, z: v.z * s }
}

export function dot(a: Vector3, b: Vector3): number {
  return a.x * b.x + a.y * b.y + a.z * b.z
}

export function cross(a: Vector3, b: Vector3): Vector3 {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  }
}

export function length(v: Vector3): number {
  return Math.sqrt(dot(v, v))
}

/** Returns the zero vector for a near-zero input, so callers can test the length. */
export function normalize(v: Vector3): Vector3 {
  const len = length(v)
  if (len < 1e-9) return { x: 0, y: 0, z: 0 }
  return scale(v, 1 / len)
}

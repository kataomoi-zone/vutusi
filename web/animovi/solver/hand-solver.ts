import { cross, dot, length, normalize, scale, sub, type Vector3 } from '../math/vector'
import { toSolverSpace } from './pose-solver'

export interface HandLandmark {
  x: number
  y: number
  z: number
}

export type HandLandmarks = HandLandmark[]

/**
 * The subject's side. HolisticLandmarker tracks the left hand from the pose's
 * left wrist (landmark 15), and the pose's left is the subject's left.
 */
export type HandSide = 'left' | 'right'

export interface FingerRotation {
  curl: number // 0 = extended, 1 = fully curled
  spread: number // [-1, 1], ±1 at 45° from the middle finger. Positive is toward the pinky.
}

/**
 * Hand orientation in solver space, as two perpendicular unit vectors.
 * TrackingBridge composes it with the arm chain to get the wrist bone's local
 * rotation.
 *
 * The palm normal alone is degenerate when it lines up with the forearm. That
 * happens when the user reaches toward the camera with the palm facing it.
 */
export interface WristFrame {
  /** From the wrist toward the middle-finger knuckle (MCP), in the palm plane. */
  handAxis: Vector3
  /** Out of the palm. */
  palmNormal: Vector3
}

export interface HandResult {
  thumb: FingerRotation
  index: FingerRotation
  middle: FingerRotation
  ring: FingerRotation
  pinky: FingerRotation
  /** Null when the landmark geometry is degenerate. */
  wristFrame: WristFrame | null
}

// MediaPipe Hand landmark indices, knuckle (MCP) to tip. For the thumb they
// are CMC, MCP, IP, and tip.
const FINGER_INDICES = {
  thumb: [1, 2, 3, 4],
  index: [5, 6, 7, 8],
  middle: [9, 10, 11, 12],
  ring: [13, 14, 15, 16],
  pinky: [17, 18, 19, 20],
}

function angleBetween(a: Vector3, b: Vector3): number {
  if (length(a) < 1e-6 || length(b) < 1e-6) return 0
  const cosA = dot(normalize(a), normalize(b))
  return Math.acos(Math.max(-1, Math.min(1, cosA)))
}

function clamp01(v: number): number {
  return Math.max(0, Math.min(1, v))
}

function calculateWristFrame(landmarks: HandLandmarks, side: HandSide): WristFrame | null {
  const wrist = toSolverSpace(landmarks[0])
  const indexMCP = toSolverSpace(landmarks[FINGER_INDICES.index[0]])
  const middleMCP = toSolverSpace(landmarks[FINGER_INDICES.middle[0]])
  const pinkyMCP = toSolverSpace(landmarks[FINGER_INDICES.pinky[0]])

  // In solver space, cross(wrist→index, wrist→pinky) points out of the back of
  // the subject's left hand, so the sign flips. The right hand's mirrored layout makes the
  // same cross product point out of the palm.
  const rawNormal = cross(sub(indexMCP, wrist), sub(pinkyMCP, wrist))
  const sideSign = side === 'left' ? -1 : 1
  const palmNormal = normalize(scale(rawNormal, sideSign))
  if (length(palmNormal) < 1e-6) return null

  // The middle knuckle usually sits off the palm plane. Projecting onto the
  // plane gives the perpendicular pair that rotationFromTwoPairs requires.
  const handAxisRaw = sub(middleMCP, wrist)
  const handAxisInPlane = sub(handAxisRaw, scale(palmNormal, dot(handAxisRaw, palmNormal)))
  if (length(handAxisInPlane) < 1e-6) return null
  const handAxis = normalize(handAxisInPlane)

  return { handAxis, palmNormal }
}

/**
 * Curl in [0, 1]: the bends at the two joints past the knuckle, summed, over π.
 * A metric on image y alone reads ~0 when the palm faces the camera, because
 * the fingers then curl along z.
 */
function calculateFingerCurl(landmarks: HandLandmarks, fingerIndices: number[]): number {
  const [mcp, pip, dip, tip] = fingerIndices.map((i) => landmarks[i])
  const v1 = sub(pip, mcp)
  const v2 = sub(dip, pip)
  const v3 = sub(tip, dip)
  const totalBend = angleBetween(v1, v2) + angleBetween(v2, v3)
  // Each joint bends about π/2 at most, so π is the practical maximum.
  return clamp01(totalBend / Math.PI)
}

/**
 * Each finger's angle from the middle finger, in the palm plane through the
 * wrist and the knuckles. The palm-plane frame keeps the measure valid when
 * the palm faces the camera.
 */
function calculateFingerSpreads(landmarks: HandLandmarks): Record<string, number> {
  const wrist = landmarks[0]
  const indexMCP = landmarks[FINGER_INDICES.index[0]]
  const middleMCP = landmarks[FINGER_INDICES.middle[0]]
  const pinkyMCP = landmarks[FINGER_INDICES.pinky[0]]

  const axisU = normalize(sub(middleMCP, wrist))
  const sideRaw = sub(pinkyMCP, indexMCP)
  const palmNormal = normalize(cross(axisU, sideRaw))
  // In the palm plane, perpendicular to axisU, pointing from index toward pinky.
  const axisV = normalize(cross(palmNormal, axisU))

  const middleDir = normalize(sub(landmarks[FINGER_INDICES.middle[3]], middleMCP))
  const middleAngle = Math.atan2(dot(middleDir, axisV), dot(middleDir, axisU))

  const fingerNames = ['thumb', 'index', 'middle', 'ring', 'pinky'] as const
  const maxSpreadAngle = Math.PI / 4
  const result: Record<string, number> = {}

  for (const name of fingerNames) {
    const idx = FINGER_INDICES[name]
    const fingerDir = normalize(sub(landmarks[idx[3]], landmarks[idx[0]]))
    const angle = Math.atan2(dot(fingerDir, axisV), dot(fingerDir, axisU))
    const deviation = angle - middleAngle
    result[name] = Math.max(-1, Math.min(1, deviation / maxSpreadAngle))
  }
  return result
}

export function solveHand(landmarks: HandLandmarks, side: HandSide): HandResult | null {
  if (landmarks.length === 0) {
    return null
  }

  const spreads = calculateFingerSpreads(landmarks)

  return {
    thumb: { curl: calculateFingerCurl(landmarks, FINGER_INDICES.thumb), spread: spreads.thumb },
    index: { curl: calculateFingerCurl(landmarks, FINGER_INDICES.index), spread: spreads.index },
    middle: { curl: calculateFingerCurl(landmarks, FINGER_INDICES.middle), spread: spreads.middle },
    ring: { curl: calculateFingerCurl(landmarks, FINGER_INDICES.ring), spread: spreads.ring },
    pinky: { curl: calculateFingerCurl(landmarks, FINGER_INDICES.pinky), spread: spreads.pinky },
    wristFrame: calculateWristFrame(landmarks, side),
  }
}

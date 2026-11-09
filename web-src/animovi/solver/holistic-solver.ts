import { solveFace, type FaceLandmarks, type FaceResult } from './face-solver'
import { solvePose, type PoseLandmarks, type PoseResult } from './pose-solver'
import { solveHand, type HandLandmarks, type HandResult } from './hand-solver'

export interface HolisticLandmarks {
  face: FaceLandmarks
  pose: PoseLandmarks
  // MediaPipe poseWorldLandmarks, in meters. Without them, solvePose estimates
  // spine yaw from normalized z.
  poseWorld?: PoseLandmarks
  leftHand: HandLandmarks
  rightHand: HandLandmarks
}

export interface HolisticResult {
  face: FaceResult | null
  pose: PoseResult | null
  leftHand: HandResult | null
  rightHand: HandResult | null
}

export function solveHolistic(landmarks: HolisticLandmarks): HolisticResult {
  return {
    face: solveFace(landmarks.face),
    pose: solvePose(landmarks.pose, landmarks.poseWorld),
    leftHand: solveHand(landmarks.leftHand, 'left'),
    rightHand: solveHand(landmarks.rightHand, 'right'),
  }
}

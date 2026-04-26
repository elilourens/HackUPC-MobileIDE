import Foundation
import Vision
import CoreGraphics

enum GestureType: String, Equatable {
    case none
    case point
    case pinch
    case openPalm
    case fist
    case thumbsUp
}

final class GestureInterpreter {
    func interpret(landmarks: HandPoseResult) -> GestureType {
        let extended = fingerExtension(landmarks: landmarks)
        let indexExtended = extended.index
        let middleExtended = extended.middle
        let ringExtended = extended.ring
        let littleExtended = extended.little
        let thumbExtended = extended.thumb

        // Pinch: thumb tip near index tip (do not require middle extended — that blocked natural pinches on many hands / slower Vision cadence).
        if let thumb = landmarks.point(.thumbTip), let index = landmarks.point(.indexTip) {
            let d = distance(thumb, index)
            if d < 0.055 {
                return .pinch
            }
        }

        // Thumbs up: thumb extended upward (in vision coords y increases upward),
        // others curled
        if thumbExtended && !indexExtended && !middleExtended && !ringExtended && !littleExtended {
            if let thumbTip = landmarks.point(.thumbTip), let wrist = landmarks.point(.wrist) {
                if thumbTip.y > wrist.y + 0.10 {
                    return .thumbsUp
                }
            }
        }

        // Open palm: all five extended
        if thumbExtended && indexExtended && middleExtended && ringExtended && littleExtended {
            return .openPalm
        }

        // Fist: none extended
        if !indexExtended && !middleExtended && !ringExtended && !littleExtended {
            return .fist
        }

        // Point: index extended, middle/ring/little curled
        if indexExtended && !middleExtended && !ringExtended && !littleExtended {
            return .point
        }

        return .none
    }

    private struct Extension { let thumb: Bool; let index: Bool; let middle: Bool; let ring: Bool; let little: Bool }

    private func fingerExtension(landmarks: HandPoseResult) -> Extension {
        let thumb = isFingerExtended(tip: .thumbTip, mcp: .thumbCMC, landmarks: landmarks, threshold: 0.10)
        let index = isFingerExtended(tip: .indexTip, mcp: .indexMCP, landmarks: landmarks)
        let middle = isFingerExtended(tip: .middleTip, mcp: .middleMCP, landmarks: landmarks)
        let ring = isFingerExtended(tip: .ringTip, mcp: .ringMCP, landmarks: landmarks)
        let little = isFingerExtended(tip: .littleTip, mcp: .littleMCP, landmarks: landmarks)
        return Extension(thumb: thumb, index: index, middle: middle, ring: ring, little: little)
    }

    private func isFingerExtended(tip: VNHumanHandPoseObservation.JointName,
                                  mcp: VNHumanHandPoseObservation.JointName,
                                  landmarks: HandPoseResult,
                                  threshold: CGFloat = 0.13) -> Bool {
        guard let t = landmarks.point(tip), let m = landmarks.point(mcp) else { return false }
        return distance(t, m) > threshold
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}

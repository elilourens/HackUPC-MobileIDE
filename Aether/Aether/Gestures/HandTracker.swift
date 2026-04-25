import Foundation
import Vision
import CoreVideo
import UIKit
import simd

struct HandPoseResult {
    /// Vision-normalized points (origin = bottom-left, range 0...1) keyed by joint name.
    let pointsByJoint: [VNHumanHandPoseObservation.JointName: CGPoint]

    /// Flat ordered list of points used for drawing the skeleton overlay.
    let normalizedPoints: [CGPoint]

    /// Per-finger PIP/MCP/Tip groupings for gesture interpretation.
    let chirality: VNChirality

    func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        pointsByJoint[joint]
    }
}

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest
    private let queue = DispatchQueue(label: "aether.handtracker", qos: .userInteractive)
    private var inFlight: Bool = false

    init() {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        request = r
    }

    func process(pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation,
                 completion: @escaping (HandPoseResult?) -> Void) {
        if inFlight {
            return
        }
        inFlight = true
        queue.async { [weak self] in
            guard let self = self else { return }
            defer { self.inFlight = false }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.request])
            } catch {
                completion(nil)
                return
            }
            guard let observation = self.request.results?.first else {
                completion(nil)
                return
            }
            do {
                let allPoints = try observation.recognizedPoints(.all)
                var dict: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
                var flat: [CGPoint] = []
                for (key, value) in allPoints where value.confidence > 0.3 {
                    dict[key] = value.location
                    flat.append(value.location)
                }
                let result = HandPoseResult(
                    pointsByJoint: dict,
                    normalizedPoints: flat,
                    chirality: observation.chirality
                )
                completion(result)
            } catch {
                completion(nil)
            }
        }
    }
}

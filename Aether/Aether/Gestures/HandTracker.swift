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

/// Runs Vision hand pose on a serial queue. **Coalesces** incoming pixel buffers so we never
/// queue many `queue.async` blocks each capturing an `ARFrame`'s `capturedImage` — that pattern
/// is what triggers "delegate is retaining N ARFrames" when MainActor or Vision falls behind.
final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest
    private let queue = DispatchQueue(label: "aether.handtracker", qos: .userInteractive)
    private let lock = NSLock()
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingOrientation: CGImagePropertyOrientation = .right
    private var workerRunning = false

    init() {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        request = r
    }

    func process(pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation,
                 completion: @escaping (HandPoseResult?) -> Void) {
        lock.lock()
        pendingPixelBuffer = pixelBuffer
        pendingOrientation = orientation
        if workerRunning {
            lock.unlock()
            return
        }
        workerRunning = true
        lock.unlock()

        queue.async { [weak self] in
            self?.drainPendingFrames(completion: completion)
        }
    }

    /// Processes every buffer that queued up during a Vision pass, but reports **only the
    /// latest** pose to `completion` once. Calling `completion` after every inner iteration
    /// scheduled many MainActor Tasks and kept pixel buffers alive long enough for ARKit to warn
    /// that the session delegate was retaining many `ARFrame`s.
    private func drainPendingFrames(completion: @escaping (HandPoseResult?) -> Void) {
        var lastResult: HandPoseResult?
        var didWork = false
        while true {
            lock.lock()
            guard let pixelBuffer = pendingPixelBuffer else {
                workerRunning = false
                lock.unlock()
                if didWork {
                    completion(lastResult)
                }
                return
            }
            pendingPixelBuffer = nil
            let orientation = pendingOrientation
            lock.unlock()

            lastResult = Self.performHandPose(request: request, pixelBuffer: pixelBuffer, orientation: orientation)
            didWork = true
        }
    }

    private static func performHandPose(
        request: VNDetectHumanHandPoseRequest,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> HandPoseResult? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else {
            return nil
        }
        do {
            let allPoints = try observation.recognizedPoints(.all)
            var dict: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            var flat: [CGPoint] = []
            for (key, value) in allPoints where value.confidence > 0.3 {
                dict[key] = value.location
                flat.append(value.location)
            }
            return HandPoseResult(
                pointsByJoint: dict,
                normalizedPoints: flat,
                chirality: observation.chirality
            )
        } catch {
            return nil
        }
    }
}

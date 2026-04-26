import SwiftUI
import ARKit
import RealityKit
import UIKit

struct ARWorkspaceView: UIViewRepresentable {
    @ObservedObject var sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let profile = DevicePerformanceProfile.current
        arView.environment.background = .cameraFeed()
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR]
        arView.environment.lighting.intensityExponent = 1.2
        arView.debugOptions = []
        _ = profile.preferredFPS

        sessionManager.attach(arView: arView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTapRecenter(_:)))
        doubleTap.numberOfTapsRequired = 2

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        // Let a clear double-tap win before single-tap panel logic runs.
        tap.require(toFail: doubleTap)

        arView.addGestureRecognizer(doubleTap)
        arView.addGestureRecognizer(tap)

        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Session lifecycle and gestures are owned by `ARSessionManager` / coordinator.
    }

    func makeCoordinator() -> Coordinator { Coordinator(sessionManager: sessionManager) }

    @MainActor
    final class Coordinator: NSObject {
        let sessionManager: ARSessionManager
        weak var arView: ARView?

        init(sessionManager: ARSessionManager) { self.sessionManager = sessionManager }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARView else { return }
            let location = gesture.location(in: view)
            sessionManager.handleTap(at: location)
        }

        @objc func handleDoubleTapRecenter(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? ARView else { return }
            let location = gesture.location(in: view)
            sessionManager.requestReplacement(doubleTapLocation: location)
        }
    }
}

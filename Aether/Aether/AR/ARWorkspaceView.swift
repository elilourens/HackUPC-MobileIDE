import SwiftUI
import ARKit
import RealityKit

struct ARWorkspaceView: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.environment.background = .cameraFeed()
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR]
        arView.environment.lighting.intensityExponent = 1.2
        arView.debugOptions = []

        sessionManager.attach(arView: arView)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(sessionManager: sessionManager) }

    @MainActor
    final class Coordinator: NSObject {
        let sessionManager: ARSessionManager
        init(sessionManager: ARSessionManager) { self.sessionManager = sessionManager }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARView else { return }
            let location = gesture.location(in: view)
            sessionManager.handleTap(at: location)
        }
    }
}

import ARKit
import RealityKit
import UIKit

@MainActor
final class SpatialSceneManager {
    static let userDefaultsKey = "aether.spatial.scene"

    static func loadPersistedScene() -> SpatialScene {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let scene = SpatialScene(rawValue: raw) {
            return scene
        }
        return .realWorld
    }

    private weak var arView: ARView?
    private weak var workspaceAnchor: AnchorEntity?
    private var sceneAnchor: AnchorEntity?
    private var sceneEntities: [Entity] = []
    private var currentScene: SpatialScene = .realWorld

    func updateContext(arView: ARView?, workspaceAnchor: AnchorEntity?) {
        self.arView = arView
        self.workspaceAnchor = workspaceAnchor
    }

    func apply(scene: SpatialScene, panelManager: PanelManager?, animated: Bool = true) {
        currentScene = scene
        UserDefaults.standard.set(scene.rawValue, forKey: Self.userDefaultsKey)
        print("[SpatialScene] scene selected: \(scene.displayName)")

        removeCurrentScene()
        panelManager?.pulseSceneSwitch()

        guard let arView else { return }

        switch scene {
        case .realWorld:
            arView.environment.background = .cameraFeed()
            arView.environment.lighting.resource = nil
            print("[SpatialScene] scene removed")
            return
        case .focusDark:
            arView.environment.background = .cameraFeed()
            arView.environment.lighting.resource = nil
            setupAnchor()
            buildFocusMode(animated: animated)
            return
        case .cambridge, .canaryWharf, .pretoriaGardens:
            if !attemptEXRLoad(for: scene) {
                print("[SpatialScene] EXR unavailable, using procedural fallback for \(scene.displayName)")
            }
            setupAnchor()
            buildProcedural(for: scene, animated: animated)
        }
    }

    private func setupAnchor() {
        guard let arView else { return }
        let worldOrigin: SIMD3<Float>
        if let workspaceAnchor {
            worldOrigin = workspaceAnchor.position(relativeTo: nil)
        } else if let cam = arView.session.currentFrame?.camera.transform {
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let forward = simd_normalize(SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z))
            worldOrigin = camPos + forward * 1.0
        } else {
            worldOrigin = SIMD3<Float>(0, 0, -1.0)
        }
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(worldOrigin.x, worldOrigin.y, worldOrigin.z, 1)
        let anchor = AnchorEntity(world: m)
        arView.scene.addAnchor(anchor)
        sceneAnchor = anchor
    }

    private func removeCurrentScene() {
        sceneEntities.forEach { $0.removeFromParent() }
        sceneEntities.removeAll()
        sceneAnchor?.removeFromParent()
        sceneAnchor = nil
    }

    private func attemptEXRLoad(for scene: SpatialScene) -> Bool {
        guard let assetName = scene.assetName else { return false }
        print("[SpatialScene] asset load attempted: \(assetName)")
        guard let url = Bundle.main.url(forResource: assetName, withExtension: nil, subdirectory: "EnvironmentMaps")
            ?? Bundle.main.url(forResource: assetName, withExtension: nil) else {
            print("[SpatialScene] asset load failure: file not found in bundle")
            return false
        }
        if #available(iOS 16.0, *) {
            do {
                _ = try TextureResource.load(contentsOf: url)
                print("[SpatialScene] asset load success: \(assetName)")
                return true
            } catch {
                print("[SpatialScene] asset load failure: \(error.localizedDescription)")
            }
        } else {
            print("[SpatialScene] asset load failure: iOS version too old for TextureResource.load")
        }
        return false
    }

    private func buildProcedural(for scene: SpatialScene, animated: Bool) {
        guard let anchor = sceneAnchor else { return }
        let radius: Float = 2.4
        let shell = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: .black)])
        shell.scale = SIMD3<Float>(-1, 1, 1)
        shell.position = SIMD3<Float>(0, 0.3, 0)

        let tintA: UIColor
        let tintB: UIColor
        switch scene {
        case .cambridge:
            tintA = UIColor(red: 0.47, green: 0.39, blue: 0.28, alpha: 0.32)
            tintB = UIColor(red: 0.38, green: 0.52, blue: 0.37, alpha: 0.18)
        case .canaryWharf:
            tintA = UIColor(red: 0.08, green: 0.13, blue: 0.23, alpha: 0.45)
            tintB = UIColor(red: 0.18, green: 0.30, blue: 0.55, alpha: 0.24)
        case .pretoriaGardens:
            tintA = UIColor(red: 0.18, green: 0.42, blue: 0.24, alpha: 0.32)
            tintB = UIColor(red: 0.64, green: 0.78, blue: 0.38, alpha: 0.20)
        case .realWorld, .focusDark:
            tintA = .clear
            tintB = .clear
        }

        let layerA = ModelEntity(
            mesh: .generatePlane(width: 5.0, depth: 5.0),
            materials: [UnlitMaterial(color: tintA)]
        )
        layerA.position = SIMD3<Float>(0, 0.35, -0.2)
        layerA.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        let layerB = ModelEntity(
            mesh: .generatePlane(width: 5.0, depth: 5.0),
            materials: [UnlitMaterial(color: tintB)]
        )
        layerB.position = SIMD3<Float>(0, 1.2, -0.5)
        layerB.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        anchor.addChild(shell)
        anchor.addChild(layerA)
        anchor.addChild(layerB)
        sceneEntities.append(contentsOf: [shell, layerA, layerB])

        if scene == .canaryWharf {
            for i in 0..<8 {
                let bar = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(0.02, 0.45 + Float(i % 3) * 0.15, 0.02)),
                    materials: [UnlitMaterial(color: UIColor(red: 0.32, green: 0.55, blue: 0.95, alpha: 0.45))]
                )
                bar.position = SIMD3<Float>(-1.2 + Float(i) * 0.35, 0.35, -1.15)
                anchor.addChild(bar)
                sceneEntities.append(bar)
            }
        }

        if scene == .pretoriaGardens {
            for i in 0..<30 {
                let p = ModelEntity(
                    mesh: .generateSphere(radius: 0.008),
                    materials: [UnlitMaterial(color: UIColor(red: 0.84, green: 0.92, blue: 0.73, alpha: 0.35))]
                )
                let x = Float(i % 10) * 0.22 - 1.0
                let y = 0.2 + Float(i / 10) * 0.2
                let z = -0.8 - Float(i % 4) * 0.2
                p.position = SIMD3<Float>(x, y, z)
                anchor.addChild(p)
                sceneEntities.append(p)
            }
        }

        animateInIfNeeded(sceneEntities, animated: animated)
    }

    private func buildFocusMode(animated: Bool) {
        guard let anchor = sceneAnchor else { return }
        let shell = ModelEntity(
            mesh: .generateSphere(radius: 1.8),
            materials: [UnlitMaterial(color: UIColor(white: 0.03, alpha: 0.65))]
        )
        shell.scale = SIMD3<Float>(-1, 1, 1)
        shell.position = SIMD3<Float>(0, 0.3, 0)
        anchor.addChild(shell)
        sceneEntities = [shell]
        animateInIfNeeded(sceneEntities, animated: animated)
    }

    private func animateInIfNeeded(_ entities: [Entity], animated: Bool) {
        guard animated else { return }
        for entity in entities {
            let original = entity.scale
            entity.scale = original * 0.96
            entity.move(
                to: Transform(scale: original, rotation: entity.transform.rotation, translation: entity.transform.translation),
                relativeTo: entity.parent,
                duration: 0.28,
                timingFunction: .easeInOut
            )
        }
    }
}

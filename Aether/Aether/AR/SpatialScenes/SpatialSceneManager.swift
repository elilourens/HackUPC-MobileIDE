import ARKit
import ImageIO
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
            arView.environment.lighting.resource = nil
            arView.environment.background = .color(scene.backgroundColor)
            setupAnchor()
            loadSkyboxEnvironment(for: scene, animated: animated)
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

    /// Loads `.skybox` environments: tries Xcode-compiled catalog first, then builds from bundled EXR via `EnvironmentResource(equirectangular:withName:)`.
    private func loadSkyboxEnvironment(for scene: SpatialScene, animated: Bool) {
        guard let baseName = scene.environmentImageBaseName else { return }

        print("[SpatialScene] EnvironmentResource load started: \(baseName)")

        let sceneSnapshot = scene
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentScene == sceneSnapshot else { return }
            guard let arView = self.arView else { return }

            var env: EnvironmentResource?
            do {
                env = try EnvironmentResource.load(named: baseName, in: Bundle.main)
                print("[SpatialScene] EnvironmentResource loaded (precompiled): \(baseName)")
            } catch {
                print("[SpatialScene] precompiled load failed (\(baseName)): \(error.localizedDescription)")
                env = await Self.environmentResourceFromBundledEXR(scene: sceneSnapshot, baseName: baseName)
            }

            guard self.currentScene == sceneSnapshot else { return }
            if let env {
                arView.environment.background = .skybox(env)
                arView.environment.lighting.resource = env
            } else {
                print("[SpatialScene] no EnvironmentResource; using procedural fallback for \(baseName)")
                arView.environment.background = .color(sceneSnapshot.backgroundColor)
                arView.environment.lighting.resource = nil
                self.buildProcedural(for: sceneSnapshot, animated: animated)
            }
        }
    }

    /// Finds the EXR in the bundle (several paths for older installs) and converts it with RealityKit’s async equirectangular initializer.
    private static func environmentResourceFromBundledEXR(scene: SpatialScene, baseName: String) async -> EnvironmentResource? {
        guard let folder = scene.environmentSkyboxFolderName else { return nil }
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: baseName, withExtension: "exr", subdirectory: folder),
            bundle.url(forResource: baseName, withExtension: "exr", subdirectory: "EnvironmentMaps/\(folder)"),
            bundle.url(forResource: baseName, withExtension: "exr", subdirectory: "EnvironmentMaps"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            print("[SpatialScene] EXR not found in bundle for \(baseName) (checked \(folder), EnvironmentMaps/…)")
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("[SpatialScene] ImageIO could not decode EXR at \(url.lastPathComponent)")
            return nil
        }
        do {
            let resource = try await EnvironmentResource(equirectangular: cgImage, withName: baseName)
            print("[SpatialScene] EnvironmentResource built from EXR at \(url.path)")
            return resource
        } catch {
            print("[SpatialScene] init(equirectangular:withName:) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildProcedural(for scene: SpatialScene, animated: Bool) {
        guard let anchor = sceneAnchor else { return }

        let tintA: UIColor
        let tintB: UIColor
        switch scene {
        case .cambridge:
            tintA = UIColor(red: 0.68, green: 0.58, blue: 0.43, alpha: 0.55)
            tintB = UIColor(red: 0.54, green: 0.66, blue: 0.48, alpha: 0.38)
        case .canaryWharf:
            tintA = UIColor(red: 0.10, green: 0.19, blue: 0.42, alpha: 0.62)
            tintB = UIColor(red: 0.22, green: 0.42, blue: 0.74, alpha: 0.42)
        case .pretoriaGardens:
            tintA = UIColor(red: 0.24, green: 0.56, blue: 0.30, alpha: 0.58)
            tintB = UIColor(red: 0.72, green: 0.86, blue: 0.45, alpha: 0.38)
        case .realWorld, .focusDark:
            tintA = .clear
            tintB = .clear
        }

        let layerA = ModelEntity(
            mesh: .generatePlane(width: 6.0, depth: 3.0),
            materials: [UnlitMaterial(color: tintA)]
        )
        layerA.position = SIMD3<Float>(0, 1.0, -1.8)
        layerA.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        let layerB = ModelEntity(
            mesh: .generatePlane(width: 6.6, depth: 2.8),
            materials: [UnlitMaterial(color: tintB)]
        )
        layerB.position = SIMD3<Float>(0, 1.3, -2.6)
        layerB.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        let floorTint = ModelEntity(
            mesh: .generatePlane(width: 3.8, depth: 3.8),
            materials: [UnlitMaterial(color: tintA.withAlphaComponent(0.16))]
        )
        floorTint.position = SIMD3<Float>(0, -0.02, 0)
        floorTint.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        anchor.addChild(layerA)
        anchor.addChild(layerB)
        anchor.addChild(floorTint)
        sceneEntities.append(contentsOf: [layerA, layerB, floorTint])

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
            mesh: .generateSphere(radius: 2.8),
            materials: [UnlitMaterial(color: UIColor(white: 0.02, alpha: 0.48))]
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

private extension SpatialScene {
    var backgroundColor: UIColor {
        switch self {
        case .realWorld:
            return .black
        case .cambridge:
            return UIColor(red: 0.20, green: 0.18, blue: 0.16, alpha: 1)
        case .canaryWharf:
            return UIColor(red: 0.03, green: 0.07, blue: 0.15, alpha: 1)
        case .pretoriaGardens:
            return UIColor(red: 0.08, green: 0.16, blue: 0.08, alpha: 1)
        case .focusDark:
            return UIColor(white: 0.03, alpha: 1)
        }
    }
}

import Foundation
import RealityKit
import UIKit
import simd

enum PanelKind: String, CaseIterable, Hashable {
    case editor
    case fileTree
    case terminal
    case assistant
    case preview
    case docs
    case terry
}

final class PanelEntity: Entity, HasModel {
    let kind: PanelKind
    let widthMeters: Float
    let heightMeters: Float

    let surface: ModelEntity
    let border: ModelEntity

    private var baseOpacity: Float = 0.92
    private var hovered: Bool = false
    private var grabbed: Bool = false
    private var selected: Bool = false
    private var currentTexture: TextureResource?
    private var globalOpacity: Float = 1.0

    init(kind: PanelKind, width: Float, height: Float, texture: TextureResource?, isDark: Bool = false) {
        self.kind = kind
        self.widthMeters = width
        self.heightMeters = height

        // Neutral grey halo plane (slightly larger, sits behind the surface). Creates a soft hover glow without any blue.
        let glowColor = UIColor(red: 168/255.0, green: 173/255.0, blue: 179/255.0, alpha: 0.18)
        var borderMat = UnlitMaterial(color: glowColor)
        borderMat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let borderMesh = MeshResource.generatePlane(width: width + 0.012, height: height + 0.012, cornerRadius: 0.0)
        self.border = ModelEntity(mesh: borderMesh, materials: [borderMat])
        border.position = SIMD3<Float>(0, 0, -0.0008)

        // Surface — sharp-cornered plane carrying the JARVIS texture.
        var surfMat = UnlitMaterial(color: .white)
        if let texture = texture {
            surfMat.color = .init(tint: .white, texture: .init(texture))
        }
        surfMat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let surfMesh = MeshResource.generatePlane(width: width, height: height, cornerRadius: 0.0)
        self.surface = ModelEntity(mesh: surfMesh, materials: [surfMat])

        super.init()

        addChild(border)
        addChild(surface)

        // Component to allow ray-hit detection
        let collisionShape = ShapeResource.generateBox(width: width, height: height, depth: 0.005)
        let collision = CollisionComponent(shapes: [collisionShape])
        components.set(collision)
        // Also set on surface so hitTest finds the panel via either parent or child entity.
        surface.components.set(collision)
    }

    @MainActor required init() {
        fatalError("init() is unavailable for PanelEntity")
    }

    func updateTexture(_ texture: TextureResource) {
        currentTexture = texture
        refreshSurface()
    }

    func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        refreshBorder()
    }

    func setGrabbed(_ grabbed: Bool) {
        self.grabbed = grabbed
        refreshBorder()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        refreshBorder()
    }

    /// Multiply the panel's surface and halo by `opacity` (0...1). Used by focus mode.
    func setOpacity(_ opacity: Float) {
        globalOpacity = max(0, min(1, opacity))
        refreshSurface()
        refreshBorder()
    }

    private func refreshSurface() {
        var m = UnlitMaterial(color: .white)
        let tint = UIColor.white.withAlphaComponent(CGFloat(globalOpacity))
        if let tex = currentTexture {
            m.color = .init(tint: tint, texture: .init(tex))
        } else {
            m.color = .init(tint: tint)
        }
        m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        surface.model?.materials = [m]
    }

    private func refreshBorder() {
        var alpha: CGFloat
        if grabbed { alpha = 0.70 }
        else if selected { alpha = 0.55 }
        else if hovered { alpha = 0.40 }
        else { alpha = 0.18 }
        alpha *= CGFloat(globalOpacity)
        let color = UIColor(red: 168/255.0, green: 173/255.0, blue: 179/255.0, alpha: alpha)
        var mat = UnlitMaterial(color: color)
        mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        border.model?.materials = [mat]
    }
}

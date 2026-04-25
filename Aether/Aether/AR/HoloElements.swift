import Foundation
import RealityKit
import UIKit
import simd

/// Shared palette + factory helpers for the holographic AR elements.
enum Holo {
    static let cyan       = UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 1.0)
    static let cyanBright = UIColor(red: 100/255, green: 230/255, blue: 255/255, alpha: 1.0)
    static let cyanDim    = UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 0.55)
    static let cyanFaint  = UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 0.25)
    static let lightBlue  = UIColor(red:  88/255, green: 166/255, blue: 255/255, alpha: 1.0)

    // IntelliJ Islands palette for ambient AR elements (replaces the cyan
    // signature on the desk circle, git timeline, etc).
    static let intelBlue       = UIColor(red:  74/255, green: 136/255, blue: 199/255, alpha: 1.00) // #4A88C7
    static let intelBlueDim    = UIColor(red:  74/255, green: 136/255, blue: 199/255, alpha: 0.55)
    static let intelBlueFaint  = UIColor(red:  74/255, green: 136/255, blue: 199/255, alpha: 0.20)
    static let intelGreen      = UIColor(red:  89/255, green: 168/255, blue: 105/255, alpha: 1.00) // #59A869
    static let intelGreenBright = UIColor(red: 110/255, green: 195/255, blue: 130/255, alpha: 1.00)
    static let intelGrey       = UIColor(red: 111/255, green: 115/255, blue: 122/255, alpha: 0.85) // #6F737A
    static let intelGreyFaint  = UIColor(red: 111/255, green: 115/255, blue: 122/255, alpha: 0.40)
    static let intelText       = UIColor(red: 188/255, green: 190/255, blue: 196/255, alpha: 1.00) // #BCBEC4
    static let red        = UIColor(red:   1.0,  green: 0.30,    blue: 0.42,    alpha: 1.0)
    static let redDim     = UIColor(red:   1.0,  green: 0.30,    blue: 0.42,    alpha: 0.55)
    static let neonGreen  = UIColor(red:   0.43, green: 1.0,     blue: 0.69,    alpha: 1.0)
    static let neonYellow = UIColor(red:   1.0,  green: 0.85,    blue: 0.32,    alpha: 1.0)
    static let textWhite  = UIColor(red:   0.92, green: 0.95,    blue: 1.0,     alpha: 1.0)

    static func unlit(_ color: UIColor) -> UnlitMaterial {
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        return m
    }

    static func sphere(radius: Float, color: UIColor) -> ModelEntity {
        ModelEntity(mesh: .generateSphere(radius: radius), materials: [unlit(color)])
    }

    static func cube(size: Float, color: UIColor) -> ModelEntity {
        ModelEntity(mesh: .generateBox(size: size), materials: [unlit(color)])
    }

    /// Thin extruded text mesh (faces the same direction the parent does — typically toward the user).
    static func text(_ string: String,
                     fontSize: CGFloat = 0.020,
                     weight: UIFont.Weight = .medium,
                     color: UIColor = cyan,
                     alignment: CTTextAlignment = .center) -> ModelEntity {
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.0002,
            font: font,
            containerFrame: .zero,
            alignment: alignment,
            lineBreakMode: .byTruncatingTail
        )
        let entity = ModelEntity(mesh: mesh, materials: [unlit(color)])
        // Center horizontally so caller can place by midpoint.
        let bounds = entity.visualBounds(relativeTo: nil)
        entity.position.x = -bounds.extents.x / 2 - bounds.center.x
        return entity
    }

    /// Thin box stretched between two world-frame points.
    static func line(from a: SIMD3<Float>,
                     to b: SIMD3<Float>,
                     thickness: Float = 0.0015,
                     color: UIColor = cyanFaint) -> ModelEntity {
        let length = max(0.001, simd_length(b - a))
        let mesh = MeshResource.generateBox(width: length, height: thickness, depth: thickness)
        let entity = ModelEntity(mesh: mesh, materials: [unlit(color)])
        entity.position = (a + b) / 2
        let dir = simd_normalize(b - a)
        let xAxis = SIMD3<Float>(1, 0, 0)
        let dot = simd_dot(xAxis, dir)
        if dot >= 0.9999 {
            // Already aligned with +X, nothing to rotate.
        } else if dot <= -0.9999 {
            entity.transform.rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        } else {
            let axis = simd_normalize(simd_cross(xAxis, dir))
            let angle = acos(simd_clamp(dot, -1, 1))
            entity.transform.rotation = simd_quatf(angle: angle, axis: axis)
        }
        return entity
    }

    /// 2D-style diamond plane (45° rotated square) facing the parent's +Z.
    static func diamond(size: Float, color: UIColor) -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: size, height: size)
        let e = ModelEntity(mesh: mesh, materials: [unlit(color)])
        e.transform.rotation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
        return e
    }
}

// MARK: - Git timeline

final class GitTimelineEntity: Entity {
    private weak var pulseNode: ModelEntity?
    private var pulsePhase: Float = 0

    required override init() {
        super.init()
        let railLength: Float = 0.55
        // IntelliJ palette: rail in #6F737A grey, commit nodes in #4A88C7 blue,
        // latest in #59A869 green. Labels in #BCBEC4.
        let rail = ModelEntity(
            mesh: .generateBox(width: railLength, height: 0.0015, depth: 0.0015),
            materials: [Holo.unlit(Holo.intelGrey)]
        )
        addChild(rail)

        let commits: [(label: String, x: Float, latest: Bool)] = [
            ("init",        -0.24, false),
            ("add login",   -0.09, false),
            ("fix auth",    +0.06, false),
            ("add styles",  +0.22, true),
        ]
        for c in commits {
            let nodeR: Float = c.latest ? 0.012 : 0.0085
            let nodeColor = c.latest ? Holo.intelGreenBright : Holo.intelBlue
            let node = Holo.sphere(radius: nodeR, color: nodeColor)
            node.position = SIMD3<Float>(c.x, 0, 0)
            addChild(node)
            if c.latest { pulseNode = node }

            if c.latest {
                let ring = ModelEntity(
                    mesh: .generatePlane(width: nodeR * 5, height: nodeR * 5, cornerRadius: nodeR * 2.5),
                    materials: [Holo.unlit(Holo.intelGreen.withAlphaComponent(0.22))]
                )
                ring.position = SIMD3<Float>(c.x, 0, -0.0005)
                addChild(ring)
            }

            let label = Holo.text(c.label, fontSize: 0.013, color: Holo.intelText)
            label.position = SIMD3<Float>(c.x, 0.027, 0)
            addChild(label)

            let hash = Holo.text(String(format: "#%04x", abs(c.label.hashValue) & 0xFFFF),
                                 fontSize: 0.008, weight: .regular, color: Holo.intelGrey)
            hash.position = SIMD3<Float>(c.x, -0.020, 0)
            addChild(hash)
        }

        let branchStub = ModelEntity(
            mesh: .generateBox(width: 0.0015, height: 0.018, depth: 0.0015),
            materials: [Holo.unlit(Holo.intelGrey)]
        )
        branchStub.position = SIMD3<Float>(0.06, -0.012, 0)
        addChild(branchStub)
        let branchSphere = Holo.sphere(radius: 0.006, color: Holo.intelGreyFaint)
        branchSphere.position = SIMD3<Float>(0.06, -0.025, 0)
        addChild(branchSphere)
    }


    func tick(deltaTime: Float) {
        pulsePhase += deltaTime * 2.5
        let s: Float = 1.0 + 0.18 * sin(pulsePhase)
        pulseNode?.transform.scale = SIMD3<Float>(s, s, s)
    }
}

// MARK: - Stats ring

final class StatsRingEntity: Entity {
    private let surface: ModelEntity
    private let widthM: Float = 0.22
    private let heightM: Float = 0.22
    private var phase: Float = 0
    private var lastRenderedAt: Float = 0
    private var cpuPct: Int = 34
    private var memMb: Int = 847

    required override init() {
        var m = UnlitMaterial(color: .white)
        m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let mesh = MeshResource.generatePlane(width: 0.22, height: 0.22)
        surface = ModelEntity(mesh: mesh, materials: [m])
        super.init()
        addChild(surface)
        rerender()
    }


    func tick(deltaTime: Float) {
        phase += deltaTime
        if phase - lastRenderedAt > 0.18 {
            // jiggle the values a bit so the ring feels alive
            cpuPct = max(8, min(94, cpuPct + Int.random(in: -3...3)))
            memMb = max(420, min(1820, memMb + Int.random(in: -16...16)))
            lastRenderedAt = phase
            rerender()
        }
    }

    private func rerender() {
        let pixels: CGFloat = 1024
        let size = CGSize(width: pixels, height: pixels)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1; f.opaque = false
            return f
        }())
        let img = renderer.image { ctx in
            let g = ctx.cgContext
            // Triple concentric arcs
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let arcs: [(radius: CGFloat, lineWidth: CGFloat, value: CGFloat, color: UIColor, label: String)] = [
                (380, 22, CGFloat(cpuPct) / 100,                   Holo.cyan,       "CPU"),
                (320, 18, CGFloat(memMb) / 2048,                   Holo.lightBlue,  "MEM"),
                (260, 14, 0.62,                                    Holo.cyanDim,    "BLD"),
            ]
            for arc in arcs {
                // backing track
                g.setStrokeColor(Holo.cyanFaint.cgColor)
                g.setLineWidth(arc.lineWidth)
                g.setLineCap(.round)
                g.addArc(center: center, radius: arc.radius, startAngle: -.pi / 2,
                         endAngle: -.pi / 2 + .pi * 2, clockwise: false)
                g.strokePath()
                // filled portion
                g.setStrokeColor(arc.color.cgColor)
                g.setLineWidth(arc.lineWidth)
                g.addArc(center: center, radius: arc.radius,
                         startAngle: -.pi / 2,
                         endAngle: -.pi / 2 + .pi * 2 * arc.value,
                         clockwise: false)
                g.strokePath()
            }
            // central readouts
            let cpuStr = "CPU \(cpuPct)%"
            let memStr = "MEM \(memMb)MB"
            let bigFont = UIFont.monospacedSystemFont(ofSize: 56, weight: .semibold)
            let smallFont = UIFont.monospacedSystemFont(ofSize: 38, weight: .regular)
            NSAttributedString(string: cpuStr, attributes: [
                .font: bigFont, .foregroundColor: UIColor.white, .kern: 2
            ]).drawCentered(at: CGPoint(x: center.x, y: center.y - 38))
            NSAttributedString(string: memStr, attributes: [
                .font: smallFont, .foregroundColor: Holo.cyan, .kern: 2
            ]).drawCentered(at: CGPoint(x: center.x, y: center.y + 18))
            // outer tick marks
            g.setStrokeColor(Holo.cyanFaint.cgColor)
            g.setLineWidth(1.5)
            for i in 0..<60 {
                let a = CGFloat(i) * .pi * 2 / 60 - .pi / 2
                let inner: CGFloat = i % 5 == 0 ? 412 : 422
                let outer: CGFloat = 432
                g.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                g.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
                g.strokePath()
            }
        }
        guard let cg = img.cgImage,
              let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color))
        else { return }
        var m = UnlitMaterial(color: .white)
        m.color = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        surface.model?.materials = [m]
    }
}

// MARK: - Error markers

final class ErrorMarkersEntity: Entity {
    struct Issue { let line: Int; let message: String; let yOffset: Float }

    private var pulseNodes: [ModelEntity] = []
    private var pulsePhase: Float = 0

    required override init() {
        super.init()
        // Two issues anchored to the editor's right edge area.
        let issues: [Issue] = [
            Issue(line: 12, message: "Type error: string is not number", yOffset: 0.05),
            Issue(line: 27, message: "Missing import: useState",         yOffset: -0.03),
        ]
        for issue in issues {
            // Diamond at the editor margin
            let diamond = Holo.diamond(size: 0.025, color: Holo.red)
            diamond.position = SIMD3<Float>(0, issue.yOffset, 0)
            addChild(diamond)
            pulseNodes.append(diamond)

            // Line number badge inside the diamond
            let lnum = Holo.text("L\(issue.line)", fontSize: 0.009, weight: .semibold, color: .white)
            lnum.position = SIMD3<Float>(0, issue.yOffset, 0.0008)
            addChild(lnum)

            // Connector line to the message
            let conn = Holo.line(
                from: SIMD3<Float>(0.020, issue.yOffset, 0),
                to:   SIMD3<Float>(0.110, issue.yOffset + 0.012, 0),
                thickness: 0.0010,
                color: Holo.redDim
            )
            addChild(conn)

            // Message label
            let msg = Holo.text(issue.message, fontSize: 0.011, weight: .regular, color: Holo.red)
            msg.position = SIMD3<Float>(0.180, issue.yOffset + 0.018, 0)
            addChild(msg)
        }
    }


    func tick(deltaTime: Float) {
        pulsePhase += deltaTime * 3.5
        let s: Float = 1.0 + 0.10 * sin(pulsePhase)
        for node in pulseNodes {
            node.transform.scale = SIMD3<Float>(s, s, s)
        }
    }
}

// MARK: - Architecture graph

final class ArchitectureGraphEntity: Entity {
    private var rotation: Float = 0
    private let pivot = Entity()

    required override init() {
        super.init()
        addChild(pivot)

        // Files as colored nodes
        let nodes: [(name: String, position: SIMD3<Float>, color: UIColor)] = [
            ("App.tsx",   SIMD3<Float>(0,      0.05,  0),    Holo.cyan),
            ("Login.tsx", SIMD3<Float>(-0.10, -0.03,  0),    Holo.cyan),
            ("utils.ts",  SIMD3<Float>(0.10,  -0.05, -0.02), Holo.neonGreen),
            ("index.css", SIMD3<Float>(0.05,   0.10, -0.04), Holo.neonYellow),
            ("router.ts", SIMD3<Float>(-0.02, -0.10,  0.02), Holo.lightBlue),
        ]

        var positions: [String: SIMD3<Float>] = [:]
        for n in nodes {
            let cube = Holo.cube(size: 0.020, color: n.color)
            cube.position = n.position
            pivot.addChild(cube)
            positions[n.name] = n.position

            let label = Holo.text(n.name, fontSize: 0.010, weight: .regular, color: Holo.textWhite)
            label.position = n.position + SIMD3<Float>(0, 0.022, 0)
            pivot.addChild(label)
        }

        let edges: [(String, String)] = [
            ("App.tsx", "Login.tsx"),
            ("Login.tsx", "utils.ts"),
            ("App.tsx", "index.css"),
            ("App.tsx", "router.ts"),
        ]
        for (a, b) in edges {
            guard let pa = positions[a], let pb = positions[b] else { continue }
            let line = Holo.line(from: pa, to: pb, thickness: 0.0010, color: Holo.cyanFaint)
            pivot.addChild(line)
        }
    }


    func tick(deltaTime: Float) {
        rotation += deltaTime * 0.25
        pivot.transform.rotation = simd_quatf(angle: rotation, axis: SIMD3<Float>(0, 1, 0))
    }
}

// MARK: - Dependencies tree

final class DependenciesTreeEntity: Entity {
    required override init() {
        super.init()

        struct Node { let name: String; let pos: SIMD3<Float> }
        let root = Node(name: "my-app", pos: SIMD3<Float>(0, 0.18, 0))
        let tier1: [Node] = [
            Node(name: "react",      pos: SIMD3<Float>(-0.10, 0.06, 0)),
            Node(name: "typescript", pos: SIMD3<Float>(0,     0.06, 0)),
            Node(name: "vite",       pos: SIMD3<Float>(0.10,  0.06, 0)),
        ]
        let tier2: [Node] = [
            Node(name: "react-dom",     pos: SIMD3<Float>(-0.14, -0.06, 0)),
            Node(name: "react-router",  pos: SIMD3<Float>(-0.05, -0.06, 0)),
        ]

        for n in [root] + tier1 + tier2 {
            addChild(hex(at: n.pos, label: n.name))
        }
        // Edges
        for n in tier1 {
            addChild(Holo.line(from: root.pos, to: n.pos, thickness: 0.0010, color: Holo.cyanFaint))
        }
        if let react = tier1.first {
            for child in tier2 {
                addChild(Holo.line(from: react.pos, to: child.pos, thickness: 0.0010, color: Holo.cyanFaint))
            }
        }
    }


    private func hex(at pos: SIMD3<Float>, label: String) -> Entity {
        let group = Entity()
        group.position = pos
        // Hexagonal silhouette = small plane + 6 outline edges (visual approximation)
        let body = ModelEntity(
            mesh: .generatePlane(width: 0.022, height: 0.022, cornerRadius: 0.011),
            materials: [Holo.unlit(Holo.cyan.withAlphaComponent(0.28))]
        )
        group.addChild(body)
        let outline = ModelEntity(
            mesh: .generatePlane(width: 0.024, height: 0.024, cornerRadius: 0.012),
            materials: [Holo.unlit(Holo.cyan.withAlphaComponent(0.55))]
        )
        outline.position.z = -0.0004
        group.addChild(outline)
        let txt = Holo.text(label, fontSize: 0.0095, weight: .regular, color: Holo.textWhite)
        txt.position = SIMD3<Float>(0, 0, 0.0008)
        group.addChild(txt)
        return group
    }
}

// MARK: - Ambient circle (on the desk)

final class AmbientCircleEntity: Entity {
    private var orbitDots: [ModelEntity] = []
    private var orbitPhase: Float = 0
    private let radius: Float = 0.27
    private weak var ringPlane: ModelEntity?
    private var ringTexture: TextureResource?

    required override init() {
        super.init()

        // Render the static parts (ring + compass labels) as a horizontal textured plane
        // because text on a desk-flat plane reads nicer rendered top-down.
        let pixels: CGFloat = 1280
        let size = CGSize(width: pixels, height: pixels)
        let img = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1; f.opaque = false
            return f
        }()).image { ctx in
            let g = ctx.cgContext
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = 540

            // Neutral grey ambient — matches the JetBrains chrome palette.
            // Outer thin ring
            g.setStrokeColor(Holo.intelGrey.withAlphaComponent(0.40).cgColor)
            g.setLineWidth(2)
            g.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            g.strokePath()

            // Inner faint ring
            g.setStrokeColor(Holo.intelGrey.withAlphaComponent(0.18).cgColor)
            g.setLineWidth(1)
            g.addArc(center: center, radius: r - 60, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            g.strokePath()

            // Tick marks
            for i in 0..<48 {
                let a = CGFloat(i) * .pi * 2 / 48 - .pi / 2
                let inner: CGFloat = i % 4 == 0 ? r - 28 : r - 12
                let outer: CGFloat = r
                g.setStrokeColor(Holo.intelGrey.withAlphaComponent(i % 4 == 0 ? 0.45 : 0.25).cgColor)
                g.setLineWidth(i % 4 == 0 ? 2 : 1)
                g.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                g.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
                g.strokePath()
            }

            // Compass labels — dim grey, JetBrains tracked caps.
            let labelFont = UIFont.monospacedSystemFont(ofSize: 36, weight: .semibold)
            let labels: [(String, CGPoint)] = [
                ("SYS", CGPoint(x: center.x, y: center.y - r + 8)),  // top
                ("NET", CGPoint(x: center.x + r - 8, y: center.y)),  // right
                ("MEM", CGPoint(x: center.x, y: center.y + r - 8)),  // bottom
                ("GPU", CGPoint(x: center.x - r + 8, y: center.y)),  // left
            ]
            for (label, point) in labels {
                NSAttributedString(string: label, attributes: [
                    .font: labelFont,
                    .foregroundColor: Holo.intelGrey.withAlphaComponent(0.55),
                    .kern: 4
                ]).drawCentered(at: point)
            }
        }

        if let cg = img.cgImage,
           let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
            ringTexture = tex
            var m = UnlitMaterial(color: .white)
            m.color = .init(tint: .white, texture: .init(tex))
            m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            // Use generatePlane(width:depth:) to lie horizontal (XZ plane).
            let plane = ModelEntity(mesh: .generatePlane(width: 0.65, depth: 0.65), materials: [m])
            addChild(plane)
            ringPlane = plane
        }

        // Four orbiting dots floating just above the ring — neutral grey.
        for i in 0..<4 {
            let dot = Holo.sphere(radius: 0.006, color: Holo.intelGrey.withAlphaComponent(0.65))
            let a = Float(i) * .pi / 2
            dot.position = SIMD3<Float>(cos(a) * radius, 0.012, sin(a) * radius)
            addChild(dot)
            orbitDots.append(dot)
        }
    }


    func tick(deltaTime: Float) {
        orbitPhase += deltaTime * 0.35
        for (i, dot) in orbitDots.enumerated() {
            let a = orbitPhase + Float(i) * .pi / 2
            dot.position = SIMD3<Float>(cos(a) * radius, 0.012, sin(a) * radius)
        }
    }

    func setOpacity(_ opacity: Float) {
        let clamped = CGFloat(max(0, min(1, opacity)))
        if let tex = ringTexture {
            var m = UnlitMaterial(color: .white)
            m.color = .init(tint: UIColor.white.withAlphaComponent(clamped), texture: .init(tex))
            m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            ringPlane?.model?.materials = [m]
        }
        // Dim orbit dots too
        for dot in orbitDots {
            var m = UnlitMaterial(color: Holo.cyanBright.withAlphaComponent(clamped))
            m.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            dot.model?.materials = [m]
        }
    }
}

// MARK: - NSAttributedString centering helper (used by ring + circle textures)

extension NSAttributedString {
    func drawCentered(at point: CGPoint) {
        let s = size()
        draw(at: CGPoint(x: point.x - s.width / 2, y: point.y - s.height / 2))
    }
}

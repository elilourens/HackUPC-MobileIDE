import Foundation
import ARKit
import RealityKit
import Combine
import simd
import UIKit
import Vision

@MainActor
final class ARSessionManager: NSObject, ObservableObject {
    // MARK: Published state
    @Published var hasDetectedSurface: Bool = false
    @Published var workspacePlaced: Bool = false
    @Published var currentGesture: GestureType = .none
    @Published var pointingPanel: PanelKind? = nil
    @Published var grabbedPanel: PanelKind? = nil
    @Published var selectedPanel: PanelKind? = nil
    @Published var selectedPanelCorners: [CGPoint] = []
    @Published var handLandmarksScreen: [CGPoint] = []
    @Published var handDetected: Bool = false
    @Published var aiBubbleText: String = "Listening..."
    @Published var aiBubbleHighlight: BubbleHighlight = .none
    @Published var voiceTranscript: String = ""

    // MARK: AR
    weak var arView: ARView?
    private var placementIndicatorAnchor: AnchorEntity?
    private var placementIndicatorEntity: ModelEntity?
    private var workspaceAnchor: AnchorEntity?
    private(set) var panelManager: PanelManager?
    private var placementTransform: simd_float4x4?

    // MARK: Phase 2 — Live IDE
    let session = ProjectSession()
    private lazy var previewRenderer: PreviewRenderer = PreviewRenderer()
    /// When true, the next preview-pointing tap selects an element instead of toggling
    /// panel selection. Set by the "select" voice command.
    private var selectionArmed: Bool = false

    // MARK: Hand & gestures
    nonisolated let handTracker = HandTracker()
    let gestureInterpreter = GestureInterpreter()

    // grab state (world-anchored: ray-project finger to a plane at panel depth)
    private var grabStartFingerWorld: SIMD3<Float>?
    private var grabStartPanelWorld: SIMD3<Float>?
    /// Camera-relative depth captured at grab start. Locked for the entire drag so the
    /// finger ray doesn't drift as the panel moves (which would create a feedback loop
    /// that snaps the panel around).
    private var grabLockedDepth: Float?
    private var lastWristNormalized: CGPoint?

    // resize-via-corner state (touch-driven from SwiftUI corner handles)
    struct ScaleDragState {
        let panel: PanelKind
        let initialScale: Float
        let initialDistFromCenter: CGFloat
        let panelCenter: CGPoint
    }
    var scaleDragState: ScaleDragState?
    private var lastSwipeTime: TimeInterval = 0
    private var aiResetWorkItem: DispatchWorkItem?

    // Hand-wave detection: track recent x-velocity sign changes.
    private var waveHistory: [(time: TimeInterval, sign: Int)] = []
    private var lastWaveDismissAt: TimeInterval = 0

    // Open-palm push-to-talk gesture: callback fires with `true` when the user has held
    // an open palm for ≥150ms, and `false` once the palm has been gone for ≥300ms.
    var onPushToTalkChange: ((Bool) -> Void)?
    private var palmFirstSeenAt: TimeInterval?
    private var palmLastSeenAt: TimeInterval = 0
    private var pttGestureActive: Bool = false

    enum BubbleHighlight {
        case none, blue, green
    }

    func attach(arView: ARView) {
        self.arView = arView
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        config.isLightEstimationEnabled = true
        if type(of: config).supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.delegate = self
        arView.session.run(config, options: [.removeExistingAnchors, .resetTracking])

        installPlacementIndicator()
    }

    private func installPlacementIndicator() {
        guard let arView = arView else { return }
        let anchor = AnchorEntity(world: .zero)
        anchor.isEnabled = false

        let width: Float = 0.40
        let depth: Float = 0.30

        var fillMaterial = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.18))
        fillMaterial.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let fill = ModelEntity(
            mesh: .generatePlane(width: width, depth: depth, cornerRadius: 0.02),
            materials: [fillMaterial]
        )

        var borderMaterial = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.85))
        borderMaterial.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let border = ModelEntity(
            mesh: .generatePlane(width: width + 0.006, depth: depth + 0.006, cornerRadius: 0.022),
            materials: [borderMaterial]
        )
        border.position = SIMD3<Float>(0, -0.0005, 0)
        anchor.addChild(border)
        anchor.addChild(fill)

        arView.scene.addAnchor(anchor)
        placementIndicatorAnchor = anchor
        placementIndicatorEntity = fill
    }

    private func updatePlacementIndicator(transform: simd_float4x4) {
        placementIndicatorAnchor?.transform.matrix = transform
        placementIndicatorAnchor?.isEnabled = true
    }

    private func hidePlacementIndicator() {
        placementIndicatorAnchor?.isEnabled = false
    }

    // MARK: Tap / placement
    func handleTap(at point: CGPoint) {
        guard let arView = arView else { return }
        if !workspacePlaced {
            if let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first {
                placementTransform = result.worldTransform
            } else if let result = arView.raycast(from: arView.center, allowing: .estimatedPlane, alignment: .horizontal).first {
                placementTransform = result.worldTransform
            }
            return
        }
        // Post-placement: check for preview panel element selection first
        if let hitResult = arView.hitTest(point, query: .nearest, mask: .all).first,
           let kind = panelManager?.panelKind(for: hitResult.entity),
           kind == .preview,
           !session.currentCode.isEmpty {
            // Try element selection on the preview panel
            handlePreviewTap(hitResult: hitResult)
            return
        }

        // Default panel selection (toggle)
        if let entity = arView.hitTest(point, query: .nearest, mask: .all).first?.entity,
           let kind = panelManager?.panelKind(for: entity) {
            selectPanel(selectedPanel == kind ? nil : kind)
        } else {
            selectPanel(nil)
        }
    }

    private func handlePreviewTap(hitResult: CollisionCastHit) {
        guard let panelManager = panelManager,
              let previewPanel = panelManager.panels[.preview] else { return }

        // RealityKit's hitTest returns the world-space hit position directly.
        let hitWorld = hitResult.position
        // Convert world position to panel-local coordinates
        let localPos = previewPanel.convert(position: hitWorld, from: nil)

        // Panel dimensions in meters
        let widthMeters = previewPanel.widthMeters
        let heightMeters = previewPanel.heightMeters
        let halfW = widthMeters / 2
        let halfH = heightMeters / 2

        // Map to UV (0–1)
        let u = (localPos.x + halfW) / widthMeters
        let v = (localPos.y + halfH) / heightMeters

        // Guard against out-of-bounds (shouldn't happen on a valid hit, but safe)
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return }

        // Map to web pixel coordinates (375×667, Y-flipped). u/v are Float; convert
        // explicitly so the CGPoint init compiles.
        let webX = CGFloat(u) * 375
        let webY = CGFloat(1 - v) * 667

        previewRenderer.selectElement(at: CGPoint(x: webX, y: webY)) { [weak self] info, image in
            guard let self = self else { return }
            self.session.setSelectedElement(info)
            if let image = image {
                self.panelManager?.setPreviewImage(image)
            }
            self.appendTerminalLog(.command, "selected \(info?.humanLabel ?? "element")")
            JarvisVoice.shared.speak("Selected. What would you like to change?")
            self.selectionArmed = false
        }
    }

    func selectPanel(_ kind: PanelKind?) {
        selectedPanel = kind
        panelManager?.setSelected(kind)
        if kind == nil {
            selectedPanelCorners = []
        } else {
            updateSelectedCorners()
        }
    }

    func beginScaleDrag(corner: Int, location: CGPoint) {
        guard let kind = selectedPanel,
              let arView = arView,
              let info = panelManager?.panelWorldPosition(kind),
              let center = arView.project(info.position),
              let scale = panelManager?.panelScale(kind) else { return }
        let dx = location.x - center.x
        let dy = location.y - center.y
        let dist = max(sqrt(dx * dx + dy * dy), 1)
        scaleDragState = ScaleDragState(
            panel: kind,
            initialScale: scale,
            initialDistFromCenter: dist,
            panelCenter: center
        )
    }

    func updateScaleDrag(location: CGPoint) {
        guard let state = scaleDragState else { return }
        let dx = location.x - state.panelCenter.x
        let dy = location.y - state.panelCenter.y
        let dist = sqrt(dx * dx + dy * dy)
        let ratio = Float(dist / state.initialDistFromCenter)
        let newScale = max(0.4, min(2.5, state.initialScale * ratio))
        panelManager?.setPanelScale(state.panel, scale: newScale)
        updateSelectedCorners()
    }

    func endScaleDrag() {
        scaleDragState = nil
    }

    /// Called when a corner drag releases with high velocity — animate the panel out
    /// and clear selection.
    func throwDismissSelectedPanel() {
        guard let kind = selectedPanel else { return }
        // Only voice-spawned panels are dismissible (preview, docs, terminal). Editor /
        // file tree / assistant stay put.
        let dismissible: Set<PanelKind> = [.preview, .docs, .terminal]
        guard dismissible.contains(kind) else { return }
        panelManager?.hidePanel(kind)
        selectPanel(nil)
        JarvisVoice.shared.speak("Done.")
    }

    private func updateSelectedCorners() {
        guard let kind = selectedPanel else {
            if !selectedPanelCorners.isEmpty { selectedPanelCorners = [] }
            return
        }
        if let corners = panelManager?.panelCornersScreen(kind, in: arView) {
            selectedPanelCorners = corners
        }
    }

    @discardableResult
    func placeWorkspace() -> Bool {
        guard !workspacePlaced, let arView = arView, let transform = placementTransform else { return false }

        hidePlacementIndicator()

        // Rotate the anchor so its local +Z points toward the camera (horizontal projection).
        // The panels' fronts will face that direction.
        let anchorPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        var yaw: Float = 0
        if let camTransform = arView.session.currentFrame?.camera.transform {
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            let dx = camPos.x - anchorPos.x
            let dz = camPos.z - anchorPos.z
            yaw = atan2(dx, dz)
        }
        var anchorTransform = matrix_identity_float4x4
        anchorTransform.columns.3 = SIMD4<Float>(anchorPos.x, anchorPos.y, anchorPos.z, 1)
        let anchor = AnchorEntity(world: anchorTransform)
        anchor.transform.rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        arView.scene.addAnchor(anchor)

        let pm = PanelManager()
        pm.createPanels(on: anchor)
        pm.attachSceneUpdates(arView: arView)
        panelManager = pm
        workspaceAnchor = anchor
        workspacePlaced = true
        return true
    }

    private func currentCameraPosition() -> SIMD3<Float> {
        guard let camera = arView?.session.currentFrame?.camera else { return SIMD3<Float>(0, 0, 0) }
        let m = camera.transform
        return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private func currentCameraForward() -> SIMD3<Float> {
        guard let camera = arView?.session.currentFrame?.camera else { return SIMD3<Float>(0, 0, -1) }
        let m = camera.transform
        let forward = SIMD3<Float>(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)
        return forward
    }

    // MARK: Gesture application
    private func applyGesture(_ gesture: GestureType, indexTipScreen: CGPoint?, viewSize: CGSize) {
        guard let arView = arView, let pm = panelManager else { return }

        // Pointing / hover
        if gesture == .point, let tip = indexTipScreen {
            let raycastPoint = CGPoint(x: tip.x, y: tip.y)
            let hit = arView.hitTest(raycastPoint, query: .nearest, mask: .all).first
            let panel: PanelKind?
            if let entity = hit?.entity {
                panel = pm.panelKind(for: entity)
            } else {
                panel = nil
            }
            if pointingPanel != panel {
                pointingPanel = panel
                pm.setHoverHighlight(panel)
            }
        } else {
            if pointingPanel != nil {
                pointingPanel = nil
                pm.setHoverHighlight(nil)
            }
        }

        // Pinch / grab — project finger screen point to a world plane at a LOCKED depth.
        if gesture == .pinch, let tip = indexTipScreen {
            if grabbedPanel == nil, let panel = pointingPanel ?? closestPanelToScreenPoint(tip) {
                grabbedPanel = panel
                pm.setGrabbed(panel)
                let panelPos = pm.panelWorldPosition(panel)?.position ?? SIMD3<Float>(0, 0.2, 0)
                let camPos = currentCameraPosition()
                // Camera-relative depth; locked for the lifetime of this grab.
                let depth = max(0.15, simd_length(panelPos - camPos))
                grabLockedDepth = depth
                grabStartFingerWorld = worldPositionForScreenPoint(tip, depth: depth)
                grabStartPanelWorld = panelPos
            }
            if let panel = grabbedPanel,
               let startFinger = grabStartFingerWorld,
               let startPanel = grabStartPanelWorld,
               let depth = grabLockedDepth,
               let currentFinger = worldPositionForScreenPoint(tip, depth: depth) {
                let delta = currentFinger - startFinger
                let target = startPanel + delta
                // Lerp toward target to smooth out hand-tracking jitter. The panel keeps
                // catching up frame-by-frame; on release we leave it wherever it landed.
                let current = pm.panelWorldPosition(panel)?.position ?? target
                let lerp: Float = 0.35
                let smoothed = SIMD3<Float>(
                    current.x + (target.x - current.x) * lerp,
                    current.y + (target.y - current.y) * lerp,
                    current.z + (target.z - current.z) * lerp
                )
                pm.movePanel(panel, toWorldPosition: smoothed)
            }
        } else {
            if grabbedPanel != nil {
                // Release: panel stays exactly where the lerp last left it. No snap-back.
                pm.setGrabbed(nil)
                grabbedPanel = nil
                grabStartFingerWorld = nil
                grabStartPanelWorld = nil
                grabLockedDepth = nil
            }
        }

        // Swipe (handled in process below via wrist tracking)

        // Thumbs up: confirm
        if gesture == .thumbsUp {
            flashBubble(.green, text: "Confirmed.")
        }
        // Fist: undo
        if gesture == .fist {
            flashBubble(.blue, text: "Action undone.")
        }
    }

    private func handleSwipe(direction: SwipeDirection) {
        guard let pm = panelManager else { return }
        switch direction {
        case .left, .right:
            pm.cycleEditorTab(forward: direction == .right)
        case .up:
            pm.scrollEditor(by: -3)
        case .down:
            pm.scrollEditor(by: 3)
        }
    }

    private func closestPanelToScreenPoint(_ point: CGPoint) -> PanelKind? {
        guard let arView = arView, let pm = panelManager else { return nil }
        var best: (PanelKind, Float)?
        for kind in PanelKind.allCases {
            guard let info = pm.panelWorldPosition(kind) else { continue }
            let projected = arView.project(info.position) ?? .zero
            let dx = Float(projected.x - point.x)
            let dy = Float(projected.y - point.y)
            let d = sqrt(dx * dx + dy * dy)
            if best == nil || d < best!.1 { best = (kind, d) }
        }
        guard let chosen = best, chosen.1 < 200 else { return nil }
        return chosen.0
    }

    private func worldPositionForScreenPoint(_ point: CGPoint, depth: Float) -> SIMD3<Float>? {
        guard let arView = arView, let frame = arView.session.currentFrame else { return nil }
        let cam = frame.camera
        let viewportSize = arView.bounds.size
        // Build a ray from the camera through the screen point, project to plane perpendicular to camera at given depth.
        let normalizedX = Float((point.x / viewportSize.width) * 2 - 1)
        let normalizedY = Float((1 - point.y / viewportSize.height) * 2 - 1)
        // Use ARKit's intrinsics through unprojectPoint.
        let projection = cam.projectionMatrix(for: .portrait, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
        let inverseProjection = projection.inverse
        let inverseView = cam.transform
        var clip = SIMD4<Float>(normalizedX, normalizedY, 1, 1)
        var eye = inverseProjection * clip
        eye = SIMD4<Float>(eye.x, eye.y, -1, 0)
        let world4 = inverseView * eye
        let direction = simd_normalize(SIMD3<Float>(world4.x, world4.y, world4.z))
        let origin = SIMD3<Float>(inverseView.columns.3.x, inverseView.columns.3.y, inverseView.columns.3.z)
        // Move along direction by `depth`.
        return origin + direction * depth
    }

    // MARK: AI bubble
    func updateAIBubble(text: String, isUser: Bool) {
        guard !text.isEmpty else { return }
        if isUser {
            voiceTranscript = text
            aiBubbleText = text
            aiBubbleHighlight = .blue
            panelManager?.updateAssistant(text: text, highlight: .blue)
        } else {
            aiBubbleText = text
            aiBubbleHighlight = .none
            panelManager?.updateAssistant(text: text, highlight: .none)
        }
    }

    // MARK: - Voice command dispatch

    func handleVoiceCommand(_ command: VoiceCommand) {
        switch command {
        case .codegen(let prompt):
            if session.currentCode.isEmpty {
                // Fresh generation
                session.isGenerating = true
                JarvisVoice.shared.speak("On it sir.")
                appendTerminalLog(.command, "generating index.html...")
                panelManager?.showPanel(.preview)
                CodeGenerator.shared.generate(prompt: prompt) { [weak self] result in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        switch result {
                        case .success(let code):
                            self.session.setCode(code, forFile: "index.html", pushHistory: false)
                            self.panelManager?.setEditorCode(code, animated: true)
                            self.panelManager?.setLiveFiles(active: "index.html", files: Array(self.session.projectFiles.keys).sorted())
                            let lineCount = code.split(separator: "\n").count
                            self.appendTerminalLog(.success, "generated \(lineCount) lines")
                            self.loadAndApplyPreview(code: code, settleDelay: 0.6) {
                                JarvisVoice.shared.speak("Preview is live.")
                                self.appendTerminalLog(.success, "preview live")
                            }
                            self.session.isGenerating = false
                        case .failure:
                            JarvisVoice.shared.speak("Generation failed, sir.")
                            self.appendTerminalLog(.error, "generation failed")
                            self.session.isGenerating = false
                        }
                    }
                }
            } else {
                // Modification
                JarvisVoice.shared.speak("Updating.")
                appendTerminalLog(.command, "modifying \(session.currentFile)...")
                CodeGenerator.shared.modify(currentCode: session.currentCode, prompt: prompt, selected: session.selectedElement) { [weak self] result in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        switch result {
                        case .success(let newCode):
                            self.session.setCode(newCode, forFile: self.session.currentFile, pushHistory: true)
                            self.panelManager?.setEditorCode(newCode, animated: false)
                            if self.session.selectedElement != nil {
                                self.session.setSelectedElement(nil)
                                self.previewRenderer.clearSelection { [weak self] image in
                                    self?.panelManager?.setPreviewImage(image)
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                guard let self = self else { return }
                                self.loadAndApplyPreview(code: newCode, settleDelay: 0.3) {
                                    JarvisVoice.shared.speak("Done.")
                                    self.appendTerminalLog(.success, "updated")
                                }
                            }
                        case .failure:
                            JarvisVoice.shared.speak("Modification failed.")
                            self.appendTerminalLog(.error, "modification failed")
                        }
                    }
                }
            }
        case .selectElement:
            selectionArmed = true
            JarvisVoice.shared.speak("Tap on the preview to select.")
        case .deselectElement:
            selectionArmed = false
            previewRenderer.clearSelection { [weak self] image in
                self?.panelManager?.setPreviewImage(image)
            }
            session.setSelectedElement(nil)
            JarvisVoice.shared.speak("Selection cleared.")
        case .undo:
            if let restored = session.undo() {
                panelManager?.setEditorCode(restored.code, animated: false)
                if restored.file == "index.html" {
                    loadAndApplyPreview(code: restored.code, settleDelay: 0.3) {
                        JarvisVoice.shared.speak("Reverted.")
                    }
                } else {
                    JarvisVoice.shared.speak("Reverted.")
                }
                appendTerminalLog(.command, "undo")
            } else {
                JarvisVoice.shared.speak("Nothing to undo.")
            }
        case .newFile(let name):
            session.createFile(name)
            panelManager?.setLiveFiles(active: session.currentFile, files: Array(session.projectFiles.keys).sorted())
            appendTerminalLog(.command, "created \(name)")
            JarvisVoice.shared.speak("File created.")
        case .runPreview:
            panelManager?.showPanel(.preview)
            loadAndApplyPreview(code: session.currentCode, settleDelay: 0.3) {
                JarvisVoice.shared.speak("Running.")
            }
        case .save:
            JarvisVoice.shared.speak("Saved to project.")
            appendTerminalLog(.command, "save")
        case .showPreview:
            panelManager?.showPanel(.preview)
            JarvisVoice.shared.speak("Pulling up the preview now.")
            updateAIBubble(text: "Preview loaded.", isUser: false)
        case .showDocs:
            panelManager?.showPanel(.docs)
            JarvisVoice.shared.speak("Here are the docs.")
            updateAIBubble(text: "Docs loaded.", isUser: false)
        case .showTerminal:
            panelManager?.showPanel(.terminal)
            JarvisVoice.shared.speak("Terminal is up.")
        case .showGit:
            panelManager?.showGitTimeline()
            JarvisVoice.shared.speak("Here's your commit history.")
        case .showErrors:
            panelManager?.showErrorMarkers()
            JarvisVoice.shared.speak("I found 2 issues.")
        case .showStats:
            panelManager?.showStatsRing()
            JarvisVoice.shared.speak("Running diagnostics.")
        case .showArchitecture:
            panelManager?.showArchitectureGraph()
            JarvisVoice.shared.speak("Mapping the architecture.")
        case .showDependencies:
            panelManager?.showDependenciesTree()
            JarvisVoice.shared.speak("Pulling dependencies.")
        case .showTerry:
            panelManager?.showPanel(.terry)
            JarvisVoice.shared.speak("Bringing up Terry. The legend.")
            updateAIBubble(text: "Terry · classified", isUser: false)
        case .hide(let target):
            switch target {
            case .all:
                panelManager?.clearAll()
                panelManager?.hideGitTimeline()
                panelManager?.hideStatsRing()
                panelManager?.hideErrorMarkers()
                panelManager?.hideArchitectureGraph()
                panelManager?.hideDependenciesTree()
            case .preview:      panelManager?.hidePanel(.preview)
            case .docs:         panelManager?.hidePanel(.docs)
            case .terminal:     panelManager?.hidePanel(.terminal)
            case .terry:        panelManager?.hidePanel(.terry)
            case .git:          panelManager?.hideGitTimeline()
            case .errors:       panelManager?.hideErrorMarkers()
            case .stats:        panelManager?.hideStatsRing()
            case .architecture: panelManager?.hideArchitectureGraph()
            case .dependencies: panelManager?.hideDependenciesTree()
            }
            JarvisVoice.shared.speak("Done.")
        case .clear:
            panelManager?.clearAll()
            panelManager?.hideGitTimeline()
            panelManager?.hideStatsRing()
            panelManager?.hideErrorMarkers()
            panelManager?.hideArchitectureGraph()
            panelManager?.hideDependenciesTree()
            JarvisVoice.shared.speak("Workspace cleared.")
        case .focusMode:
            panelManager?.setFocusMode(true)
            JarvisVoice.shared.speak("Focus mode.")
        case .unfocusMode:
            panelManager?.setFocusMode(false)
            JarvisVoice.shared.speak("Back to normal.")
        case .darkMode:
            panelManager?.setTheme(.dark)
            JarvisVoice.shared.speak("Switching to dark mode.")
        case .lightMode:
            panelManager?.setTheme(.light)
            JarvisVoice.shared.speak("Going light.")
        case .createFunction(let name):
            JarvisVoice.shared.speak("On it.")
            updateAIBubble(text: "Creating \(name)…", isUser: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                JarvisVoice.shared.speak("Done. I've added it to your editor.")
                self.updateAIBubble(text: "Added \(name) to Login.tsx.", isUser: false)
            }
        case .ask(let question):
            updateAIBubble(text: "Thinking…", isUser: false)
            GeminiClient.shared.ask(question) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let answer):
                        self.updateAIBubble(text: answer, isUser: false)
                        JarvisVoice.shared.speak(answer)
                    case .failure:
                        let fallback = "I'm having trouble with that one, sir."
                        self.updateAIBubble(text: fallback, isUser: false)
                        JarvisVoice.shared.speak(fallback)
                    }
                }
            }
        }
    }

    /// Speaks the JARVIS welcome line, called once when the workspace is placed.
    func speakWelcome() {
        JarvisVoice.shared.speak("Hello sir. What are we working on today?")
    }

    func runFakeAIResponse() {
        let firstResponse = "Got it. Working on that now..."
        let secondResponse = "Done. Changes applied to Login.tsx"
        DispatchQueue.main.async {
            self.aiBubbleText = firstResponse
            self.aiBubbleHighlight = .blue
            self.panelManager?.updateAssistant(text: firstResponse, highlight: .blue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.aiBubbleText = secondResponse
            self.aiBubbleHighlight = .green
            self.panelManager?.updateAssistant(text: secondResponse, highlight: .green)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            self.aiBubbleText = "Listening..."
            self.aiBubbleHighlight = .none
            self.panelManager?.updateAssistant(text: "Listening...", highlight: .none)
        }
    }

    private func flashBubble(_ color: BubbleHighlight, text: String) {
        aiBubbleText = text
        aiBubbleHighlight = color
        panelManager?.updateAssistant(text: text, highlight: color)
        aiResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.aiBubbleText = "Listening..."
            self.aiBubbleHighlight = .none
            self.panelManager?.updateAssistant(text: "Listening...", highlight: .none)
        }
        aiResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: item)
    }

    private func appendTerminalLog(_ kind: TerminalLine.Kind, _ text: String) {
        switch kind {
        case .command: session.termCommand(text)
        case .output:  session.termOutput(text)
        case .success: session.termSuccess(text)
        case .error:   session.termError(text)
        case .info:    session.termInfo(text)
        }
        panelManager?.setTerminalLog(session.terminalLines)
    }

    /// Load HTML into the off-screen WKWebView, snapshot, apply to preview panel.
    /// Calls `onPreviewReady` after the snapshot is in place.
    private func loadAndApplyPreview(code: String, settleDelay: TimeInterval, onPreviewReady: (() -> Void)? = nil) {
        appendTerminalLog(.command, "rendering preview...")
        previewRenderer.loadHTML(code, settleDelay: settleDelay) { [weak self] image in
            guard let self = self else { return }
            self.panelManager?.setPreviewImage(image)
            onPreviewReady?()
        }
    }
}

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // CRITICAL: never capture `frame` or its `capturedImage` in a Task targeting MainActor.
        // The pixel buffer is allocated from ARKit's pool; if MainActor is busy and Tasks pile up,
        // each pending Task pins a buffer and ARKit complains ("delegate is retaining N ARFrames"
        // followed by camera stalls).
        //
        // Instead: hand the buffer DIRECTLY to HandTracker's bg queue (which has its own
        // inFlight guard that drops new buffers if one is still being processed). Only the
        // lightweight, buffer-free placement tick hops to MainActor.
        let pixelBuffer = frame.capturedImage
        handTracker.process(pixelBuffer: pixelBuffer, orientation: .right) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyHandResult(result)
            }
        }
        Task { @MainActor [weak self] in
            self?.tickPlacement()
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let hasHorizontal = anchors.contains { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }
        if hasHorizontal {
            Task { @MainActor [weak self] in
                self?.hasDetectedSurface = true
            }
        }
    }
}

extension ARSessionManager {
    fileprivate func tickPlacement() {
        if !workspacePlaced, let arView = arView {
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            if let result = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal).first {
                placementTransform = result.worldTransform
                if !hasDetectedSurface { hasDetectedSurface = true }
                updatePlacementIndicator(transform: result.worldTransform)
            }
        }
        if selectedPanel != nil {
            updateSelectedCorners()
        }
    }

    fileprivate func applyHandResult(_ result: HandPoseResult?) {
        guard let arView = arView else { return }
        let viewSize = arView.bounds.size
        let interfaceOrientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait

        guard let result = result else {
            handDetected = false
            handLandmarksScreen = []
            currentGesture = .none
            return
        }
        handDetected = true
        handLandmarksScreen = result.normalizedPoints.map {
            viewPoint(fromVisionNormalized: $0, viewSize: viewSize, orientation: interfaceOrientation)
        }

        let gesture = gestureInterpreter.interpret(landmarks: result)
        currentGesture = gesture

        // OPEN-PALM = push-to-talk. Activate after 150ms of continuous palm so a brief
        // accidental flash of an open hand doesn't trigger it; deactivate 300ms after
        // the palm goes away so a frame of jittery detection doesn't cut you off.
        let now = CACurrentMediaTime()
        if gesture == .openPalm {
            if palmFirstSeenAt == nil { palmFirstSeenAt = now }
            palmLastSeenAt = now
            if !pttGestureActive, now - (palmFirstSeenAt ?? now) > 0.15 {
                pttGestureActive = true
                onPushToTalkChange?(true)
            }
        } else {
            palmFirstSeenAt = nil
            if pttGestureActive, now - palmLastSeenAt > 0.30 {
                pttGestureActive = false
                onPushToTalkChange?(false)
            }
        }

        let indexTipScreen: CGPoint? = result.point(.indexTip).map {
            viewPoint(fromVisionNormalized: $0, viewSize: viewSize, orientation: interfaceOrientation)
        }

        // Suppress hand-driven panel manipulation while the user is dragging a corner handle.
        if workspacePlaced && scaleDragState == nil {
            applyGesture(gesture, indexTipScreen: indexTipScreen, viewSize: viewSize)
        }

        if let wristNorm = result.point(.wrist) {
            let wristScreen = viewPoint(fromVisionNormalized: wristNorm, viewSize: viewSize, orientation: interfaceOrientation)
            if let last = lastWristNormalized {
                let dx = wristScreen.x - last.x
                let dy = wristScreen.y - last.y
                let now = CACurrentMediaTime()

                // Hand-wave: count rapid x-direction reversals (3+ within 1s).
                if abs(dx) > 6 {
                    let sign = dx > 0 ? 1 : -1
                    if waveHistory.last?.sign != sign {
                        waveHistory.append((now, sign))
                    }
                    waveHistory.removeAll { now - $0.time > 1.0 }
                    if waveHistory.count >= 4, now - lastWaveDismissAt > 1.0 {
                        lastWaveDismissAt = now
                        waveHistory.removeAll()
                        // Wave dismisses the floating holo element. Cheap heuristic: hide all holos.
                        panelManager?.hideGitTimeline()
                        panelManager?.hideStatsRing()
                        panelManager?.hideErrorMarkers()
                        panelManager?.hideArchitectureGraph()
                        panelManager?.hideDependenciesTree()
                        JarvisVoice.shared.speak("Done.")
                    }
                }

                if now - lastSwipeTime > 0.6 {
                    if abs(dx) > 80 && abs(dx) > abs(dy) * 1.6 {
                        handleSwipe(direction: dx > 0 ? .right : .left)
                        lastSwipeTime = now
                    } else if abs(dy) > 80 && abs(dy) > abs(dx) * 1.6 {
                        handleSwipe(direction: dy > 0 ? .down : .up)
                        lastSwipeTime = now
                    }
                }
            }
            lastWristNormalized = wristScreen
        }
    }

    private func viewPoint(fromVisionNormalized point: CGPoint, viewSize: CGSize, orientation: UIInterfaceOrientation) -> CGPoint {
        // Vision returns (0,0)=bottom-left. We rotate based on interface orientation.
        let x = point.x
        let y = point.y
        switch orientation {
        case .portrait:
            // x_view = (1 - y) * width ; y_view = (1 - x) * height
            return CGPoint(x: (1 - y) * viewSize.width, y: (1 - x) * viewSize.height)
        case .portraitUpsideDown:
            return CGPoint(x: y * viewSize.width, y: x * viewSize.height)
        case .landscapeLeft:
            return CGPoint(x: (1 - x) * viewSize.width, y: y * viewSize.height)
        case .landscapeRight:
            return CGPoint(x: x * viewSize.width, y: (1 - y) * viewSize.height)
        default:
            return CGPoint(x: (1 - y) * viewSize.width, y: (1 - x) * viewSize.height)
        }
    }

}

enum SwipeDirection {
    case up, down, left, right
}

extension SIMD3 where Scalar == Float {
    static func - (lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
    static func + (lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    static func * (lhs: SIMD3<Float>, rhs: Float) -> SIMD3<Float> {
        SIMD3<Float>(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
}

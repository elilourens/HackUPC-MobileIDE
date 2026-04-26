import Foundation
import ARKit
import RealityKit
import Combine
import simd
import UIKit
import Vision
import AVFoundation

@MainActor
final class ARSessionManager: NSObject, ObservableObject {
    // MARK: Published state
    @Published var hasDetectedSurface: Bool = false
    @Published var workspacePlaced: Bool = false
    /// True after the user has tapped "Let's start" (or kicked off the first voice
    /// command). Until this flips, the desk shows only the ambient circle — no
    /// editor / file tree / terminal / assistant panels. Lets the workspace
    /// "wake up" with a satisfying conjure animation rather than dumping
    /// everything on the user the moment they place the anchor.
    @Published var workspaceStarted: Bool = false
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
    private var architectureGraph: ArchitectureGraphEntityV2?
    private var connectionLines: ConnectionLinesEntity?
    private var diffView: GitDiffView?

    // MARK: Phase 2 — Live IDE
    /// Shared with PhoneIDEView. Owned at the App level so edits in either mode
    /// flow into the other.
    let session: ProjectSession
    private lazy var previewRenderer: PreviewRenderer = PreviewRenderer()

    init(session: ProjectSession) {
        self.session = session
        super.init()
    }

    /// Callback fired when the user wants to leave AR mode and return to the phone IDE.
    /// Wired by ContentView to flip the top-level phase.
    var onRequestPhoneMode: (() -> Void)?

    /// When true, the next preview-pointing tap selects an element instead of toggling
    /// panel selection. Set by the "select" voice command.
    private var selectionArmed: Bool = false
    /// Sticky version of `pointingPanel` — keeps the last non-nil value so a swipe
    /// gesture (which clears pointingPanel mid-motion) can still know which panel
    /// the user just lifted their finger off.
    private var lastPointingPanel: PanelKind?
    private var lastPointingPanelTime: TimeInterval = 0

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

    /// Iron-Man easter egg audio player. Held strongly so it isn't deallocated
    /// mid-playback. Reset to nil between plays so the user can re-trigger.
    private var daddysHomePlayer: AVAudioPlayer?
    /// Floating Stark holo cards spawned alongside the easter egg. Held so we
    /// can despawn them when the music tails off.
    private var starkHoloCards: [ModelEntity] = []

    /// Mach-time of the most recent `beginWorkspace` call. Used as a grace
    /// window for `startPlanning` so the welcome speech and any verbalized
    /// HUD labels ("let's start") can't auto-fire a build plan during the
    /// first few seconds of the AR session.
    private var workspaceStartedAt: TimeInterval?

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
        // Post-placement: check for preview panel interaction first.
        if let hitResult = arView.hitTest(point, query: .nearest, mask: .all).first,
           let kind = panelManager?.panelKind(for: hitResult.entity),
           kind == .preview,
           !session.currentCode.isEmpty {
            // "select" voice command armed → element selection. Otherwise default
            // to click-through (DOM .click() at the tapped point).
            if let webPoint = previewWebPoint(from: hitResult) {
                if selectionArmed {
                    handlePreviewSelect(at: webPoint)
                } else {
                    handlePreviewClick(at: webPoint)
                }
            }
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

    /// Shared world→panel-local→UV→web-pixel conversion for preview interactions.
    /// Returns nil if the hit fell outside the panel surface (defensive, the hit
    /// should already be on the panel for this call site).
    private func previewWebPoint(from hitResult: CollisionCastHit) -> CGPoint? {
        guard let panelManager = panelManager,
              let previewPanel = panelManager.panels[.preview] else { return nil }
        let hitWorld = hitResult.position
        let localPos = previewPanel.convert(position: hitWorld, from: nil)
        let halfW = previewPanel.widthMeters / 2
        let halfH = previewPanel.heightMeters / 2
        let u = (localPos.x + halfW) / previewPanel.widthMeters
        let v = (localPos.y + halfH) / previewPanel.heightMeters
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let webSize = PreviewRenderer.contentSize
        return CGPoint(x: CGFloat(u) * webSize.width, y: CGFloat(1 - v) * webSize.height)
    }

    /// Element-selection mode: outline the element under the tap, store it in
    /// session.selectedElement, and arm the next codegen call to scope the change
    /// to that element only.
    private func handlePreviewSelect(at webPoint: CGPoint) {
        previewRenderer.selectElement(at: webPoint) { [weak self] info, image in
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

    /// Click-through mode: synthesize a DOM click on whatever element is under
    /// the tap, then re-snapshot so any onclick mutations make it into the
    /// preview texture.
    private func handlePreviewClick(at webPoint: CGPoint) {
        appendTerminalLog(.command, "click @ (\(Int(webPoint.x)), \(Int(webPoint.y)))")
        previewRenderer.clickElement(at: webPoint) { [weak self] _, image in
            guard let self = self else { return }
            if let image = image {
                self.panelManager?.setPreviewImage(image)
            }
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

        // Defensive: a previous run may have left a stale plan in memory (e.g.
        // a planning request raced with app suspension). Always start the AR
        // workspace with a clean slate so the user never sees an unsolicited
        // "JUNIE EXECUTION PLAN" card on first launch.
        session.pendingPlan = nil
        session.isPlanning = false
        session.pendingPlanIsModification = false

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
            // Sticky tracker: remember the last non-nil pointed panel for the
            // swipe-routing window in handleSwipe.
            if let panel = panel {
                lastPointingPanel = panel
                lastPointingPanelTime = CACurrentMediaTime()
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

        // Tony-Stark "fling aside": open palm (5 fingers extended) + horizontal
        // swipe over a panel hides that panel. The gesture must still be
        // .openPalm at swipe time — it can't be the leftover state from a
        // pinch-grab. Triggers on left OR right; the closest panel to the
        // current wrist is what gets dismissed.
        if currentGesture == .openPalm,
           (direction == .left || direction == .right) {
            let panelToHide = lastPointingPanel
                ?? (lastWristNormalized.flatMap { closestPanelToScreenPoint($0) })
            if let panel = panelToHide {
                pm.hidePanel(panel)
                JarvisVoice.shared.speak("Dismissed.")
                return
            }
        }

        // Vertical swipes scroll the preview when the user is (or recently was)
        // pointing at it — otherwise they scroll the editor. The "recently"
        // window catches the common case where the user finishes pointing and
        // immediately swipes (gesture state already cleared).
        if direction == .up || direction == .down {
            let recentlyAtPreview = (CACurrentMediaTime() - lastPointingPanelTime) < 1.0
                && lastPointingPanel == .preview
            if (pointingPanel == .preview || recentlyAtPreview)
                && !session.currentCode.isEmpty
                && pm.isPanelVisible(.preview) {
                let dy: CGFloat = direction == .up ? 240 : -240
                previewRenderer.scrollBy(dy: dy) { [weak self] image in
                    guard let self = self, let image = image else { return }
                    self.panelManager?.setPreviewImage(image)
                }
                return
            }
        }

        switch direction {
        case .left, .right:
            pm.cycleEditorTab(forward: direction == .right)
        case .up:
            // Swipe up = scroll forward through the code (line numbers increase).
            // Matches iOS list-scrolling convention.
            pm.scrollEditor(by: 3)
        case .down:
            pm.scrollEditor(by: -3)
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
        // Voice-first users may speak before tapping "Let's start" — wake the
        // workspace up first so panels exist to receive their command.
        if !workspaceStarted {
            beginWorkspace()
        }
        switch command {
        case .codegen(let prompt):
            startPlanning(prompt: prompt)
        case .armWake:
            // Wake phrase fired with no body — JARVIS acknowledges so the user
            // knows their next utterance will be treated as a build prompt.
            JarvisVoice.shared.speak("Yes sir. What would you like to build?")
            appendTerminalLog(.info, "armed · awaiting prompt")
        case .confirm:
            confirmPendingPlan()
        case .cancel:
            cancelPendingPlan()
        case .skipStep(let n):
            skipPlanStep(n)
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
        case .goToPhoneIDE:
            // Leave AR. ContentView wires this callback to flip the top-level
            // phase back to the phone IDE. JARVIS acks first so the user knows
            // the swap is intentional and isn't a crash.
            JarvisVoice.shared.speak("Switching to the phone editor.")
            appendTerminalLog(.command, "exit ar → phone ide")
            onRequestPhoneMode?()
        case .daddysHome:
            playDaddysHomeEasterEgg()
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
        case .showConnections:
            showConnectionLines()
            JarvisVoice.shared.speak("Showing cross-file connections.")
        case .showTerry:
            panelManager?.showPanel(.terry)
            JarvisVoice.shared.speak("Bringing up Terry. The legend.")
            updateAIBubble(text: "Terry · classified", isUser: false)
        case .showDiff:
            showDiff()
        case .hide(let target):
            switch target {
            case .all:
                panelManager?.clearAll()
                panelManager?.hideGitTimeline()
                panelManager?.hideStatsRing()
                panelManager?.hideErrorMarkers()
                panelManager?.hideArchitectureGraph()
                panelManager?.hideDependenciesTree()
                hideConnectionLines()
                break // errorDetector removed
            case .preview:      panelManager?.hidePanel(.preview)
            case .docs:         panelManager?.hidePanel(.docs)
            case .terminal:     panelManager?.hidePanel(.terminal)
            case .terry:        panelManager?.hidePanel(.terry)
            case .git:          panelManager?.hideGitTimeline()
            case .errors:       panelManager?.hideErrorMarkers()
            case .stats:        panelManager?.hideStatsRing()
            case .architecture: panelManager?.hideArchitectureGraph()
            case .dependencies: panelManager?.hideDependenciesTree()
            case .connections:  hideConnectionLines()
            case .diff:         break // hideDiff() not yet implemented
            case .review:       break
            case .errorMarkers: break
            }
            JarvisVoice.shared.speak("Done.")
        case .clear:
            panelManager?.clearAll()
            panelManager?.hideGitTimeline()
            panelManager?.hideStatsRing()
            panelManager?.hideErrorMarkers()
            panelManager?.hideArchitectureGraph()
            panelManager?.hideDependenciesTree()
            hideConnectionLines()
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
        case .reviewCode:
            performCodeReview()
        case .ask(let question):
            // Route through regular Q&A
            updateAIBubble(text: "Thinking…", isUser: false)
            JarvisAssistant.shared.ask(question) { [weak self] result in
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

    /// Wake the workspace up: materialize the base panels (assistant → editor →
    /// file tree → terminal, staggered) and play the JARVIS welcome line.
    /// Idempotent. Called by the "Let's start" overlay tap, and as a safety
    /// net at the top of handleVoiceCommand so a voice-first user is never
    /// stuck on an empty desk.
    // MARK: - Plan / confirm / cancel pipeline
    //
    // The user's prompt now goes through a two-stage flow:
    //   1) `/api/plan` returns a summary + structured steps + an expanded
    //      hidden prompt. JARVIS reads the summary aloud, the AR plan overlay
    //      shows the steps, and the chat surfaces the same in the agent panel.
    //   2) The user says "yes / confirm" (or taps Confirm on the phone) →
    //      `/api/build` runs against the EXPANDED prompt, not the raw one.
    //      "no / cancel" discards the plan and frees Junie up.

    func startPlanning(prompt: String) {
        // Don't start a new plan if one is already pending awaiting confirmation.
        if session.pendingPlan != nil { return }
        // Drop self-feedback loops. The AR session uses .defaultToSpeaker so
        // JARVIS's TTS leaks back into the mic, and the open-palm PTT gesture
        // can auto-arm the recognizer at launch — so welcome lines and HUD
        // labels (e.g. "Let's start") get parsed as build prompts and silently
        // fire /api/plan. Filter aggressively: require enough length AND word
        // count, drop canned phrases, and gate the first few seconds after
        // workspace start so launch-time chatter never lands a plan.
        let cleanedLower = prompt
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let letterCount = cleanedLower.unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .count
        let wordCount = cleanedLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        guard letterCount >= 14, wordCount >= 3 else {
            appendTerminalLog(.info, "ignored short prompt: \(prompt)")
            return
        }
        // Post-launch grace window: no codegen for the first 6s after
        // `beginWorkspace`. Catches the welcome speech echoing back through
        // the mic AND the user verbally saying "let's start" while tapping
        // the placement HUD button — neither are real build intent.
        if let started = workspaceStartedAt, CACurrentMediaTime() - started < 6.0 {
            appendTerminalLog(.info, "ignored prompt during launch grace: \(prompt)")
            return
        }
        let jarvisEchoPhrases = [
            "hello sir", "what are we working on", "listening",
            "shall i proceed", "working on a plan", "on it", "done",
            "preview is live", "yes sir", "what would you like to build",
            "cancelled", "back to normal", "focus mode",
            "switching to dark mode", "going light",
            // HUD button / placement-screen labels that get verbally read out
            "let's start", "lets start", "let us start",
            "open arcreact", "introducing arcreact",
            "code anywhere", "even on your", "shake your phone",
            // "daddy's home" easter egg lines — must NOT trigger codegen
            "welcome home", "mister stark", "mr stark",
            "let's get cracking", "lets get cracking",
            "web development today", "with jetbrains"
        ]
        if jarvisEchoPhrases.contains(where: { cleanedLower.contains($0) }) {
            appendTerminalLog(.info, "ignored TTS/HUD echo: \(prompt)")
            return
        }
        let isModification = session.hasUserCode
        let trimmed = prompt.count > 64 ? String(prompt.prefix(64)) + "…" : prompt
        appendTerminalLog(.command, trimmed)
        appendTerminalLog(.info, "planning…")
        session.isPlanning = true
        session.pendingPlanIsModification = isModification
        JarvisVoice.shared.speak("Working on a plan, sir.")

        BackendClient.shared.plan(prompt: prompt,
                                  currentCode: isModification ? session.currentCode : nil,
                                  session: session) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.session.isPlanning = false
                switch result {
                case .success(let plan):
                    self.session.pendingPlan = plan
                    self.appendTerminalLog(.success, "plan ready · \(plan.steps.count) steps")
                    JarvisVoice.shared.speak(plan.summary)
                    // Brief breath, then the prompt — keeps the summary readable
                    // before "Shall I proceed?" stomps on it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if self.session.pendingPlan != nil {
                            JarvisVoice.shared.speak("Shall I proceed?")
                        }
                    }
                case .failure(let err):
                    self.session.pendingPlanIsModification = false
                    JarvisVoice.shared.speak("Planning failed, sir.")
                    self.appendTerminalLog(.error, "plan failed: \(err.localizedDescription)")
                }
            }
        }
    }

    func confirmPendingPlan() {
        guard let plan = session.pendingPlan else { return }
        let isModification = session.pendingPlanIsModification
        session.pendingPlan = nil
        session.pendingPlanIsModification = false
        session.isGenerating = true
        appendTerminalLog(.info, "executing plan…")
        JarvisVoice.shared.speak("On it.")
        let startTime = CACurrentMediaTime()

        let onResult: (Result<BackendClient.BuildResult, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.session.isGenerating = false
                switch result {
                case .success(let project):
                    self.session.applyProject(project,
                                              replace: !isModification,
                                              pushHistory: isModification)
                    if !isModification {
                        self.panelManager?.enterLiveIDEMode()
                        self.panelManager?.materializePreview()
                    }
                    let primaryCode = self.session.currentCode
                    self.panelManager?.setEditorCode(primaryCode, animated: !isModification)
                    self.panelManager?.setLiveFiles(active: self.session.currentFile,
                                                    files: Array(self.session.projectFiles.keys).sorted())
                    let elapsed = CACurrentMediaTime() - startTime
                    self.appendTerminalLog(.success,
                                           "\(isModification ? "updated" : "generated") \(project.stack) · \(project.files.count) files · \(String(format: "%.1f", elapsed))s")
                    // Preview the bundled HTML so JSX renders even though we
                    // can't run vite — falls back to the file's own contents
                    // for plain html projects.
                    self.loadAndApplyPreview(code: project.previewHtml,
                                             settleDelay: isModification ? 0.3 : 0.6) {
                        JarvisVoice.shared.speak(isModification ? "Done." : "Preview is live.")
                        self.appendTerminalLog(.success, "preview live")
                    }
                case .failure(let err):
                    JarvisVoice.shared.speak("Execution failed, sir.")
                    self.appendTerminalLog(.error, "execution failed: \(err.localizedDescription)")
                }
            }
        }

        if isModification {
            if let element = session.selectedElement {
                BackendClient.shared.modifyElement(prompt: plan.expandedPrompt,
                                                   files: session.projectFiles,
                                                   primary: session.currentFile,
                                                   element: element,
                                                   session: session,
                                                   completion: onResult)
            } else {
                BackendClient.shared.modify(prompt: plan.expandedPrompt,
                                            files: session.projectFiles,
                                            primary: session.currentFile,
                                            session: session,
                                            completion: onResult)
            }
        } else {
            BackendClient.shared.generate(prompt: plan.expandedPrompt,
                                          session: session,
                                          completion: onResult)
        }
    }

    /// Drop step `n` from the pending plan. Both 1-based step.id and 1-based
    /// position are accepted to be voice-command friendly.
    func skipPlanStep(_ n: Int) {
        guard var plan = session.pendingPlan else { return }
        let before = plan.steps.count
        plan = BackendClient.PlanPayload(
            summary: plan.summary,
            steps: plan.steps.filter { $0.id != n },
            expandedPrompt: plan.expandedPrompt
        )
        if plan.steps.count < before {
            session.pendingPlan = plan
            appendTerminalLog(.info, "skipped step \(n)")
            JarvisVoice.shared.speak("Step \(n) skipped.")
        } else {
            JarvisVoice.shared.speak("No step \(n) in this plan.")
        }
    }

    func cancelPendingPlan() {
        guard session.pendingPlan != nil else { return }
        session.pendingPlan = nil
        session.pendingPlanIsModification = false
        appendTerminalLog(.info, "plan cancelled")
        JarvisVoice.shared.speak("Cancelled.")
    }

    /// Scroll the AR preview WebView and refresh the preview panel texture.
    /// Called by the HUD's preview-scroll arrow buttons. Positive `dy` scrolls down.
    func scrollPreview(dy: CGFloat) {
        guard !session.currentCode.isEmpty else { return }
        previewRenderer.scrollBy(dy: dy) { [weak self] image in
            guard let self = self, let image = image else { return }
            self.panelManager?.setPreviewImage(image)
        }
    }

    /// True when there's a live preview to scroll (used to gate the HUD arrows).
    var hasLivePreview: Bool {
        !session.currentCode.isEmpty
    }

    func beginWorkspace() {
        guard !workspaceStarted else { return }
        workspaceStarted = true
        workspaceStartedAt = CACurrentMediaTime()
        // Phone IDE has already seeded an initial index.html (ArcReact splash)
        // — when AR wakes up, surface that into the editor panel + preview so
        // the live IDE flow has content to render from the first frame.
        if session.hasAnyCode {
            panelManager?.enterLiveIDEMode()
            panelManager?.materializePreview()
            panelManager?.setEditorCode(session.currentCode, animated: false)
            panelManager?.setLiveFiles(active: session.currentFile,
                                       files: Array(session.projectFiles.keys).sorted())
            loadAndApplyPreview(code: session.currentCode, settleDelay: 0.5)
        }
        panelManager?.materializeBasePanels()
        // Speak welcome a hair AFTER the assistant panel has begun materializing
        // so the bubble is visible while JARVIS talks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            JarvisVoice.shared.speak("Hello sir. What are we working on today?")
        }
    }

    /// "Daddy's home" easter egg — the Iron-Man tribute. The whole desk
    /// collapses to nothing, AC/DC kicks in, JARVIS greets Mr. Stark a beat
    /// later, then the workspace re-conjures with a hardcoded Stark-themed
    /// site loaded into the preview panel. Pure showmanship.
    private func playDaddysHomeEasterEgg() {
        appendTerminalLog(.command, "daddy's home 🦾")

        // 1) Collapse every panel. The base panels keep their `basePanelsMaterialized`
        //    flag set so we can't re-call materializeBasePanels — instead we
        //    re-animate each one individually.
        let allKinds: [PanelKind] = [.assistant, .editor, .fileTree, .terminal,
                                      .preview, .docs, .terry]
        for kind in allKinds {
            panelManager?.hidePanel(kind)
        }

        // 2) Spawn the Stark holo cards (arc reactor / helmet / vitals readout)
        //    so the workspace doesn't go totally empty during the music
        //    intro — three floating Marvel-esque AR HUD panels fill the void.
        spawnStarkHoloCards()

        // 3) Music. Bundled mp3 — falls back silently if the file is missing
        //    so the rest of the easter egg still fires.
        if let url = Bundle.main.url(forResource: "daddy_home", withExtension: "mp3") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.volume = 1.0
                player.play()
                daddysHomePlayer = player
            } catch {
                appendTerminalLog(.error, "daddy's home audio failed: \(error.localizedDescription)")
            }
        } else {
            appendTerminalLog(.error, "daddy_home.mp3 not bundled")
        }

        // 3) ~3.5s in — long enough for the AC/DC riff to land before
        //    JARVIS speaks over it. Duck the music gently (over 2s) so the
        //    transition into JARVIS isn't an abrupt cut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.fadeDaddysHomeMusic(to: 0.22, duration: 2.0)
            JarvisVoice.shared.speak("Welcome home, Mister Stark. Let's get cracking on some web development today, with JetBrains.")
        }

        // 4) Push the Stark-themed page into editor + preview, then re-conjure
        //    the panels in sync with the greeting. ~5.5s lets the AC/DC sting
        //    breathe before the workspace blooms back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self = self else { return }
            self.session.setCode(StarkTributePage.html,
                                 forFile: "stark.html",
                                 pushHistory: true,
                                 recordEdit: false,
                                 editType: "easter_egg")
            self.session.switchTo(file: "stark.html")
            // Mark the Stark page as throwaway demo content so the next user
            // prompt routes through generate() rather than modify(). Without
            // this, GPT gets fed the hardcoded Stark HTML as "current code"
            // and tries to mutate it instead of building what the user asked
            // for, which produces garbage output.
            self.session.markCurrentBufferAsDemo()
            self.panelManager?.setEditorCode(StarkTributePage.html, animated: true)
            self.panelManager?.setLiveFiles(active: "stark.html",
                                            files: Array(self.session.projectFiles.keys).sorted())
            let order: [(PanelKind, TimeInterval)] = [
                (.assistant, 0.00),
                (.editor,    0.18),
                (.terminal,  0.36),
                (.fileTree,  0.50),
                (.preview,   0.70),
            ]
            for (kind, delay) in order {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.panelManager?.showPanel(kind)
                }
            }
            self.loadAndApplyPreview(code: StarkTributePage.html, settleDelay: 0.8)
            self.appendTerminalLog(.success, "stark.html · workspace re-conjured")
        }

        // 5) Final fade-out — long, slow tail so the sting bleeds off into
        //    silence rather than getting yanked. ~6s of fade buys plenty of
        //    breathing room for JARVIS's line + the panel re-conjure
        //    animation to land before the music is fully gone. Stark holo
        //    cards despawn near the end of the fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            self?.fadeDaddysHomeMusic(to: 0.0, duration: 6.0) { [weak self] in
                self?.daddysHomePlayer?.stop()
                self?.daddysHomePlayer = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.0) { [weak self] in
            self?.clearStarkHoloCards()
        }
    }

    /// Spawn the three floating Stark holo cards (Arc Reactor / Helmet HUD /
    /// Vitals Readout) around the workspace, each with a staggered fade-in
    /// scale. Called at the start of the easter egg so they bloom in alongside
    /// the music.
    private func spawnStarkHoloCards() {
        guard let anchor = workspaceAnchor else { return }
        clearStarkHoloCards()

        // Three cards — each at a fixed world-space offset relative to the
        // workspace anchor so they float in a tight triptych in front of the
        // user. Sizes are in meters; positions are (x: right, y: up, z: forward).
        // Tightened from ±0.55m → ±0.26m so all three fit in a single camera
        // frame at the typical viewing distance.
        let cardSpecs: [(image: UIImage, position: SIMD3<Float>, size: SIMD2<Float>, delay: TimeInterval)] = [
            (drawArcReactorCard(),    SIMD3<Float>(-0.26,  0.32, -0.05), SIMD2<Float>(0.20, 0.28), 0.05),
            (drawStarkHelmetCard(),   SIMD3<Float>( 0.00,  0.40, -0.08), SIMD2<Float>(0.28, 0.21), 0.20),
            (drawVitalsReadoutCard(), SIMD3<Float>( 0.26,  0.32, -0.05), SIMD2<Float>(0.20, 0.28), 0.35),
        ]

        for spec in cardSpecs {
            guard let card = makeHoloCard(image: spec.image,
                                          width: spec.size.x,
                                          height: spec.size.y) else { continue }
            card.position = spec.position
            // Subtle inward yaw so each side card faces the user, not the air.
            let yaw: Float = spec.position.x < -0.05 ? .pi / 11
                            : spec.position.x >  0.05 ? -.pi / 11
                            : 0
            card.transform.rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            card.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(card)
            starkHoloCards.append(card)

            // Stagger the bloom — overshoot then settle, mirroring the panel
            // materialize animation.
            let target = Transform(scale: SIMD3<Float>(1.06, 1.06, 1.06),
                                   rotation: card.transform.rotation,
                                   translation: card.position)
            DispatchQueue.main.asyncAfter(deadline: .now() + spec.delay) { [weak card, weak anchor] in
                guard let card = card, let anchor = anchor else { return }
                card.move(to: target, relativeTo: anchor, duration: 0.55, timingFunction: .easeOut)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak card, weak anchor] in
                    guard let card = card, let anchor = anchor else { return }
                    let settle = Transform(scale: SIMD3<Float>(1, 1, 1),
                                           rotation: card.transform.rotation,
                                           translation: card.position)
                    card.move(to: settle, relativeTo: anchor, duration: 0.20, timingFunction: .easeIn)
                }
            }
        }
    }

    /// Despawn all Stark holo cards with a 0.4s shrink-out, then remove them
    /// from the scene graph and drop our strong refs.
    private func clearStarkHoloCards() {
        for card in starkHoloCards {
            let parent = card.parent
            let target = Transform(scale: SIMD3<Float>(0.001, 0.001, 0.001),
                                   rotation: card.transform.rotation,
                                   translation: card.transform.translation)
            card.move(to: target, relativeTo: parent, duration: 0.40, timingFunction: .easeIn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak card] in
                card?.parent?.removeChild(card!)
            }
        }
        starkHoloCards.removeAll()
    }

    /// Build a flat ModelEntity textured with `image`. Unlit + double-sided so
    /// it reads as a holographic card regardless of camera angle.
    private func makeHoloCard(image: UIImage, width: Float, height: Float) -> ModelEntity? {
        guard let cg = image.cgImage,
              let texture = try? TextureResource.generate(from: cg, options: .init(semantic: .color))
        else { return nil }
        var material = UnlitMaterial(color: .white)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let mesh = MeshResource.generatePlane(width: width, height: height)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        return entity
    }

    /// Card 1 — pulsing arc-reactor disc with "MK LXXXV" label. Drawn with
    /// Core Graphics so it has zero dependency on bundled assets.
    private func drawArcReactorCard() -> UIImage {
        let size = CGSize(width: 600, height: 840)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Background — deep void with hot-rod red corner glow.
            cg.setFillColor(UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            let glow = CGGradient(colorsSpace: nil,
                                  colors: [UIColor(red: 0.78, green: 0.07, blue: 0.13, alpha: 0.45).cgColor,
                                           UIColor.clear.cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawRadialGradient(glow,
                                  startCenter: CGPoint(x: size.width/2, y: size.height*0.42),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: size.width/2, y: size.height*0.42),
                                  endRadius: size.width*0.55, options: [])

            // Arc reactor — concentric rings with cyan core.
            let cx = size.width/2, cy = size.height*0.42
            let outer = CGRect(x: cx - 200, y: cy - 200, width: 400, height: 400)
            cg.setStrokeColor(UIColor(red: 0.49, green: 0.86, blue: 1, alpha: 0.6).cgColor)
            cg.setLineWidth(2)
            cg.strokeEllipse(in: outer)
            cg.setStrokeColor(UIColor(red: 0.49, green: 0.86, blue: 1, alpha: 0.85).cgColor)
            cg.setLineWidth(2.5)
            cg.strokeEllipse(in: outer.insetBy(dx: 32, dy: 32))
            cg.setStrokeColor(UIColor(red: 0.6, green: 0.92, blue: 1, alpha: 0.7).cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: outer.insetBy(dx: 64, dy: 64))

            // Core glow.
            let coreGradient = CGGradient(colorsSpace: nil,
                                          colors: [UIColor(red: 0.87, green: 0.98, blue: 1, alpha: 1).cgColor,
                                                   UIColor(red: 0.49, green: 0.86, blue: 1, alpha: 0.95).cgColor,
                                                   UIColor(red: 0.11, green: 0.36, blue: 0.55, alpha: 0.85).cgColor] as CFArray,
                                          locations: [0, 0.45, 1])!
            cg.drawRadialGradient(coreGradient,
                                  startCenter: CGPoint(x: cx, y: cy),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: cx, y: cy),
                                  endRadius: 130, options: [])

            // Spoke ticks — the 8 little radial dashes around a real arc reactor.
            cg.setStrokeColor(UIColor(red: 0.78, green: 0.95, blue: 1, alpha: 0.85).cgColor)
            cg.setLineWidth(3)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let x1 = cx + cos(a) * 145, y1 = cy + sin(a) * 145
                let x2 = cx + cos(a) * 175, y2 = cy + sin(a) * 175
                cg.move(to: CGPoint(x: x1, y: y1))
                cg.addLine(to: CGPoint(x: x2, y: y2))
                cg.strokePath()
            }

            // Top-left HUD label.
            let mono = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
            let red = UIColor(red: 1, green: 0.16, blue: 0.27, alpha: 1)
            ("// ARC REACTOR · ONLINE" as NSString)
                .draw(at: CGPoint(x: 36, y: 32),
                      withAttributes: [.font: mono, .foregroundColor: red])

            // Bottom MK badge.
            let bigDisplay = UIFont.systemFont(ofSize: 84, weight: .heavy)
            let mkText = "MK · LXXXV" as NSString
            let mkSize = mkText.size(withAttributes: [.font: bigDisplay])
            mkText.draw(at: CGPoint(x: (size.width - mkSize.width)/2, y: size.height - 220),
                        withAttributes: [.font: bigDisplay,
                                         .foregroundColor: UIColor.white])
            let sub = UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
            let subText = "BLEEDING-EDGE NANO ARMOR" as NSString
            let subSize = subText.size(withAttributes: [.font: sub])
            subText.draw(at: CGPoint(x: (size.width - subSize.width)/2, y: size.height - 130),
                         withAttributes: [.font: sub,
                                          .foregroundColor: UIColor(white: 0.65, alpha: 1)])

            // Corner brackets.
            drawCornerBrackets(in: cg, rect: CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18),
                               color: red, length: 28)
        }
    }

    /// Card 2 — wide Iron Man helmet silhouette with glowing eye slits and a
    /// targeting reticle. Centerpiece of the triptych.
    private func drawStarkHelmetCard() -> UIImage {
        let size = CGSize(width: 800, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Hot-rod red top fade → black bottom.
            let bgGrad = CGGradient(colorsSpace: nil,
                                    colors: [UIColor(red: 0.18, green: 0.02, blue: 0.04, alpha: 1).cgColor,
                                             UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor] as CFArray,
                                    locations: [0, 1])!
            cg.drawLinearGradient(bgGrad,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: size.height),
                                  options: [])

            // Helmet silhouette — stylized hexagonal mask shape.
            let cx = size.width/2, cy = size.height*0.55
            let helmet = UIBezierPath()
            helmet.move(to: CGPoint(x: cx - 130, y: cy - 150))
            helmet.addLine(to: CGPoint(x: cx + 130, y: cy - 150))
            helmet.addLine(to: CGPoint(x: cx + 175, y: cy - 60))
            helmet.addLine(to: CGPoint(x: cx + 165, y: cy + 90))
            helmet.addCurve(to: CGPoint(x: cx, y: cy + 175),
                            controlPoint1: CGPoint(x: cx + 140, y: cy + 160),
                            controlPoint2: CGPoint(x: cx + 70, y: cy + 175))
            helmet.addCurve(to: CGPoint(x: cx - 165, y: cy + 90),
                            controlPoint1: CGPoint(x: cx - 70, y: cy + 175),
                            controlPoint2: CGPoint(x: cx - 140, y: cy + 160))
            helmet.addLine(to: CGPoint(x: cx - 175, y: cy - 60))
            helmet.close()

            UIColor(red: 0.78, green: 0.07, blue: 0.13, alpha: 1).setFill()
            helmet.fill()
            // Helmet outline
            cg.setStrokeColor(UIColor(red: 0.96, green: 0.77, blue: 0.19, alpha: 1).cgColor)
            cg.setLineWidth(3)
            helmet.stroke()

            // Eye slits — angled trapezoids glowing white.
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 18,
                         color: UIColor(red: 1, green: 1, blue: 1, alpha: 0.95).cgColor)
            UIColor.white.setFill()
            let leftEye = UIBezierPath()
            leftEye.move(to: CGPoint(x: cx - 95, y: cy - 30))
            leftEye.addLine(to: CGPoint(x: cx - 28, y: cy - 32))
            leftEye.addLine(to: CGPoint(x: cx - 25, y: cy - 12))
            leftEye.addLine(to: CGPoint(x: cx - 90, y: cy - 8))
            leftEye.close()
            leftEye.fill()
            let rightEye = UIBezierPath()
            rightEye.move(to: CGPoint(x: cx + 28, y: cy - 32))
            rightEye.addLine(to: CGPoint(x: cx + 95, y: cy - 30))
            rightEye.addLine(to: CGPoint(x: cx + 90, y: cy - 8))
            rightEye.addLine(to: CGPoint(x: cx + 25, y: cy - 12))
            rightEye.close()
            rightEye.fill()
            cg.restoreGState()

            // Mouth grille — stylized horizontal bars.
            cg.setStrokeColor(UIColor(red: 0.96, green: 0.77, blue: 0.19, alpha: 0.85).cgColor)
            cg.setLineWidth(2)
            for i in 0..<3 {
                let y = cy + 80 + CGFloat(i) * 14
                cg.move(to: CGPoint(x: cx - 50, y: y))
                cg.addLine(to: CGPoint(x: cx + 50, y: y))
                cg.strokePath()
            }

            // Top label.
            let mono = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
            let red = UIColor(red: 1, green: 0.27, blue: 0.4, alpha: 1)
            ("// HALL OF ARMOR · BAY 04" as NSString)
                .draw(at: CGPoint(x: 32, y: 28),
                      withAttributes: [.font: mono, .foregroundColor: red])
            let topRight = "HUD · TARGETING" as NSString
            let trSize = topRight.size(withAttributes: [.font: mono])
            topRight.draw(at: CGPoint(x: size.width - trSize.width - 32, y: 28),
                          withAttributes: [.font: mono,
                                           .foregroundColor: UIColor(red: 1, green: 0.84, blue: 0.32, alpha: 1)])

            // Reticle ring around helmet center (subtle).
            cg.setStrokeColor(UIColor(red: 1, green: 0.84, blue: 0.32, alpha: 0.35).cgColor)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: CGRect(x: cx - 220, y: cy - 220, width: 440, height: 440))

            drawCornerBrackets(in: cg, rect: CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18),
                               color: red, length: 28)
        }
    }

    /// Card 3 — vertical HUD vitals stack ("REPULSORS ONLINE / FLIGHT READY /
    /// JARVIS SYNCED") plus a sweep waveform underneath.
    private func drawVitalsReadoutCard() -> UIImage {
        let size = CGSize(width: 600, height: 840)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            // Faint hot-rod red bottom glow.
            let glow = CGGradient(colorsSpace: nil,
                                  colors: [UIColor.clear.cgColor,
                                           UIColor(red: 0.78, green: 0.07, blue: 0.13, alpha: 0.4).cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawLinearGradient(glow, start: CGPoint(x: 0, y: size.height*0.4),
                                  end: CGPoint(x: 0, y: size.height), options: [])

            // Top label.
            let mono = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
            let red = UIColor(red: 1, green: 0.16, blue: 0.27, alpha: 1)
            ("// SYSTEMS · DIAGNOSTICS" as NSString)
                .draw(at: CGPoint(x: 32, y: 28),
                      withAttributes: [.font: mono, .foregroundColor: red])

            // Stacked vitals rows.
            let vitals: [(String, String, UIColor)] = [
                ("REPULSORS",  "ONLINE",   UIColor(red: 0.42, green: 0.85, blue: 0.5, alpha: 1)),
                ("FLIGHT",     "READY",    UIColor(red: 0.42, green: 0.85, blue: 0.5, alpha: 1)),
                ("JARVIS",     "SYNCED",   UIColor(red: 0.42, green: 0.85, blue: 0.5, alpha: 1)),
                ("ARC CORE",   "3.2 GW",   UIColor(red: 0.49, green: 0.86, blue: 1, alpha: 1)),
                ("VITALS",     "ALL GREEN",UIColor(red: 0.42, green: 0.85, blue: 0.5, alpha: 1)),
                ("THREATS",    "NONE",     UIColor(red: 0.96, green: 0.77, blue: 0.19, alpha: 1)),
            ]
            let labelFont = UIFont.systemFont(ofSize: 22, weight: .bold)
            let valueFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
            var y: CGFloat = 110
            for (label, value, color) in vitals {
                // Status dot.
                cg.setFillColor(color.cgColor)
                cg.fillEllipse(in: CGRect(x: 36, y: y + 8, width: 12, height: 12))
                // Label.
                (label as NSString).draw(at: CGPoint(x: 60, y: y),
                                         withAttributes: [.font: labelFont,
                                                          .foregroundColor: UIColor.white])
                // Value (right-aligned).
                let v = value as NSString
                let vSize = v.size(withAttributes: [.font: valueFont])
                v.draw(at: CGPoint(x: size.width - vSize.width - 36, y: y),
                       withAttributes: [.font: valueFont, .foregroundColor: color])
                // Divider.
                cg.setStrokeColor(UIColor(red: 0.78, green: 0.07, blue: 0.13, alpha: 0.35).cgColor)
                cg.setLineWidth(1)
                cg.move(to: CGPoint(x: 36, y: y + 44))
                cg.addLine(to: CGPoint(x: size.width - 36, y: y + 44))
                cg.strokePath()
                y += 70
            }

            // Waveform sweep at bottom.
            cg.setStrokeColor(UIColor(red: 0.49, green: 0.86, blue: 1, alpha: 0.85).cgColor)
            cg.setLineWidth(2)
            cg.beginPath()
            let waveTop: CGFloat = size.height - 180
            let waveBaseline = waveTop + 50
            cg.move(to: CGPoint(x: 36, y: waveBaseline))
            for x in stride(from: CGFloat(36), through: size.width - 36, by: 4) {
                let phase = (x / 30) * .pi
                let amp = sin(phase) * 18 + sin(phase * 1.7) * 8
                cg.addLine(to: CGPoint(x: x, y: waveBaseline + amp))
            }
            cg.strokePath()

            // Footer.
            let footerFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
            let footer = "// I AM IRON MAN" as NSString
            let fSize = footer.size(withAttributes: [.font: footerFont])
            footer.draw(at: CGPoint(x: (size.width - fSize.width)/2, y: size.height - 80),
                        withAttributes: [.font: footerFont,
                                         .foregroundColor: red])

            drawCornerBrackets(in: cg, rect: CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18),
                               color: red, length: 28)
        }
    }

    /// Stark-style L-shaped corner brackets — used on every holo card for
    /// consistent HUD chrome.
    private func drawCornerBrackets(in cg: CGContext, rect: CGRect, color: UIColor, length: CGFloat) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(2)
        let r = rect
        // Top-left
        cg.move(to: CGPoint(x: r.minX, y: r.minY + length))
        cg.addLine(to: CGPoint(x: r.minX, y: r.minY))
        cg.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        // Top-right
        cg.move(to: CGPoint(x: r.maxX - length, y: r.minY))
        cg.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        cg.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        // Bottom-right
        cg.move(to: CGPoint(x: r.maxX, y: r.maxY - length))
        cg.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        cg.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        // Bottom-left
        cg.move(to: CGPoint(x: r.minX + length, y: r.maxY))
        cg.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        cg.addLine(to: CGPoint(x: r.minX, y: r.maxY - length))
        cg.strokePath()
    }

    /// Smooth volume taper for the easter-egg player. Steps every 50ms so the
    /// fade reads as continuous; calls `completion` once the target volume is
    /// reached.
    private func fadeDaddysHomeMusic(to target: Float,
                                     duration: TimeInterval,
                                     completion: (() -> Void)? = nil) {
        guard let player = daddysHomePlayer else { completion?(); return }
        let steps = max(1, Int(duration / 0.05))
        let start = player.volume
        let delta = (target - start) / Float(steps)
        for i in 1...steps {
            let when = DispatchTime.now() + 0.05 * Double(i)
            DispatchQueue.main.asyncAfter(deadline: when) { [weak player] in
                guard let player = player else { return }
                player.volume = max(0, min(1, start + delta * Float(i)))
                if i == steps { completion?() }
            }
        }
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

    /// Perform an AI code review on the project files
    private func performCodeReview() {
        guard !session.projectFiles.isEmpty else {
            JarvisVoice.shared.speak("No code to review yet.")
            return
        }

        let summary = "Code review feature coming soon, sir."
        updateAIBubble(text: summary, isUser: false)
        JarvisVoice.shared.speak(summary)
        appendTerminalLog(.command, "code review requested")
    }

    /// Display 4 AR cards for the code review results. Spawns one ModelEntity
    /// per category in a 2×2 grid above the editor panels and stores them in
    /// `reviewCards` so a subsequent `clearReviewCards()` can despawn them.
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

        // OPEN-PALM = push-to-talk. Activate after 600ms of continuous palm so a brief
        // accidental flash of an open hand (e.g. user holding the phone with fingers
        // visible to the camera at startup) doesn't trigger it; deactivate 300ms
        // after the palm goes away so a frame of jittery detection doesn't cut
        // you off. The longer activation window also prevents the AR welcome
        // speech ("Hello sir. What are we working on today?") from being
        // captured as a build prompt via the speaker→mic feedback loop.
        let now = CACurrentMediaTime()
        if gesture == .openPalm {
            if palmFirstSeenAt == nil { palmFirstSeenAt = now }
            palmLastSeenAt = now
            if !pttGestureActive, now - (palmFirstSeenAt ?? now) > 0.6 {
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

// MARK: - Architecture visualization helpers

extension ARSessionManager {
    private func showConnectionLines() {
        guard let workspaceAnchor = workspaceAnchor, let arView = arView else { return }

        // Analyze code connections
        let connections = CodeAnalyzer.analyzeConnections(projectFiles: session.projectFiles)

        // Remove old entity if exists
        connectionLines?.removeFromParent()

        // Create new entity
        let entity = ConnectionLinesEntity()

        // Calculate node positions for the architecture graph
        let files = Array(session.projectFiles.keys).sorted()
        let radius: Float = 0.12
        var positions: [String: SIMD3<Float>] = [:]

        for (index, file) in files.enumerated() {
            let angle = Float(index) * .pi * 2 / Float(max(1, files.count))
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            positions[file] = SIMD3<Float>(x, 0, z)
        }

        entity.show(connections: connections, positions: positions)
        entity.position = SIMD3<Float>(0, 0.85, -0.40)
        workspaceAnchor.addChild(entity)
        connectionLines = entity

        session.isShowingConnections = true
    }

    private func hideConnectionLines() {
        connectionLines?.removeFromParent()
        connectionLines = nil
        session.isShowingConnections = false
    }

    private func showDiff() {
        guard let workspaceAnchor = workspaceAnchor else { return }

        // Hide existing diff if any
        hideDiff()

        // Create new diff view
        let diff = GitDiffView(session: session, filePath: session.currentFile)
        diff.rootEntity.position = SIMD3<Float>(0, 0.30, 0.20)
        workspaceAnchor.addChild(diff.rootEntity)
        diffView = diff

        session.isShowingDiff = true
        JarvisVoice.shared.speak("Showing diff.")
        appendTerminalLog(.command, "show diff")
    }

    private func hideDiff() {
        diffView?.tearDown()
        diffView = nil
        session.isShowingDiff = false
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

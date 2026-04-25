import Foundation
import RealityKit
import UIKit
import Combine
import simd

enum WorkspaceTheme {
    case dark, light
}

@MainActor
final class PanelManager {
    private(set) var panels: [PanelKind: PanelEntity] = [:]
    private weak var anchor: AnchorEntity?

    // editor state
    private var editorScrollOffset: Int = 0
    private var activeTab: Int = 0  // 0 = Login.tsx, 1 = App.tsx (cycle via swipe / voice)
    private var assistantText: String = "Listening..."
    private var assistantHighlight: ARSessionManager.BubbleHighlight = .none
    private(set) var theme: WorkspaceTheme = .dark
    private(set) var focusMode: Bool = false
    /// True after enterLiveIDEMode() has run. Idempotent guard so subsequent
    /// codegens don't re-trigger the layout-shift animation.
    private(set) var liveIDEModeActive: Bool = false
    /// True after materializeBasePanels() has run. Idempotent — the workspace
    /// only "wakes up" once.
    private(set) var basePanelsMaterialized: Bool = false

    // Phase 2 — live IDE state
    /// When non-nil, drawEditor renders these lines (with HTML/CSS/JS highlighting)
    /// instead of the hardcoded React snippet. nil = legacy demo placeholder.
    private var liveCode: String?
    /// When animating, only the first `animatedLineCount` lines of liveCode are shown.
    /// nil = full code visible.
    private var animatedLineCount: Int?
    private var lineAnimationTimer: Timer?
    /// Active filename + tab list, when the live file tree is in use.
    private var liveFiles: [String] = []
    private var liveActiveFile: String?
    /// Composited preview snapshot from PreviewRenderer. nil = legacy fake login form.
    private var previewImage: UIImage?
    /// Live terminal log, when set. nil = legacy hardcoded npm output.
    private var liveTerminal: [TerminalLine] = []
    private var liveTerminalActive: Bool = false

    // Holo elements (lazy-attached when their voice command fires)
    private var gitTimeline: GitTimelineEntity?
    private var statsRing: StatsRingEntity?
    private var errorMarkers: ErrorMarkersEntity?
    private var architectureGraph: ArchitectureGraphEntity?
    private var dependenciesTree: DependenciesTreeEntity?
    private var ambientCircle: AmbientCircleEntity?

    // Per-frame scene update subscription for animations
    private var sceneSubscription: Cancellable?

    func createPanels(on anchor: AnchorEntity) {
        self.anchor = anchor

        // Desk-anchored frame: +Y is up, +Z points toward the user (we yawed the anchor in
        // ARSessionManager so this holds). Y centers are set so each panel's BOTTOM edge
        // hovers ~3cm above the desk surface. Both the editor and preview are 56×40 cm
        // — a "two-page workspace" with the IDE on the left and the live preview on the
        // right, mirroring each other across the user's center of view. The standalone
        // file tree panel from Phase 1 is gone — file tree now lives as a sidebar inside
        // the IDE panel (see drawEditor).
        let editorPanel = makePanel(kind: .editor, width: 0.56, height: 0.40, isDark: false)
        editorPanel.position = SIMD3<Float>(-0.32, 0.30, 0.20)

        let terminalPanel = makePanel(kind: .terminal, width: 0.32, height: 0.16, isDark: true)
        terminalPanel.position = SIMD3<Float>(0, 0.10, 0.42)

        // Assistant bubble: a thin status bar high above the IDE+preview pair.
        let assistantPanel = makePanel(kind: .assistant, width: 0.50, height: 0.08, isDark: false)
        assistantPanel.position = SIMD3<Float>(0, 0.58, 0.10)

        // Tilt all "wall" panels ~15° so the top edge leans toward the user.
        let tiltAngle: Float = 15 * .pi / 180
        let tilt = simd_quatf(angle: tiltAngle, axis: SIMD3<Float>(1, 0, 0))
        for p in [editorPanel, terminalPanel, assistantPanel] {
            p.transform.rotation = tilt
            // Start every panel hidden + scaled to zero. They materialize via
            // materializeBasePanels() once the user taps "Let's start". This gives
            // an empty-desk first impression and a satisfying conjure animation.
            p.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            p.isEnabled = false
        }

        // Voice-activated panels — each gets its OWN dedicated zone so it never overlaps
        // the always-visible editor row. The user has to look around the workspace to see
        // them, which is the AR experience we want.
        //
        // Editor row footprint (no rotation/scale applied yet):
        //   file tree right edge ≈ -0.31, editor left/right ≈ ±0.25, terminal left edge ≈ +0.26.
        // Voice panels are pushed past those boundaries with a comfortable margin.

        // Preview mirrors the IDE on the right. Same size (56×40 cm), same y/z, opposite x.
        // enterLiveIDEMode() does final positioning for the live workflow but the initial
        // values here let "show preview" voice command (Phase 1) still work standalone.
        let previewPanel = makePanel(kind: .preview, width: 0.56, height: 0.40, isDark: false)
        previewPanel.position = SIMD3<Float>(0.32, 0.30, 0.20)
        previewPanel.transform.rotation = tilt
        previewPanel.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
        previewPanel.isEnabled = false

        // Docs: far left, beyond file tree. Width 0.36 → half 0.18. Right edge at -0.54.
        let docsPanel = makePanel(kind: .docs, width: 0.36, height: 0.34, isDark: false)
        docsPanel.position = SIMD3<Float>(-0.72, 0.20, -0.02)
        docsPanel.transform.rotation = tilt
        docsPanel.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
        docsPanel.isEnabled = false

        // Terry: front-and-center, well in front of the editor (z=+0.45) so it
        // pops toward the user without clipping anything in the editor row.
        let terryPanel = makePanel(kind: .terry, width: 0.30, height: 0.30, isDark: false)
        terryPanel.position = SIMD3<Float>(0, 0.22, 0.45)
        terryPanel.transform.rotation = tilt
        terryPanel.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
        terryPanel.isEnabled = false

        anchor.addChild(editorPanel)
        anchor.addChild(terminalPanel)
        anchor.addChild(assistantPanel)
        anchor.addChild(previewPanel)
        anchor.addChild(docsPanel)
        anchor.addChild(terryPanel)

        panels[.editor] = editorPanel
        panels[.terminal] = terminalPanel
        panels[.assistant] = assistantPanel
        panels[.preview] = previewPanel
        panels[.docs] = docsPanel
        panels[.terry] = terryPanel

        // Ambient circle on the desk surface — there from the start.
        let ambient = AmbientCircleEntity()
        ambient.position = SIMD3<Float>(0, 0.001, 0)
        anchor.addChild(ambient)
        ambientCircle = ambient

        refreshAllTextures()
    }

    // MARK: - Per-frame animation tick (scene update subscription)

    func attachSceneUpdates(arView: ARView) {
        sceneSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(deltaTime: Float(event.deltaTime))
        }
    }

    private func tick(deltaTime: Float) {
        gitTimeline?.tick(deltaTime: deltaTime)
        statsRing?.tick(deltaTime: deltaTime)
        errorMarkers?.tick(deltaTime: deltaTime)
        architectureGraph?.tick(deltaTime: deltaTime)
        ambientCircle?.tick(deltaTime: deltaTime)
    }

    // MARK: - Holo elements: show / hide

    func showGitTimeline() {
        guard let anchor = anchor else { return }
        if gitTimeline == nil {
            let g = GitTimelineEntity()
            // Assistant bar is now at y=0.49, so float the timeline higher.
            g.position = SIMD3<Float>(0, 0.62, -0.10)
            g.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(g)
            gitTimeline = g
        }
        if let g = gitTimeline {
            g.isEnabled = true
            g.move(to: Transform(scale: SIMD3<Float>(1, 1, 1), rotation: g.transform.rotation, translation: g.transform.translation),
                   relativeTo: g.parent, duration: 0.35, timingFunction: .easeOut)
        }
    }
    func hideGitTimeline() { collapseAndDisable(gitTimeline) }

    func showStatsRing() {
        guard let anchor = anchor else { return }
        if statsRing == nil {
            let s = StatsRingEntity()
            // Above-right of editor, beside the (now higher) assistant bar.
            s.position = SIMD3<Float>(0.42, 0.58, -0.05)
            s.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(s)
            statsRing = s
        }
        if let s = statsRing {
            s.isEnabled = true
            s.move(to: Transform(scale: SIMD3<Float>(1, 1, 1), rotation: s.transform.rotation, translation: s.transform.translation),
                   relativeTo: s.parent, duration: 0.40, timingFunction: .easeOut)
        }
    }
    func hideStatsRing() { collapseAndDisable(statsRing) }

    func showErrorMarkers() {
        guard let anchor = anchor else { return }
        if errorMarkers == nil {
            let e = ErrorMarkersEntity()
            // Anchored just to the right of the editor panel
            e.position = SIMD3<Float>(0.27, 0.21, 0.01)
            e.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(e)
            errorMarkers = e
        }
        if let e = errorMarkers {
            e.isEnabled = true
            e.move(to: Transform(scale: SIMD3<Float>(1, 1, 1), rotation: e.transform.rotation, translation: e.transform.translation),
                   relativeTo: e.parent, duration: 0.30, timingFunction: .easeOut)
        }
    }
    func hideErrorMarkers() { collapseAndDisable(errorMarkers) }

    func showArchitectureGraph() {
        guard let anchor = anchor else { return }
        if architectureGraph == nil {
            let a = ArchitectureGraphEntity()
            a.position = SIMD3<Float>(0, 0.65, -0.20)
            a.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(a)
            architectureGraph = a
        }
        if let a = architectureGraph {
            a.isEnabled = true
            a.move(to: Transform(scale: SIMD3<Float>(1, 1, 1), rotation: a.transform.rotation, translation: a.transform.translation),
                   relativeTo: a.parent, duration: 0.40, timingFunction: .easeOut)
        }
    }
    func hideArchitectureGraph() { collapseAndDisable(architectureGraph) }

    func showDependenciesTree() {
        guard let anchor = anchor else { return }
        if dependenciesTree == nil {
            let d = DependenciesTreeEntity()
            d.position = SIMD3<Float>(-0.55, 0.50, -0.05)
            d.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)
            anchor.addChild(d)
            dependenciesTree = d
        }
        if let d = dependenciesTree {
            d.isEnabled = true
            d.move(to: Transform(scale: SIMD3<Float>(1, 1, 1), rotation: d.transform.rotation, translation: d.transform.translation),
                   relativeTo: d.parent, duration: 0.35, timingFunction: .easeOut)
        }
    }
    func hideDependenciesTree() { collapseAndDisable(dependenciesTree) }

    private func collapseAndDisable(_ entity: Entity?) {
        guard let entity = entity, entity.isEnabled else { return }
        let target = Transform(scale: SIMD3<Float>(0.001, 0.001, 0.001),
                               rotation: entity.transform.rotation,
                               translation: entity.transform.translation)
        entity.move(to: target, relativeTo: entity.parent, duration: 0.30, timingFunction: .easeIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak entity] in
            entity?.isEnabled = false
        }
    }

    // MARK: - Modes

    func setFocusMode(_ on: Bool) {
        focusMode = on
        let dim: Float = on ? 0.10 : 1.0
        for (kind, panel) in panels {
            // Editor stays at full opacity in focus mode.
            let target: Float = (kind == .editor) ? 1.0 : dim
            panel.setOpacity(target)
        }
        let ambientDim: Float = on ? 0.15 : 1.0
        ambientCircle?.setOpacity(ambientDim)
    }

    func setTheme(_ newTheme: WorkspaceTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        refreshAllTextures()
    }

    // MARK: Show / hide animation
    private static let voicePanels: Set<PanelKind> = [.preview, .docs, .terminal, .terry]

    func showPanel(_ kind: PanelKind) {
        guard let panel = panels[kind] else { return }
        panel.isEnabled = true
        let target = Transform(scale: SIMD3<Float>(1, 1, 1),
                               rotation: panel.transform.rotation,
                               translation: panel.transform.translation)
        panel.move(to: target, relativeTo: panel.parent, duration: 0.35, timingFunction: .easeOut)
    }

    func hidePanel(_ kind: PanelKind) {
        guard let panel = panels[kind] else { return }
        let target = Transform(scale: SIMD3<Float>(0.001, 0.001, 0.001),
                               rotation: panel.transform.rotation,
                               translation: panel.transform.translation)
        panel.move(to: target, relativeTo: panel.parent, duration: 0.30, timingFunction: .easeIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak panel] in
            panel?.isEnabled = false
        }
    }

    /// Hide all voice-activated panels (preview, docs, terminal). Editor / file tree /
    /// assistant stay because they're the workspace's permanent fixtures.
    func clearAll() {
        for kind in PanelManager.voicePanels {
            hidePanel(kind)
        }
    }

    func isPanelVisible(_ kind: PanelKind) -> Bool {
        guard let panel = panels[kind] else { return false }
        return panel.isEnabled && panel.transform.scale.x > 0.5
    }

    func togglePanel(_ kind: PanelKind) {
        if isPanelVisible(kind) { hidePanel(kind) } else { showPanel(kind) }
    }

    private func makePanel(kind: PanelKind, width: Float, height: Float, isDark: Bool) -> PanelEntity {
        let texture = renderTexture(for: kind, widthMeters: width, heightMeters: height)
        return PanelEntity(kind: kind, width: width, height: height, texture: texture, isDark: isDark)
    }

    func panelKind(for entity: Entity) -> PanelKind? {
        var current: Entity? = entity
        while let e = current {
            if let panel = e as? PanelEntity { return panel.kind }
            current = e.parent
        }
        return nil
    }

    struct PanelWorldInfo {
        let position: SIMD3<Float>
        let distance: Float
    }

    func panelWorldPosition(_ kind: PanelKind) -> (position: SIMD3<Float>, distance: Float)? {
        guard let panel = panels[kind] else { return nil }
        let world = panel.position(relativeTo: nil)
        return (world, simd_length(world))
    }

    func setHoverHighlight(_ kind: PanelKind?) {
        for (k, p) in panels {
            p.setHovered(k == kind)
        }
    }

    func setGrabbed(_ kind: PanelKind?) {
        for (k, p) in panels {
            p.setGrabbed(k == kind)
        }
    }

    func movePanel(_ kind: PanelKind, toWorldPosition world: SIMD3<Float>) {
        guard let panel = panels[kind], let anchor = anchor else { return }
        let local = anchor.convert(position: world, from: nil)
        panel.position = local
    }

    func panelLocalPosition(_ kind: PanelKind) -> SIMD3<Float>? {
        panels[kind]?.position
    }

    func setPanelLocalPosition(_ kind: PanelKind, position: SIMD3<Float>) {
        panels[kind]?.position = position
    }

    func panelScale(_ kind: PanelKind) -> Float? {
        panels[kind]?.transform.scale.x
    }

    func setPanelScale(_ kind: PanelKind, scale: Float) {
        panels[kind]?.transform.scale = SIMD3<Float>(scale, scale, 1)
    }

    /// Returns the four panel corners in screen space (TL, TR, BL, BR), already accounting for scale.
    func panelCornersScreen(_ kind: PanelKind, in arView: ARView?) -> [CGPoint]? {
        guard let arView = arView, let panel = panels[kind] else { return nil }
        let halfW = panel.widthMeters / 2
        let halfH = panel.heightMeters / 2
        let local: [SIMD3<Float>] = [
            SIMD3<Float>(-halfW,  halfH, 0),  // TL
            SIMD3<Float>( halfW,  halfH, 0),  // TR
            SIMD3<Float>(-halfW, -halfH, 0),  // BL
            SIMD3<Float>( halfW, -halfH, 0),  // BR
        ]
        // panel.convert applies scale + rotation + position transformation.
        let projected = local.compactMap { p -> CGPoint? in
            let world = panel.convert(position: p, to: nil)
            return arView.project(world)
        }
        return projected.count == 4 ? projected : nil
    }

    func setSelected(_ kind: PanelKind?) {
        for (k, p) in panels {
            p.setSelected(k == kind)
        }
    }

    func cycleEditorTab(forward: Bool) {
        activeTab = (activeTab + (forward ? 1 : -1) + 2) % 2
        regenerateEditor()
    }

    func scrollEditor(by lines: Int) {
        // Clamp to the actual code length when in live mode; fall back to a fixed cap
        // for the Phase 1 hardcoded snippet.
        let upperBound: Int
        if let live = liveCode {
            let total = live.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            // ~22 visible lines is what the editor draws by default; leave one as
            // headroom so the last line of code is never alone at the top.
            upperBound = Swift.max(0, total - 22)
        } else {
            upperBound = 20
        }
        editorScrollOffset = Swift.max(0, Swift.min(upperBound, editorScrollOffset + lines))
        regenerateEditor()
    }

    func updateAssistant(text: String, highlight: ARSessionManager.BubbleHighlight) {
        self.assistantText = text
        self.assistantHighlight = highlight
        regenerateAssistant()
    }

    // MARK: - Phase 2 live setters

    /// Set the live editor code. If `animated`, reveal it line by line at 80ms/line.
    /// On a fresh animation we cancel any in-flight one. Scroll offset is reset so
    /// the user sees the new code from line 1.
    func setEditorCode(_ code: String, animated: Bool) {
        lineAnimationTimer?.invalidate()
        lineAnimationTimer = nil
        liveCode = code
        editorScrollOffset = 0

        if animated {
            let total = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            animatedLineCount = 0
            regenerateEditor()
            // 0.15s/line — enough to feel like typing, low enough that the editor
            // texture redraw (~12ms at 2500ppm) doesn't starve the main thread.
            // The Timer's `block:` already runs on the runloop's thread (we add
            // it to .main below), so no Task @MainActor wrapper is needed.
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self = self else { timer.invalidate(); return }
                    let count = (self.animatedLineCount ?? 0) + 1
                    if count >= total {
                        self.animatedLineCount = nil
                        self.regenerateEditor()
                        timer.invalidate()
                        self.lineAnimationTimer = nil
                    } else {
                        self.animatedLineCount = count
                        self.regenerateEditor()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            lineAnimationTimer = timer
        } else {
            animatedLineCount = nil
            regenerateEditor()
        }
    }

    /// Composite a fresh preview snapshot into the preview panel chrome.
    func setPreviewImage(_ image: UIImage?) {
        previewImage = image
        regeneratePreview()
    }

    /// Switch the workspace into the two-page live workflow: IDE on the left,
    /// preview on the right (mirror), terminal centered below them. The IDE and
    /// preview both stay at full scale — no shrinking. Idempotent.
    func enterLiveIDEMode() {
        guard !liveIDEModeActive else { return }
        liveIDEModeActive = true

        let dur: TimeInterval = 0.55

        // IDE panel: front-left at full size.
        if let editor = panels[.editor], let parent = editor.parent {
            let target = Transform(
                scale: SIMD3<Float>(1, 1, 1),
                rotation: editor.transform.rotation,
                translation: SIMD3<Float>(-0.32, 0.30, 0.20)
            )
            editor.move(to: target, relativeTo: parent, duration: dur, timingFunction: .easeInOut)
        }

        // Terminal: centered below the IDE/preview pair, pushed forward so it
        // reads as a desk-level inspector rather than a wall panel.
        if let terminal = panels[.terminal], let parent = terminal.parent {
            let target = Transform(
                scale: SIMD3<Float>(1, 1, 1),
                rotation: terminal.transform.rotation,
                translation: SIMD3<Float>(0, 0.10, 0.42)
            )
            terminal.move(to: target, relativeTo: parent, duration: dur, timingFunction: .easeInOut)
        }

        // Preview: front-right (mirror of IDE). Reposition only — show animation
        // runs separately via materializePreview().
        if let preview = panels[.preview] {
            preview.position = SIMD3<Float>(0.32, 0.30, 0.20)
        }
    }

    /// First-run "wake up" animation: bring the four base panels (assistant first,
    /// then editor, file tree, terminal) up from zero with a staggered overshoot,
    /// each ~150ms after the previous so it reads as JARVIS conjuring the
    /// workspace into being. Idempotent.
    func materializeBasePanels() {
        guard !basePanelsMaterialized else { return }
        basePanelsMaterialized = true

        // Order matters — assistant first because that's where JARVIS "speaks" from,
        // then the editor as the centerpiece, then the supporting panels.
        let order: [(PanelKind, TimeInterval)] = [
            (.assistant, 0.00),
            (.editor,    0.18),
            (.terminal,  0.36),
        ]
        for (kind, delay) in order {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.materializePanel(kind)
            }
        }
    }

    /// Two-stage scale animation reused by materializeBasePanels and the
    /// preview's first show. 0 → 1.06 → 1.0, ~0.75s total.
    private func materializePanel(_ kind: PanelKind) {
        guard let panel = panels[kind], let parent = panel.parent else { return }
        panel.isEnabled = true
        panel.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)

        let baseRotation = panel.transform.rotation
        let basePosition = panel.transform.translation

        let stage1 = Transform(
            scale: SIMD3<Float>(1.06, 1.06, 1.06),
            rotation: baseRotation,
            translation: basePosition
        )
        panel.move(to: stage1, relativeTo: parent, duration: 0.55, timingFunction: .easeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak panel] in
            guard let panel = panel, let parent = panel.parent else { return }
            let stage2 = Transform(
                scale: SIMD3<Float>(1, 1, 1),
                rotation: panel.transform.rotation,
                translation: panel.transform.translation
            )
            panel.move(to: stage2, relativeTo: parent, duration: 0.20, timingFunction: .easeIn)
        }
    }

    /// Materialize the preview panel: scale 0.001 → 1.06 (overshoot, easeOut) →
    /// 1.0 (settle, easeIn). Replaces a flat showPanel(.preview) when fresh code
    /// has just been generated — feels like the page is conjuring itself.
    func materializePreview() {
        guard let preview = panels[.preview], let parent = preview.parent else { return }

        // Reset to invisible scale so the animation always plays from zero, even if
        // the panel was previously visible.
        preview.isEnabled = true
        preview.transform.scale = SIMD3<Float>(0.001, 0.001, 0.001)

        let baseRotation = preview.transform.rotation
        let basePosition = preview.transform.translation

        let stage1 = Transform(
            scale: SIMD3<Float>(1.06, 1.06, 1.06),
            rotation: baseRotation,
            translation: basePosition
        )
        preview.move(to: stage1, relativeTo: parent, duration: 0.55, timingFunction: .easeOut)

        // Stage 2 fires after stage 1 finishes — shrinks the slight overshoot back
        // to natural size for a tactile "settle" feel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak preview] in
            guard let preview = preview, let parent = preview.parent else { return }
            let stage2 = Transform(
                scale: SIMD3<Float>(1, 1, 1),
                rotation: preview.transform.rotation,
                translation: preview.transform.translation
            )
            preview.move(to: stage2, relativeTo: parent, duration: 0.20, timingFunction: .easeIn)
        }
    }

    /// Update the file list shown in the IDE's left sidebar. Active file is
    /// highlighted in cyan. (The standalone file tree panel from Phase 1 is
    /// gone — files now render inside the editor panel itself.)
    func setLiveFiles(active: String, files: [String]) {
        liveActiveFile = active
        liveFiles = files
        regenerateEditor()
    }

    /// Switch the terminal to live mode and render the given log lines.
    func setTerminalLog(_ lines: [TerminalLine]) {
        liveTerminalActive = true
        liveTerminal = lines
        regenerateTerminal()
    }

    private func refreshAllTextures() {
        regenerateEditor()
        regenerateTerminal()
        regenerateAssistant()
    }

    private func regenerateEditor() {
        guard let panel = panels[.editor] else { return }
        if let texture = renderTexture(for: .editor, widthMeters: panel.widthMeters, heightMeters: panel.heightMeters) {
            panel.updateTexture(texture)
        }
    }

    private func regenerateFileTree() {
        guard let panel = panels[.fileTree] else { return }
        if let texture = renderTexture(for: .fileTree, widthMeters: panel.widthMeters, heightMeters: panel.heightMeters) {
            panel.updateTexture(texture)
        }
    }

    private func regenerateTerminal() {
        guard let panel = panels[.terminal] else { return }
        if let texture = renderTexture(for: .terminal, widthMeters: panel.widthMeters, heightMeters: panel.heightMeters) {
            panel.updateTexture(texture)
        }
    }

    private func regenerateAssistant() {
        guard let panel = panels[.assistant] else { return }
        if let texture = renderTexture(for: .assistant, widthMeters: panel.widthMeters, heightMeters: panel.heightMeters) {
            panel.updateTexture(texture)
        }
    }

    private func regeneratePreview() {
        guard let panel = panels[.preview] else { return }
        if let texture = renderTexture(for: .preview, widthMeters: panel.widthMeters, heightMeters: panel.heightMeters) {
            panel.updateTexture(texture)
        }
    }

    // MARK: Texture rendering
    private func renderTexture(for kind: PanelKind, widthMeters: Float, heightMeters: Float) -> TextureResource? {
        // 2500 px/m keeps panels sharp at the ~50cm viewing distance the workspace
        // sits at, while costing ~3× less CPU per redraw than the original 4500
        // ppm. The typing animation regenerates the editor texture every tick, and
        // at 4500 ppm a 0.50×0.36m editor was 3.6M pixels per redraw — enough to
        // saturate the main thread and starve ARKit of camera frames (the
        // "ARSession is retaining N ARFrames" warnings in the console).
        let pixelsPerMeter: CGFloat = 2500
        let size = CGSize(width: max(256, CGFloat(widthMeters) * pixelsPerMeter),
                          height: max(128, CGFloat(heightMeters) * pixelsPerMeter))
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1
            f.opaque = false
            return f
        }())
        let image = renderer.image { ctx in
            switch kind {
            case .editor: drawEditor(in: ctx.cgContext, size: size)
            case .fileTree: drawFileTree(in: ctx.cgContext, size: size)
            case .terminal: drawTerminal(in: ctx.cgContext, size: size)
            case .assistant: drawAssistant(in: ctx.cgContext, size: size)
            case .preview: drawPreview(in: ctx.cgContext, size: size)
            case .docs: drawDocs(in: ctx.cgContext, size: size)
            case .terry: drawTerry(in: ctx.cgContext, size: size)
            }
        }
        guard let cg = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
    }

    // MARK: JARVIS palette + chrome (theme-aware)
    private struct JarvisPalette {
        let bg: UIColor
        let bgDarker: UIColor
        let cyan: UIColor
        let cyanDim: UIColor
        let cyanFaint: UIColor
        let lightBlue: UIColor
        let textPrimary: UIColor
        let textDim: UIColor
        let scanLine: UIColor
        let synKeyword: UIColor
        let synFunction: UIColor
        let synString: UIColor
        let synJSX: UIColor
        let synNormal: UIColor
        let synLineNum: UIColor
    }

    private static let darkPalette = JarvisPalette(
        bg:          UIColor(red:  8/255, green: 12/255, blue: 20/255, alpha: 0.65),
        bgDarker:    UIColor(red:  4/255, green:  7/255, blue: 12/255, alpha: 0.72),
        cyan:        UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 1.0),
        cyanDim:     UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 0.55),
        cyanFaint:   UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 0.18),
        lightBlue:   UIColor(red: 88/255, green: 166/255, blue: 255/255, alpha: 1.0),
        textPrimary: UIColor(red: 230/255, green: 240/255, blue: 250/255, alpha: 1.0),
        textDim:     UIColor(red: 120/255, green: 145/255, blue: 180/255, alpha: 1.0),
        scanLine:    UIColor(red:   0,    green: 212/255, blue: 255/255, alpha: 0.10),
        synKeyword:  UIColor(red: 1.00, green: 0.48, blue: 0.71, alpha: 1),
        synFunction: UIColor(red: 0.70, green: 0.57, blue: 0.94, alpha: 1),
        synString:   UIColor(red: 0.34, green: 0.85, blue: 0.91, alpha: 1),
        synJSX:      UIColor(red: 0.43, green: 1.00, blue: 0.69, alpha: 1),
        synNormal:   UIColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1),
        synLineNum:  UIColor(red: 0.34, green: 0.40, blue: 0.50, alpha: 1)
    )

    private static let lightPalette = JarvisPalette(
        bg:          UIColor(red: 245/255, green: 248/255, blue: 252/255, alpha: 0.78),
        bgDarker:    UIColor(red: 235/255, green: 240/255, blue: 248/255, alpha: 0.85),
        cyan:        UIColor(red:   0,    green: 122/255, blue: 180/255, alpha: 1.0),
        cyanDim:     UIColor(red:   0,    green: 122/255, blue: 180/255, alpha: 0.65),
        cyanFaint:   UIColor(red:   0,    green: 122/255, blue: 180/255, alpha: 0.22),
        lightBlue:   UIColor(red: 38/255, green: 96/255,  blue: 180/255, alpha: 1.0),
        textPrimary: UIColor(red: 12/255, green: 18/255,  blue: 28/255,  alpha: 1.0),
        textDim:     UIColor(red: 90/255, green: 105/255, blue: 130/255, alpha: 1.0),
        scanLine:    UIColor(red:   0,    green: 122/255, blue: 180/255, alpha: 0.06),
        synKeyword:  UIColor(red: 0.78, green: 0.13, blue: 0.46, alpha: 1),
        synFunction: UIColor(red: 0.46, green: 0.27, blue: 0.78, alpha: 1),
        synString:   UIColor(red: 0.10, green: 0.50, blue: 0.62, alpha: 1),
        synJSX:      UIColor(red: 0.08, green: 0.55, blue: 0.32, alpha: 1),
        synNormal:   UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1),
        synLineNum:  UIColor(red: 0.65, green: 0.70, blue: 0.77, alpha: 1)
    )

    private var Jarvis: JarvisPalette { theme == .dark ? PanelManager.darkPalette : PanelManager.lightPalette }

    private func drawJarvisBackground(_ ctx: CGContext, size: CGSize, dark: Bool = false) {
        (dark ? Jarvis.bgDarker : Jarvis.bg).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        drawScanLines(ctx, size: size)
    }

    private func drawScanLines(_ ctx: CGContext, size: CGSize) {
        ctx.setStrokeColor(Jarvis.scanLine.cgColor)
        ctx.setLineWidth(1)
        let spacing: CGFloat = max(6, size.height / 90)
        var y: CGFloat = 0
        while y < size.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            ctx.strokePath()
            y += spacing
        }
    }

    private func drawCornerBrackets(_ ctx: CGContext, size: CGSize, color: UIColor? = nil, lineWidth: CGFloat = 2.5) {
        let color = color ?? Jarvis.cyan
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        let bracket = min(size.width, size.height) * 0.06
        let pad: CGFloat = max(8, min(size.width, size.height) * 0.012)

        func L(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c); ctx.strokePath()
        }
        L(CGPoint(x: pad,                  y: pad + bracket),
          CGPoint(x: pad,                  y: pad),
          CGPoint(x: pad + bracket,        y: pad))
        L(CGPoint(x: size.width - pad - bracket, y: pad),
          CGPoint(x: size.width - pad,           y: pad),
          CGPoint(x: size.width - pad,           y: pad + bracket))
        L(CGPoint(x: pad,                  y: size.height - pad - bracket),
          CGPoint(x: pad,                  y: size.height - pad),
          CGPoint(x: pad + bracket,        y: size.height - pad))
        L(CGPoint(x: size.width - pad - bracket, y: size.height - pad),
          CGPoint(x: size.width - pad,           y: size.height - pad),
          CGPoint(x: size.width - pad,           y: size.height - pad - bracket))

        // Tiny inner-corner marker dots
        ctx.setFillColor(color.cgColor)
        let dotR: CGFloat = 2.2
        for p in [CGPoint(x: pad + bracket + 6,            y: pad + bracket + 6),
                  CGPoint(x: size.width - pad - bracket - 6, y: pad + bracket + 6),
                  CGPoint(x: pad + bracket + 6,            y: size.height - pad - bracket - 6),
                  CGPoint(x: size.width - pad - bracket - 6, y: size.height - pad - bracket - 6)] {
            ctx.fillEllipse(in: CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2))
        }

        // Hex marker top-center, triangle bottom-center
        drawHexagon(ctx, center: CGPoint(x: size.width / 2, y: pad + 2), radius: 5, color: color)
        drawDownTriangle(ctx, center: CGPoint(x: size.width / 2, y: size.height - pad - 2), radius: 5, color: color)
    }

    private func drawHexagon(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: UIColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        let path = CGMutablePath()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 6
            let x = center.x + cos(a) * radius
            let y = center.y + sin(a) * radius
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawDownTriangle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: UIColor) {
        ctx.setFillColor(color.cgColor)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - radius, y: center.y - radius * 0.6))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius * 0.6))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 0.6))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func drawSystemReadout(_ ctx: CGContext, size: CGSize, extra: String? = nil) {
        let fontSize = max(8, size.height * 0.018)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let parts = ["SYS:ACTIVE", "MEM:847MB", "PROC:12"] + (extra.map { [$0] } ?? [])
        let text = parts.joined(separator: "   ")
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Jarvis.cyanDim,
            .kern: 1.4
        ])
        let w = attr.size().width
        let pad = max(12, min(size.width, size.height) * 0.025)
        attr.draw(at: CGPoint(x: (size.width - w) / 2, y: size.height - fontSize - pad - 4))

        // Top-left status tag
        let tag = NSAttributedString(string: "◉ LIVE", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: Jarvis.cyan,
            .kern: 1.4
        ])
        tag.draw(at: CGPoint(x: pad + 18, y: pad - 2))
    }

    // MARK: Editor renderer
    /// VS Code-style IDE renderer: file tree sidebar on the left, tab bar + code on
    /// the right. Preserves the JARVIS holographic theme (corner brackets, scan
    /// lines, cyan accents) but reorganises the layout to feel like a real IDE
    /// rather than a single-column text dump. Backwards-compatible with Phase 1:
    /// when `liveCode` is nil, it shows the original React snippet on the right
    /// and a default file list on the left.
    private func drawEditor(in ctx: CGContext, size: CGSize) {
        drawJarvisBackground(ctx, size: size)

        let outerPad = max(20, min(size.width, size.height) * 0.04)

        // Layout: left sidebar (~22% width) | vertical separator | code area
        let sidebarWidth = (size.width - outerPad * 2) * 0.22
        let separatorX = outerPad + sidebarWidth + 14
        let codeAreaLeft = separatorX + 14
        let workTop = outerPad + 6
        let workBottom = size.height - max(40, size.height * 0.06)  // room for system readout

        // Sidebar background: 6% darker tint than the main panel bg so the two
        // halves read as distinct without screaming.
        let sidebarBg = (theme == .dark
            ? UIColor(red:  4/255, green:  7/255, blue: 14/255, alpha: 0.55)
            : UIColor(red: 232/255, green: 238/255, blue: 248/255, alpha: 0.55))
        sidebarBg.setFill()
        ctx.fill(CGRect(x: outerPad, y: workTop, width: sidebarWidth, height: workBottom - workTop))

        // Vertical separator (cyan, soft).
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: separatorX, y: workTop))
        ctx.addLine(to: CGPoint(x: separatorX, y: workBottom))
        ctx.strokePath()

        // ---- Sidebar: EXPLORER label + file rows ----------------------------
        let sidebarFontSize = max(11, size.height * 0.026)
        let sidebarLabelFontSize = max(11, size.height * 0.022)
        let labelFont = UIFont.systemFont(ofSize: sidebarLabelFontSize, weight: .semibold)
        let fileFont = UIFont.monospacedSystemFont(ofSize: sidebarFontSize, weight: .regular)

        var sy: CGFloat = workTop + 14
        NSAttributedString(string: "EXPLORER", attributes: [
            .font: labelFont,
            .foregroundColor: Jarvis.cyan,
            .kern: 2.6
        ]).draw(at: CGPoint(x: outerPad + 14, y: sy))
        sy += sidebarLabelFontSize * 2.0

        // Faint horizontal divider under the section header.
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: outerPad + 8, y: sy - 6))
        ctx.addLine(to: CGPoint(x: outerPad + sidebarWidth - 8, y: sy - 6))
        ctx.strokePath()

        // Resolve which files to show + which is active.
        let sidebarFiles: [String]
        let activeFile: String?
        if !liveFiles.isEmpty, let active = liveActiveFile {
            sidebarFiles = liveFiles
            activeFile = active
        } else if let live = liveActiveFile {
            sidebarFiles = [live]
            activeFile = live
        } else {
            sidebarFiles = ["Login.tsx", "App.tsx", "index.css", "utils.ts"]
            activeFile = "Login.tsx"
        }

        for file in sidebarFiles {
            let isActive = (file == activeFile)
            let rowH = sidebarFontSize * 1.65
            let rowRect = CGRect(x: outerPad + 6, y: sy - 4, width: sidebarWidth - 12, height: rowH)

            if isActive {
                // Active row: faint cyan tint + cyan accent strip on the left.
                ctx.setFillColor(Jarvis.cyan.withAlphaComponent(0.10).cgColor)
                ctx.fill(rowRect)
                ctx.setFillColor(Jarvis.cyan.cgColor)
                ctx.fill(CGRect(x: rowRect.minX, y: rowRect.minY, width: 2.5, height: rowRect.height))
            }

            // File icon: small filled cyan dot (active) or hollow ring (inactive).
            let iconR: CGFloat = sidebarFontSize * 0.20
            let iconY = sy + sidebarFontSize * 0.45
            let iconX = outerPad + 16
            if isActive {
                ctx.setFillColor(Jarvis.cyan.cgColor)
                ctx.fillEllipse(in: CGRect(x: iconX, y: iconY - iconR, width: iconR * 2, height: iconR * 2))
            } else {
                ctx.setStrokeColor(Jarvis.cyanDim.cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: iconX, y: iconY - iconR, width: iconR * 2, height: iconR * 2))
            }

            // File name. Truncate by allowing the row to clip — the sidebar is
            // intentionally narrow.
            let color: UIColor = isActive ? Jarvis.cyan : Jarvis.textPrimary
            NSAttributedString(string: file, attributes: [
                .font: fileFont,
                .foregroundColor: color
            ]).draw(at: CGPoint(x: outerPad + 16 + iconR * 2 + 8, y: sy))
            sy += rowH
            if sy > workBottom - rowH { break }
        }

        // ---- Code area: tab bar then code ----------------------------------
        let tabBarHeight: CGFloat = size.height * 0.075
        let tabBarRect = CGRect(
            x: codeAreaLeft,
            y: workTop,
            width: size.width - codeAreaLeft - outerPad,
            height: tabBarHeight
        )

        // Tab separator line.
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: tabBarRect.minX, y: tabBarRect.maxY + 1))
        ctx.addLine(to: CGPoint(x: tabBarRect.maxX, y: tabBarRect.maxY + 1))
        ctx.strokePath()

        let tabFontSize = tabBarHeight * 0.46
        let tabFont = UIFont.systemFont(ofSize: tabFontSize, weight: .medium)
        let displayedTabs: [String] = activeFile.map { [$0] } ?? ["Login.tsx", "App.tsx"]
        let activeTabIdx = activeFile == nil ? activeTab : 0

        var tx = tabBarRect.minX + 6
        for (i, t) in displayedTabs.enumerated() {
            let isActive = (i == activeTabIdx)
            let attr = NSAttributedString(string: t, attributes: [
                .font: tabFont,
                .foregroundColor: isActive ? Jarvis.cyan : Jarvis.textDim,
                .kern: 1.0
            ])
            let w = attr.size().width
            attr.draw(at: CGPoint(x: tx, y: tabBarRect.midY - tabFontSize / 1.6))
            if isActive {
                ctx.setFillColor(Jarvis.cyan.cgColor)
                ctx.fill(CGRect(x: tx, y: tabBarRect.maxY - 3, width: w, height: 2.5))
            }
            tx += w + 28
        }

        // Code area geometry.
        let codeTop = tabBarRect.maxY + 14
        let codeBottom = workBottom
        let codeFontSize = (codeBottom - codeTop) / 22
        let codeFont = UIFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        let lineNumWidth: CGFloat = codeFontSize * 2.4
        let xCodeLeft = codeAreaLeft
        let xCodeText = xCodeLeft + lineNumWidth + 10
        var y = codeTop

        if let live = liveCode {
            let allLines = live.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let firstLine: Int
            let lastLine: Int
            if let count = animatedLineCount {
                firstLine = 0
                lastLine = min(count, allLines.count)
            } else {
                firstLine = min(max(0, editorScrollOffset), max(0, allLines.count - 1))
                let visibleCap = max(8, Int((codeBottom - codeTop) / (codeFontSize * 1.42)))
                lastLine = min(allLines.count, firstLine + visibleCap + 4)
            }
            let linesToRender = firstLine < lastLine ? Array(allLines[firstLine..<lastLine]) : []

            // Replay language state for blocks that started before the scroll window.
            var currentLang: WebLang = .html
            for skipped in allLines.prefix(firstLine) {
                if skipped.contains("<style") { currentLang = .css }
                else if skipped.contains("</style>") { currentLang = .html }
                else if skipped.contains("<script") { currentLang = .js }
                else if skipped.contains("</script>") { currentLang = .html }
            }

            for (relIdx, line) in linesToRender.enumerated() {
                let absIdx = firstLine + relIdx
                if line.contains("<style") { currentLang = .css }
                else if line.contains("</style>") { currentLang = .html }
                else if line.contains("<script") { currentLang = .js }
                else if line.contains("</script>") { currentLang = .html }

                NSAttributedString(string: String(format: "%3d", absIdx + 1), attributes: [
                    .font: codeFont,
                    .foregroundColor: Jarvis.synLineNum
                ]).draw(at: CGPoint(x: xCodeLeft, y: y))

                ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: xCodeLeft + lineNumWidth + 2, y: y - 2))
                ctx.addLine(to: CGPoint(x: xCodeLeft + lineNumWidth + 2, y: y + codeFontSize + 2))
                ctx.strokePath()

                let tokens = tokenizeWeb(line: line, lang: currentLang)
                var dx = xCodeText
                for (text, kind) in tokens {
                    let color: UIColor = colorForToken(kind)
                    let attr = NSAttributedString(string: text, attributes: [
                        .font: codeFont,
                        .foregroundColor: color
                    ])
                    attr.draw(at: CGPoint(x: dx, y: y))
                    dx += attr.size().width
                }
                y += codeFontSize * 1.42
                if y > codeBottom - codeFontSize { break }
            }
        } else {
            // Phase 1 demo snippet.
            let allLines: [String] = [
                "import React from 'react'",
                "import { useState } from 'react'",
                "",
                "const Login = () => {",
                "  const [email, setEmail] = useState('')",
                "  const [pass, setPass] = useState('')",
                "",
                "  return (",
                "    <div className=\"login\">",
                "      <h1>Sign in</h1>",
                "      <input type=\"email\" value={email} />",
                "      <button>Login</button>",
                "    </div>",
                "  )",
                "}"
            ]
            for (idx, line) in allLines.enumerated() {
                NSAttributedString(string: String(format: "%2d", idx + 1), attributes: [
                    .font: codeFont,
                    .foregroundColor: Jarvis.synLineNum
                ]).draw(at: CGPoint(x: xCodeLeft, y: y))

                ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: xCodeLeft + lineNumWidth + 2, y: y - 2))
                ctx.addLine(to: CGPoint(x: xCodeLeft + lineNumWidth + 2, y: y + codeFontSize + 2))
                ctx.strokePath()

                let tokens = tokenize(line: line)
                var dx = xCodeText
                for (text, kind) in tokens {
                    let color: UIColor = colorForToken(kind)
                    let attr = NSAttributedString(string: text, attributes: [
                        .font: codeFont,
                        .foregroundColor: color
                    ])
                    attr.draw(at: CGPoint(x: dx, y: y))
                    dx += attr.size().width
                }
                y += codeFontSize * 1.42
                if y > codeBottom - codeFontSize { break }
            }
        }

        drawSystemReadout(ctx, size: size, extra: "IDE")
        drawCornerBrackets(ctx, size: size)
    }

    private func colorForToken(_ kind: TokenKind) -> UIColor {
        switch kind {
        case .keyword:  return Jarvis.synKeyword
        case .function: return Jarvis.synFunction
        case .string:   return Jarvis.synString
        case .jsx:      return Jarvis.synJSX
        case .normal:   return Jarvis.synNormal
        }
    }

    private enum TokenKind { case keyword, function, string, jsx, normal }

    private enum WebLang { case html, css, js }

    private func tokenize(line: String) -> [(String, TokenKind)] {
        var result: [(String, TokenKind)] = []
        let keywords: Set<String> = ["import", "from", "const", "return", "useState", "let", "var", "function", "if", "else"]
        // Simple split on whitespace + symbols; keep separators
        var current = ""
        var inString: Character? = nil
        var inJSX: Bool = false

        func flush() {
            if current.isEmpty { return }
            let trimmed = current
            if let _ = inString {
                result.append((trimmed, .string))
            } else if keywords.contains(trimmed.trimmingCharacters(in: .whitespaces)) {
                result.append((trimmed, .keyword))
            } else if trimmed.range(of: #"^[A-Z][A-Za-z0-9]*$"#, options: .regularExpression) != nil {
                result.append((trimmed, .function))
            } else {
                result.append((trimmed, .normal))
            }
            current = ""
        }

        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if let s = inString {
                current.append(c)
                if c == s {
                    result.append((current, .string))
                    current = ""
                    inString = nil
                }
                i = line.index(after: i)
                continue
            }
            if c == "'" || c == "\"" {
                flush()
                current = String(c)
                inString = c
                i = line.index(after: i)
                continue
            }
            if c == "<" {
                flush()
                // gather <tagName...
                var jsx = "<"
                var j = line.index(after: i)
                while j < line.endIndex {
                    let ch = line[j]
                    if ch == ">" {
                        jsx.append(">")
                        j = line.index(after: j)
                        break
                    }
                    jsx.append(ch)
                    j = line.index(after: j)
                }
                result.append((jsx, .jsx))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var word = ""
                var j = i
                while j < line.endIndex, line[j].isLetter || line[j].isNumber || line[j] == "_" {
                    word.append(line[j])
                    j = line.index(after: j)
                }
                let trimmed = word
                if keywords.contains(trimmed) {
                    result.append((trimmed, .keyword))
                } else if trimmed.first?.isUppercase == true && trimmed.count > 1 {
                    result.append((trimmed, .function))
                } else {
                    result.append((trimmed, .normal))
                }
                i = j
                continue
            }
            current.append(c)
            i = line.index(after: i)
            if !current.isEmpty {
                result.append((current, .normal))
                current = ""
            }
        }
        flush()
        return result
    }

    private func tokenizeWeb(line: String, lang: WebLang) -> [(String, TokenKind)] {
        var result: [(String, TokenKind)] = []
        let jsKeywords: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "true", "false", "null", "document", "window", "querySelector", "addEventListener"]
        let cssProperties: Set<String> = ["color", "background", "font-size", "width", "height", "padding", "margin", "display", "flex", "border", "text-align", "position", "top", "left", "right", "bottom"]

        var current = ""
        var inString: Character? = nil
        var inComment: Int = 0  // 0 = not in comment, 1 = in //, 2 = in /* */

        func flush() {
            if current.isEmpty { return }
            let trimmed = current.trimmingCharacters(in: .whitespaces)

            if let _ = inString {
                result.append((current, .string))
            } else if inComment > 0 {
                result.append((current, .normal))  // comments as normal for now
            } else if lang == .html {
                if current.contains("<") || current.contains(">") {
                    result.append((current, .jsx))
                } else if current.contains("=") && !trimmed.isEmpty {
                    let parts = current.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count > 0 {
                        result.append((String(parts[0]), .jsx))
                        if parts.count > 1 {
                            result.append(("=", .normal))
                            result.append((String(parts[1]), .string))
                        }
                    }
                } else {
                    result.append((current, .normal))
                }
            } else if lang == .css {
                if trimmed.hasSuffix(":") {
                    result.append((current, .jsx))  // property name before :
                } else if trimmed.hasSuffix(";") || current.contains(";") {
                    result.append((current, .normal))  // value
                } else if cssProperties.contains(trimmed) {
                    result.append((current, .jsx))
                } else {
                    result.append((current, .normal))
                }
            } else if lang == .js {
                if jsKeywords.contains(trimmed) {
                    result.append((current, .keyword))
                } else if trimmed.first?.isUppercase == true && trimmed.count > 1 {
                    result.append((current, .function))
                } else {
                    result.append((current, .normal))
                }
            }
            current = ""
        }

        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]

            // Handle comments
            if inComment == 0 && c == "/" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "/" {
                flush()
                let comment = String(line[i...])
                result.append((comment, .normal))
                break
            }
            if inComment == 0 && c == "/" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "*" {
                flush()
                inComment = 2
                current.append(c)
                i = line.index(after: i)
                current.append(line[i])
                i = line.index(after: i)
                continue
            }
            if inComment == 2 && c == "*" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "/" {
                current.append(c)
                i = line.index(after: i)
                current.append(line[i])
                result.append((current, .normal))
                current = ""
                inComment = 0
                i = line.index(after: i)
                continue
            }
            if inComment == 2 {
                current.append(c)
                i = line.index(after: i)
                continue
            }

            // Handle HTML comments
            if inComment == 0 && lang == .html && c == "<" && line[i...].hasPrefix("<!--") {
                flush()
                var comment = ""
                var j = i
                while j < line.endIndex {
                    comment.append(line[j])
                    if comment.hasSuffix("-->") { break }
                    j = line.index(after: j)
                }
                result.append((comment, .normal))
                i = line.index(comment.endIndex, offsetBy: -1, limitedBy: line.startIndex) ?? line.endIndex
                i = line.index(after: i)
                continue
            }

            // Handle strings
            if let s = inString {
                current.append(c)
                if c == s {
                    result.append((current, .string))
                    current = ""
                    inString = nil
                }
                i = line.index(after: i)
                continue
            }
            if c == "'" || c == "\"" {
                flush()
                current = String(c)
                inString = c
                i = line.index(after: i)
                continue
            }

            // Handle HTML tags
            if lang == .html && c == "<" {
                flush()
                var tag = "<"
                var j = line.index(after: i)
                while j < line.endIndex {
                    let ch = line[j]
                    tag.append(ch)
                    if ch == ">" { break }
                    j = line.index(after: j)
                }
                result.append((tag, .jsx))
                i = line.index(after: i)
                while i < line.endIndex && line[i] != ">" {
                    i = line.index(after: i)
                }
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }

            // Handle CSS/JS identifiers and properties
            if c.isLetter || c == "_" {
                var word = ""
                var j = i
                while j < line.endIndex, line[j].isLetter || line[j].isNumber || line[j] == "_" || line[j] == "-" {
                    word.append(line[j])
                    j = line.index(after: j)
                }
                current.append(contentsOf: word)
                i = j
                continue
            }

            // Handle special characters
            if c == ":" || c == ";" || c == "=" {
                flush()
                current = String(c)
                flush()
                i = line.index(after: i)
                continue
            }

            // Whitespace and other
            if c.isWhitespace {
                flush()
                current = String(c)
                flush()
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        flush()
        return result
    }

    // MARK: File tree
    private func drawFileTree(in ctx: CGContext, size: CGSize) {
        drawJarvisBackground(ctx, size: size)

        let pad = max(24, min(size.width, size.height) * 0.05)
        let titleFontSize = size.height * 0.040
        let bodyFontSize = size.height * 0.038

        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let bodyFont = UIFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular)

        var y: CGFloat = pad + 6
        NSAttributedString(string: "FILES", attributes: [
            .font: titleFont,
            .foregroundColor: Jarvis.cyan,
            .kern: 3.0
        ]).draw(at: CGPoint(x: pad + 18, y: y))
        y += titleFontSize * 2.0

        // Underline below header
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: pad, y: y - bodyFontSize * 0.5))
        ctx.addLine(to: CGPoint(x: size.width - pad, y: y - bodyFontSize * 0.5))
        ctx.strokePath()

        struct Item { let label: String; let indent: CGFloat; let highlight: Bool; let isFolder: Bool }

        let items: [Item] = if !liveFiles.isEmpty && liveActiveFile != nil {
            // Live file mode: render each file from liveFiles
            liveFiles.map { filename in
                Item(label: filename, indent: 0, highlight: filename == liveActiveFile, isFolder: false)
            }
        } else {
            // Phase 1 demo: hardcoded project structure
            [
                Item(label: "src",           indent: 0,  highlight: false, isFolder: true),
                Item(label: "App.tsx",       indent: 28, highlight: false, isFolder: false),
                Item(label: "Login.tsx",     indent: 28, highlight: true,  isFolder: false),
                Item(label: "index.css",     indent: 28, highlight: false, isFolder: false),
                Item(label: "utils.ts",      indent: 28, highlight: false, isFolder: false),
                Item(label: "public",        indent: 0,  highlight: false, isFolder: true),
                Item(label: "index.html",    indent: 28, highlight: false, isFolder: false),
                Item(label: "package.json",  indent: 0,  highlight: false, isFolder: false),
                Item(label: "tsconfig.json", indent: 0,  highlight: false, isFolder: false),
            ]
        }

        for item in items {
            let labelColor: UIColor = item.highlight
                ? Jarvis.cyan
                : (item.isFolder ? Jarvis.lightBlue : Jarvis.textPrimary)

            // Highlight strip + left bracket for the active file
            if item.highlight {
                let stripRect = CGRect(x: pad - 4, y: y - 4, width: size.width - (pad - 4) * 2, height: bodyFontSize * 1.4)
                ctx.setFillColor(Jarvis.cyan.withAlphaComponent(0.10).cgColor)
                ctx.fill(stripRect)
                ctx.setFillColor(Jarvis.cyan.cgColor)
                ctx.fill(CGRect(x: pad - 4, y: y - 4, width: 3, height: bodyFontSize * 1.4))
            }

            // Icon: folder ▸ outlined cyan square, file ● cyan dot
            let iconX = pad + item.indent + 4
            let iconY = y + bodyFontSize * 0.30
            if item.isFolder {
                ctx.setStrokeColor(Jarvis.lightBlue.cgColor)
                ctx.setLineWidth(1.2)
                let r: CGFloat = bodyFontSize * 0.28
                ctx.stroke(CGRect(x: iconX, y: iconY - r, width: r * 2, height: r * 1.6))
                // small chevron
                ctx.setStrokeColor(Jarvis.cyan.cgColor)
                ctx.move(to: CGPoint(x: iconX + r * 0.5, y: iconY - r * 0.2))
                ctx.addLine(to: CGPoint(x: iconX + r, y: iconY + r * 0.4))
                ctx.addLine(to: CGPoint(x: iconX + r * 1.5, y: iconY - r * 0.2))
                ctx.strokePath()
            } else {
                let r: CGFloat = bodyFontSize * 0.18
                ctx.setFillColor((item.highlight ? Jarvis.cyan : Jarvis.cyanDim).cgColor)
                ctx.fillEllipse(in: CGRect(x: iconX + r * 0.6, y: iconY - r, width: r * 2, height: r * 2))
            }

            NSAttributedString(string: item.label, attributes: [
                .font: bodyFont,
                .foregroundColor: labelColor
            ]).draw(at: CGPoint(x: pad + item.indent + bodyFontSize * 1.4, y: y))
            y += bodyFontSize * 1.65
        }

        drawSystemReadout(ctx, size: size, extra: "TREE")
        drawCornerBrackets(ctx, size: size)
    }

    // MARK: Terminal
    /// Terminal panel rebranded as a Gemini CLI surface — 4-point sparkle, model
    /// badge, prompt arrows. Same content (live terminal log lines), restyled.
    private func drawTerminal(in ctx: CGContext, size: CGSize) {
        drawJarvisBackground(ctx, size: size, dark: true)

        let pad = max(20, min(size.width, size.height) * 0.045)

        let headerFontSize = size.height * 0.085
        let badgeFontSize = size.height * 0.055
        let bodyFontSize = size.height * 0.072

        let headerFont = UIFont.systemFont(ofSize: headerFontSize, weight: .semibold)
        let badgeFont = UIFont.monospacedSystemFont(ofSize: badgeFontSize, weight: .regular)
        let bodyFont = UIFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular)

        // Gemini-CLI palette (slightly different from JARVIS green-prompt scheme):
        // - prompts in bright cyan (user input)
        // - "thinking" / info in soft purple-blue
        // - success in soft green
        // - error in soft red
        // - output in dim white
        let promptCyan   = UIColor(red: 0.42, green: 0.86, blue: 1.00, alpha: 1)
        let infoMauve    = UIColor(red: 0.78, green: 0.78, blue: 1.00, alpha: 0.92)
        let successGreen = UIColor(red: 0.46, green: 0.92, blue: 0.66, alpha: 1)
        let errorRed     = UIColor(red: 1.00, green: 0.50, blue: 0.50, alpha: 1)
        let outputDim    = UIColor(red: 0.74, green: 0.78, blue: 0.85, alpha: 0.82)

        // ---- Header row: sparkle + GEMINI + model badge -------------------
        var y: CGFloat = pad + 6
        let sparkleR: CGFloat = headerFontSize * 0.46
        let sparkleCenter = CGPoint(x: pad + 18 + sparkleR, y: y + sparkleR + 2)
        drawGeminiSparkle(ctx, center: sparkleCenter, radius: sparkleR, color: Jarvis.cyan)

        let titleX = sparkleCenter.x + sparkleR + 14
        NSAttributedString(string: "GEMINI", attributes: [
            .font: headerFont,
            .foregroundColor: Jarvis.cyan,
            .kern: 4.0
        ]).draw(at: CGPoint(x: titleX, y: y))

        // Model badge (right-aligned).
        let modelBadge = NSAttributedString(string: "gemini-2.0-flash", attributes: [
            .font: badgeFont,
            .foregroundColor: Jarvis.cyanDim,
            .kern: 1.2
        ])
        let badgeWidth = modelBadge.size().width
        let badgeRect = CGRect(
            x: size.width - pad - badgeWidth - 22,
            y: y + 2,
            width: badgeWidth + 16,
            height: badgeFontSize + 8
        )
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(badgeRect)
        modelBadge.draw(at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 4))

        y += headerFontSize * 1.55

        // Cyan separator under the header.
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: pad, y: y - 4))
        ctx.addLine(to: CGPoint(x: size.width - pad, y: y - 4))
        ctx.strokePath()

        // ---- Body lines ----------------------------------------------------
        let bodyTop = y + 4
        let bodyBottom = size.height - max(40, size.height * 0.10)

        if liveTerminalActive {
            // Render the most recent N lines that fit. Compute capacity from the
            // available body area + line height so the panel never clips text.
            let lineHeight = bodyFontSize * 1.42
            let capacity = max(3, Int((bodyBottom - bodyTop) / lineHeight))
            let linesToRender = Array(liveTerminal.suffix(capacity))

            var ly = bodyTop
            for terminalLine in linesToRender {
                let color: UIColor
                switch terminalLine.kind {
                case .command: color = promptCyan
                case .output:  color = outputDim
                case .success: color = successGreen
                case .error:   color = errorRed
                case .info:    color = infoMauve
                }
                NSAttributedString(string: terminalLine.text, attributes: [
                    .font: bodyFont,
                    .foregroundColor: color
                ]).draw(at: CGPoint(x: pad + 6, y: ly))
                ly += lineHeight
            }
        } else {
            // Idle: show a Gemini-CLI welcome banner. Pure cosmetic.
            let banner: [(String, UIColor)] = [
                ("✦ welcome to gemini-cli", infoMauve),
                ("  type a prompt or hold the mic to speak", outputDim),
                ("> ", promptCyan),
            ]
            var ly = bodyTop
            for (text, color) in banner {
                NSAttributedString(string: text, attributes: [
                    .font: bodyFont,
                    .foregroundColor: color
                ]).draw(at: CGPoint(x: pad + 6, y: ly))
                ly += bodyFontSize * 1.42
            }
        }

        // ---- Footer status pill --------------------------------------------
        // Pulses while we're "thinking" — heuristic: any line in the recent
        // history starts with the sparkle prefix and we haven't yet logged a
        // success/error after it.
        let thinking = isTerminalThinking()
        let footerText = thinking ? "[ THINKING ]" : "[ READY ]"
        let footerColor: UIColor = thinking ? infoMauve : Jarvis.cyanDim
        let footerFont = UIFont.monospacedSystemFont(ofSize: badgeFontSize * 0.85, weight: .medium)
        let footerAttr = NSAttributedString(string: footerText, attributes: [
            .font: footerFont,
            .foregroundColor: footerColor,
            .kern: 1.8
        ])
        let footerW = footerAttr.size().width
        footerAttr.draw(at: CGPoint(x: pad + 6, y: size.height - pad - badgeFontSize - 6))

        // Tokens-out approximation on the right.
        let tokensApprox = approximateTokenCount()
        let tokensStr = NSAttributedString(string: "↑ \(tokensApprox) tokens", attributes: [
            .font: footerFont,
            .foregroundColor: outputDim,
            .kern: 1.0
        ])
        let tokensW = tokensStr.size().width
        tokensStr.draw(at: CGPoint(x: size.width - pad - tokensW - 6,
                                   y: size.height - pad - badgeFontSize - 6))
        _ = footerW

        drawSystemReadout(ctx, size: size, extra: "CLI")
        drawCornerBrackets(ctx, size: size)
    }

    /// 4-point sparkle (the Gemini logo signature). 8 vertices alternating outer
    /// and inner radius gives a plump cross/star.
    private func drawGeminiSparkle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: UIColor) {
        let path = CGMutablePath()
        let outerR = radius
        let innerR = radius * 0.34
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let r = i % 2 == 0 ? outerR : innerR
            let x = center.x + cos(angle) * r
            let y = center.y + sin(angle) * r
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    /// "Thinking" if the most recent meaningful log line is a prompt-or-info
    /// without a closing success/error after it.
    private func isTerminalThinking() -> Bool {
        for line in liveTerminal.reversed() {
            switch line.kind {
            case .success, .error: return false
            case .command, .info:  return true
            case .output:          continue
            }
        }
        return false
    }

    /// Rough token estimate used for the footer counter. Just sums character
    /// counts of all output lines and divides — close enough for cosmetic UI.
    private func approximateTokenCount() -> Int {
        let total = liveTerminal.reduce(0) { $0 + $1.text.count }
        return total / 4
    }

    // MARK: Assistant bubble
    private func drawAssistant(in ctx: CGContext, size: CGSize) {
        // Dark holographic bar (no rounded corners — corner brackets define the shape)
        let bgColor: UIColor
        let accentColor: UIColor
        switch assistantHighlight {
        case .blue:
            bgColor = UIColor(red: 8/255, green: 22/255, blue: 40/255, alpha: 0.92)
            accentColor = Jarvis.cyan
        case .green:
            bgColor = UIColor(red: 8/255, green: 30/255, blue: 22/255, alpha: 0.92)
            accentColor = UIColor(red: 0.43, green: 1.00, blue: 0.69, alpha: 1)
        case .none:
            bgColor = Jarvis.bg
            accentColor = Jarvis.cyan
        }
        bgColor.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        drawScanLines(ctx, size: size)

        // Pulsing-style emphasis: a thin accent bar across the top edge
        ctx.setFillColor(accentColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 2))
        ctx.fill(CGRect(x: 0, y: size.height - 2, width: size.width, height: 2))

        // Status dot (concentric rings) on the left
        let dotR: CGFloat = size.height * 0.16
        let dotCenter = CGPoint(x: size.height * 0.55, y: size.height / 2)
        ctx.setFillColor(accentColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.setStrokeColor(accentColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(x: dotCenter.x - dotR * 1.9, y: dotCenter.y - dotR * 1.9, width: dotR * 3.8, height: dotR * 3.8))
        ctx.setStrokeColor(accentColor.withAlphaComponent(0.25).cgColor)
        ctx.strokeEllipse(in: CGRect(x: dotCenter.x - dotR * 2.6, y: dotCenter.y - dotR * 2.6, width: dotR * 5.2, height: dotR * 5.2))

        // Label "AETHER" in tiny tracked caps
        let labelFont = UIFont.monospacedSystemFont(ofSize: size.height * 0.20, weight: .medium)
        NSAttributedString(string: "AETHER", attributes: [
            .font: labelFont,
            .foregroundColor: accentColor,
            .kern: 2.5
        ]).draw(at: CGPoint(x: size.height * 1.4, y: size.height * 0.16))

        // Main message text
        let textFont = UIFont.systemFont(ofSize: size.height * 0.36, weight: .regular)
        let attr = NSAttributedString(string: assistantText, attributes: [
            .font: textFont,
            .foregroundColor: Jarvis.textPrimary
        ])
        let textRect = CGRect(x: size.height * 1.4,
                              y: size.height * 0.40,
                              width: size.width - size.height * 1.8,
                              height: size.height * 0.55)
        attr.draw(in: textRect)

        // Right-side micro readout
        let micro = NSAttributedString(string: "▸ STREAMING", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: size.height * 0.18, weight: .regular),
            .foregroundColor: accentColor.withAlphaComponent(0.7),
            .kern: 1.4
        ])
        let mw = micro.size().width
        micro.draw(at: CGPoint(x: size.width - mw - size.height * 0.6, y: size.height * 0.40))

        drawCornerBrackets(ctx, size: size, color: accentColor, lineWidth: 2.5)
    }

    // MARK: Preview (mini browser-like card)
    private func drawPreview(in ctx: CGContext, size: CGSize) {
        // Preview ALSO has a holographic dark frame, but the inner content area is white
        // because it's a rendered web page.
        drawJarvisBackground(ctx, size: size)

        let pad = max(16, min(size.width, size.height) * 0.04)
        let titleFontSize = size.height * 0.055
        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)

        // Header bar
        var y: CGFloat = pad + 4
        NSAttributedString(string: "PREVIEW", attributes: [
            .font: titleFont,
            .foregroundColor: Jarvis.cyan,
            .kern: 3.0
        ]).draw(at: CGPoint(x: pad + 18, y: y))

        // URL bar
        let urlBar = CGRect(x: pad + 130, y: y - 2, width: size.width - pad * 2 - 150, height: titleFontSize * 1.3)
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(urlBar)
        NSAttributedString(string: "localhost:3000", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: titleFontSize * 0.7, weight: .regular),
            .foregroundColor: Jarvis.textDim
        ]).draw(at: CGPoint(x: urlBar.minX + 10, y: urlBar.midY - titleFontSize * 0.45))

        y += titleFontSize * 2.1

        // Inner white "browser" surface
        let inner = CGRect(x: pad, y: y, width: size.width - pad * 2, height: size.height - y - max(48, size.height * 0.08))
        UIColor.white.withAlphaComponent(0.95).setFill()
        ctx.fill(inner)
        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.stroke(inner)

        if let preview = previewImage {
            // Aspect-fit the snapshot inside `inner` so the WKWebView output never
            // stretches when its aspect doesn't perfectly match the panel's inner
            // rect (panel size can change at runtime via the corner-resize handles,
            // and the WKWebView is a fixed 1600×900). Letterbox bands stay white
            // so they read as "browser chrome" rather than a void.
            let imgSize = preview.size
            let drawRect: CGRect
            if imgSize.width > 0, imgSize.height > 0 {
                let imgAspect = imgSize.width / imgSize.height
                let innerAspect = inner.width / inner.height
                if imgAspect > innerAspect {
                    // Image wider than the inner rect → letterbox top + bottom.
                    let h = inner.width / imgAspect
                    drawRect = CGRect(x: inner.minX, y: inner.midY - h / 2, width: inner.width, height: h)
                } else {
                    // Image taller than the inner rect → pillarbox left + right.
                    let w = inner.height * imgAspect
                    drawRect = CGRect(x: inner.midX - w / 2, y: inner.minY, width: w, height: inner.height)
                }
            } else {
                drawRect = inner
            }
            preview.draw(in: drawRect)
        } else {
            // Phase 1 demo: fake login form
            let formCenter = CGPoint(x: inner.midX, y: inner.midY)
            let titleSize = inner.height * 0.10
            let titleAttr = NSAttributedString(string: "Sign in", attributes: [
                .font: UIFont.systemFont(ofSize: titleSize, weight: .semibold),
                .foregroundColor: UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
            ])
            let titleW = titleAttr.size().width
            titleAttr.draw(at: CGPoint(x: formCenter.x - titleW / 2, y: inner.minY + inner.height * 0.18))

            // Two input fields
            let fieldWidth = inner.width * 0.55
            let fieldHeight = inner.height * 0.085
            let fieldX = formCenter.x - fieldWidth / 2
            var fieldY = inner.minY + inner.height * 0.36

            let fieldFont = UIFont.systemFont(ofSize: fieldHeight * 0.42, weight: .regular)
            for placeholder in ["email@example.com", "••••••••"] {
                ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(CGRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
                NSAttributedString(string: placeholder, attributes: [
                    .font: fieldFont,
                    .foregroundColor: UIColor(white: 0.55, alpha: 1)
                ]).draw(at: CGPoint(x: fieldX + 12, y: fieldY + fieldHeight / 2 - fieldHeight * 0.25))
                fieldY += fieldHeight * 1.4
            }

            // Login button (blue)
            let btn = CGRect(x: fieldX, y: fieldY + 8, width: fieldWidth, height: fieldHeight)
            UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1).setFill()
            ctx.fill(btn)
            let btnText = NSAttributedString(string: "Login", attributes: [
                .font: UIFont.systemFont(ofSize: fieldHeight * 0.42, weight: .medium),
                .foregroundColor: UIColor.white
            ])
            let btnTextW = btnText.size().width
            btnText.draw(at: CGPoint(x: btn.midX - btnTextW / 2, y: btn.midY - fieldHeight * 0.25))
        }

        drawSystemReadout(ctx, size: size, extra: "WEB")
        drawCornerBrackets(ctx, size: size)
    }

    // MARK: Docs
    private func drawDocs(in ctx: CGContext, size: CGSize) {
        drawJarvisBackground(ctx, size: size)

        let pad = max(20, min(size.width, size.height) * 0.04)
        let titleFontSize = size.height * 0.045
        let bodyFontSize = size.height * 0.030
        let codeFontSize = size.height * 0.028

        var y: CGFloat = pad + 4
        NSAttributedString(string: "DOCS · useState", attributes: [
            .font: UIFont.systemFont(ofSize: titleFontSize, weight: .semibold),
            .foregroundColor: Jarvis.cyan,
            .kern: 2.5
        ]).draw(at: CGPoint(x: pad + 18, y: y))
        y += titleFontSize * 1.9

        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: pad, y: y - bodyFontSize * 0.4))
        ctx.addLine(to: CGPoint(x: size.width - pad, y: y - bodyFontSize * 0.4))
        ctx.strokePath()

        let bodyFont = UIFont.systemFont(ofSize: bodyFontSize, weight: .regular)
        let codeFont = UIFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

        let bodyParas: [(String, UIColor, UIFont)] = [
            ("useState is a React Hook that lets you add a state variable to your component.",
             Jarvis.textPrimary, bodyFont),
            ("",  Jarvis.textPrimary, bodyFont),
            ("Signature", Jarvis.cyan, UIFont.systemFont(ofSize: bodyFontSize, weight: .semibold)),
            ("const [state, setState] = useState(initialValue)", Jarvis.synJSX, codeFont),
            ("",  Jarvis.textPrimary, bodyFont),
            ("Parameters", Jarvis.cyan, UIFont.systemFont(ofSize: bodyFontSize, weight: .semibold)),
            ("· initialValue — the value the state starts with on the first render.",
             Jarvis.textPrimary, bodyFont),
            ("",  Jarvis.textPrimary, bodyFont),
            ("Returns", Jarvis.cyan, UIFont.systemFont(ofSize: bodyFontSize, weight: .semibold)),
            ("An array with the current state and a setter function.",
             Jarvis.textPrimary, bodyFont),
        ]
        for (text, color, font) in bodyParas {
            NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color
            ]).draw(in: CGRect(x: pad, y: y, width: size.width - pad * 2, height: bodyFontSize * 1.6))
            y += bodyFontSize * 1.55
            if y > size.height - max(48, size.height * 0.08) - bodyFontSize { break }
        }

        drawSystemReadout(ctx, size: size, extra: "DOCS")
        drawCornerBrackets(ctx, size: size)
    }

    // MARK: Terry (Easter egg)
    private func drawTerry(in ctx: CGContext, size: CGSize) {
        drawJarvisBackground(ctx, size: size)

        let pad = max(20, min(size.width, size.height) * 0.04)
        let titleFontSize = size.height * 0.045
        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)

        // Header with TERRY label + classified-style tag.
        var y: CGFloat = pad + 4
        NSAttributedString(string: "TERRY · CLASSIFIED", attributes: [
            .font: titleFont,
            .foregroundColor: Jarvis.cyan,
            .kern: 3.0
        ]).draw(at: CGPoint(x: pad + 18, y: y))
        y += titleFontSize * 1.9

        ctx.setStrokeColor(Jarvis.cyanFaint.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: pad, y: y - titleFontSize * 0.4))
        ctx.addLine(to: CGPoint(x: size.width - pad, y: y - titleFontSize * 0.4))
        ctx.strokePath()

        // Photo area: square, centered, with cyan corner brackets
        let photoSide = min(size.width - pad * 2, size.height - y - pad * 4)
        let photoRect = CGRect(
            x: (size.width - photoSide) / 2,
            y: y + 8,
            width: photoSide,
            height: photoSide
        )

        if let img = UIImage(named: "Terry") {
            // Slight cyan border behind the photo
            ctx.setStrokeColor(Jarvis.cyan.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(photoRect.insetBy(dx: -3, dy: -3))
            // Draw the photo inside
            img.draw(in: photoRect)
        } else {
            // Fallback if asset is missing
            ctx.setFillColor(UIColor(white: 0.10, alpha: 1).cgColor)
            ctx.fill(photoRect)
            NSAttributedString(string: "[ asset missing ]", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: Jarvis.cyanDim
            ]).draw(at: CGPoint(x: photoRect.midX - 100, y: photoRect.midY - 12))
        }

        // Photo corner brackets in cyan
        let bracket: CGFloat = 22
        ctx.setStrokeColor(Jarvis.cyan.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        let r = photoRect.insetBy(dx: -8, dy: -8)
        // TL
        ctx.move(to: CGPoint(x: r.minX, y: r.minY + bracket)); ctx.addLine(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX + bracket, y: r.minY)); ctx.strokePath()
        // TR
        ctx.move(to: CGPoint(x: r.maxX - bracket, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + bracket)); ctx.strokePath()
        // BL
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY - bracket)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.minX + bracket, y: r.maxY)); ctx.strokePath()
        // BR
        ctx.move(to: CGPoint(x: r.maxX - bracket, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bracket)); ctx.strokePath()

        // Caption row below
        let captionY = photoRect.maxY + 18
        NSAttributedString(string: "subject: TERRY", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: titleFontSize * 0.55, weight: .regular),
            .foregroundColor: Jarvis.textPrimary,
            .kern: 1.6
        ]).draw(at: CGPoint(x: pad + 18, y: captionY))
        NSAttributedString(string: "status: LEGENDARY", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: titleFontSize * 0.55, weight: .regular),
            .foregroundColor: Jarvis.cyan,
            .kern: 1.6
        ]).draw(at: CGPoint(x: pad + 18, y: captionY + titleFontSize * 0.85))

        drawSystemReadout(ctx, size: size, extra: "EGG")
        drawCornerBrackets(ctx, size: size)
    }
}

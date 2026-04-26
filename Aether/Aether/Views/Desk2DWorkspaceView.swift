import SwiftUI
import WebKit
import UIKit
import CoreImage

/// Flat SwiftUI mirror of the AR floating panels: planar pan (1–2 touches, single recognizer),
/// pinch zoom, PROJECT sidebar matching AR file list, header drag to move, Terry + skybox.
struct Desk2DWorkspaceView: View {
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var projectSession: ProjectSession

    @State private var cameraScale: CGFloat = 1.28
    @State private var pinchLive: CGFloat = 1
    /// Screen-space translation of the whole desk (locked to the 2D plane — no 3D tilt).
    @State private var deskPanOffset: CGSize = .zero

    @State private var headerDragKind: PanelKind?
    @State private var headerPanelStartPos: SIMD3<Float> = .zero
    @State private var headerDragActivationTranslation: CGSize = .zero
    /// Pre-scale layout offset while dragging (committed to `PanelManager` on finger up).
    @State private var headerDragVisualOffset: CGSize = .zero

    @State private var resizeDraggingKind: PanelKind?
    @State private var resizeStartScale: Float = 1

    @State private var skyboxImage: UIImage?

    private let metersToPoints: CGFloat = 780
    private let cyan = Color(red: 168 / 255, green: 173 / 255, blue: 179 / 255)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                deskBackground
                    .ignoresSafeArea()

                if let pm = sessionManager.panelManager {
                    let kinds = deskKinds(panelManager: pm)
                    ZStack {
                        Desk2DCameraGestureOverlay(
                            onPlanarPanDelta: { d in
                                deskPanOffset.width += d.x
                                deskPanOffset.height += d.y
                            },
                            onBackgroundTap: {
                                sessionManager.selectPanel(nil)
                            }
                        )
                        let layoutExclusion = headerDragKind ?? resizeDraggingKind
                        ForEach(kinds, id: \.self) { kind in
                            deskPanel(kind: kind, panelManager: pm, size: geo.size, layoutExclusion: layoutExclusion)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(deskPanOffset)
                    .scaleEffect(cameraScale * pinchLive, anchor: .center)
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { pinchLive = $0 }
                            .onEnded { _ in
                                cameraScale = min(4, max(0.4, cameraScale * pinchLive))
                                pinchLive = 1
                            }
                    )
                } else {
                    Color.black.ignoresSafeArea()
                }

                VStack {
                    HStack(spacing: 10) {
                        Button {
                            resetCamera()
                        } label: {
                            Label("Reset view", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 112)
                    Spacer()
                }
            }
        }
        .task(id: sessionManager.selectedSpatialScene) {
            skyboxImage = await Desk2DSkyboxLoader.loadUIImage(for: sessionManager.selectedSpatialScene)
        }
    }

    private func resetCamera() {
        cameraScale = 1.28
        pinchLive = 1
        deskPanOffset = .zero
    }

    private func deskKinds(panelManager pm: PanelManager) -> [PanelKind] {
        PanelKind.allCases.compactMap { k -> PanelKind? in
            pm.panelDeskFrame(k).map { _ in k }
        }
        .sorted { a, b in
            let ya = pm.panelDeskFrame(a)?.pos.y ?? 0
            let yb = pm.panelDeskFrame(b)?.pos.y ?? 0
            return ya < yb
        }
    }

    /// Bounding-box centre of all visible desk panels in XZ, optionally ignoring one panel
    /// so it doesn’t move the origin while that tile is dragged or resized (prevents flicker / “double” tiles).
    private func centroidXZ(panelManager pm: PanelManager, excluding: PanelKind?) -> SIMD2<Float>? {
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        var any = false
        for k in PanelKind.allCases {
            if let ex = excluding, k == ex { continue }
            guard let f = pm.panelDeskFrame(k) else { continue }
            let hw = f.w / 2
            let hh = f.h / 2
            minX = min(minX, f.pos.x - hw)
            maxX = max(maxX, f.pos.x + hw)
            minZ = min(minZ, f.pos.z - hh)
            maxZ = max(maxZ, f.pos.z + hh)
            any = true
        }
        if !any, let ex = excluding, let f = pm.panelDeskFrame(ex) {
            return SIMD2(f.pos.x, f.pos.z)
        }
        guard any else { return nil }
        return SIMD2((minX + maxX) / 2, (minZ + maxZ) / 2)
    }

    @ViewBuilder
    private func deskPanel(kind: PanelKind, panelManager pm: PanelManager, size: CGSize, layoutExclusion: PanelKind?) -> some View {
        if let frame = pm.panelDeskFrame(kind), let c = centroidXZ(panelManager: pm, excluding: layoutExclusion) {
            let wPts = CGFloat(frame.w) * metersToPoints
            let hPts = CGFloat(frame.h) * metersToPoints
            let cx = CGFloat(frame.pos.x - c.x) * metersToPoints
            let cy = CGFloat(frame.pos.z - c.y) * metersToPoints

            let isSelected = sessionManager.selectedPanel == kind
            let screenPos = CGPoint(x: size.width / 2 + cx, y: size.height / 2 + cy)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? cyan : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                    )

                VStack(spacing: 0) {
                    panelHeader(kind: kind, panelManager: pm)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.55))

                    panelBody(kind: kind, panelManager: pm, panelWidth: wPts, panelHeight: max(40, hPts - 34))
                }
                .frame(width: wPts, height: hPts)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if isSelected {
                    resizeHandle(kind: kind, panelManager: pm, panelSize: CGSize(width: wPts, height: hPts))
                }
            }
            .frame(width: wPts, height: hPts)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .position(screenPos)
            .offset(headerDragKind == kind ? headerDragVisualOffset : .zero)
        }
    }

    private func panelHeader(kind: PanelKind, panelManager pm: PanelManager) -> some View {
        HStack {
            Text(title(for: kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .gesture(headerDragGesture(kind: kind, panelManager: pm))
    }

    private func headerDragGesture(kind: PanelKind, panelManager pm: PanelManager) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if headerDragKind == nil, dist > 8 {
                    headerDragKind = kind
                    headerPanelStartPos = pm.panelLocalPosition(kind) ?? .zero
                    // Lock the "drag zero" at the exact activation point to avoid
                    // a visual pop when crossing the drag threshold.
                    headerDragActivationTranslation = value.translation
                    headerDragVisualOffset = .zero
                }
                guard headerDragKind == kind else { return }
                // Desk cluster is `scaleEffect` above us — map screen translation into layout points
                // so the tile tracks the finger 1:1 and we don’t spam `PanelManager` / SwiftUI every frame.
                let adjusted = CGSize(
                    width: value.translation.width - headerDragActivationTranslation.width,
                    height: value.translation.height - headerDragActivationTranslation.height
                )
                let eff = max(cameraScale * pinchLive, 0.001)
                headerDragVisualOffset = CGSize(
                    width: adjusted.width / eff,
                    height: adjusted.height / eff
                )
            }
            .onEnded { value in
                guard headerDragKind == kind else { return }
                let dist = hypot(value.translation.width, value.translation.height)
                if dist < 10 {
                    if sessionManager.selectedPanel == kind {
                        sessionManager.selectPanel(nil)
                    } else {
                        sessionManager.selectPanel(kind)
                    }
                } else {
                    let adjusted = CGSize(
                        width: value.translation.width - headerDragActivationTranslation.width,
                        height: value.translation.height - headerDragActivationTranslation.height
                    )
                    let eff = max(cameraScale * pinchLive, 0.001)
                    let dx = Float(adjusted.width / eff) / Float(metersToPoints)
                    let dz = Float(adjusted.height / eff) / Float(metersToPoints)
                    var p = headerPanelStartPos
                    p.x += dx
                    p.z += dz
                    pm.setPanelLocalPosition(kind, position: p)
                    sessionManager.objectWillChange.send()
                }
                headerDragVisualOffset = .zero
                headerDragActivationTranslation = .zero
                headerDragKind = nil
            }
    }

    @ViewBuilder
    private func panelBody(kind: PanelKind, panelManager pm: PanelManager, panelWidth: CGFloat, panelHeight: CGFloat) -> some View {
        switch kind {
        case .editor:
            let sidebarW = max(152, min(floor(panelWidth * 0.32), panelWidth - 120))
            let codeW = max(100, panelWidth - sidebarW)
            HStack(spacing: 0) {
                deskEditorSidebar(panelManager: pm, fixedWidth: sidebarW)
                    .frame(width: sidebarW)
                MonacoEditorView(
                    filename: projectSession.currentFile,
                    code: projectSession.currentCode,
                    onChange: { new in
                        if new != projectSession.currentCode {
                            projectSession.setCode(new, forFile: projectSession.currentFile, pushHistory: false)
                        }
                    }
                )
                .frame(width: codeW, height: panelHeight)
                .clipped()
            }
            .frame(width: panelWidth, height: panelHeight)
            .background(IJ.bgEditor)
        case .preview:
            Desk2DPreviewWebView(html: projectSession.currentCode)
                .frame(width: panelWidth, height: panelHeight)
        case .assistant:
            ScrollView {
                Text(sessionManager.aiBubbleText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: panelWidth, height: panelHeight)
        case .terminal:
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundColor(cyan.opacity(0.85))
                Text("Terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(width: panelWidth, height: panelHeight)
        case .docs:
            VStack(spacing: 6) {
                Image(systemName: "book")
                    .font(.title2)
                    .foregroundColor(cyan.opacity(0.85))
                Text("Docs")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(width: panelWidth, height: panelHeight)
        case .terry:
            ZStack {
                Color(red: 0.06, green: 0.07, blue: 0.09)
                Group {
                    if UIImage(named: "Terry") != nil {
                        Image("Terry")
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundColor(cyan.opacity(0.5))
                    }
                }
            }
            .frame(width: panelWidth, height: panelHeight)
        case .fileTree:
            Text("Files")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .frame(width: panelWidth, height: panelHeight)
        }
    }

    private func deskEditorSidebar(panelManager pm: PanelManager, fixedWidth: CGFloat) -> some View {
        let rows = pm.deskSidebarFileRows()
        let names = rows.files
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("PROJECT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(IJ.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(IJ.textSecondary)
                    Text("src")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(IJ.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                ForEach(names, id: \.self) { file in
                    let active = projectSession.currentFile == file
                    Button {
                        projectSession.switchTo(file: file)
                        let sorted = Array(projectSession.projectFiles.keys).sorted()
                        pm.setLiveFiles(active: projectSession.currentFile, files: sorted.isEmpty ? names : sorted)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(IJ.iconColor(for: file))
                                .frame(width: 7, height: 7)
                            Text(file)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(active ? IJ.textPrimary : IJ.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(active ? IJ.bgSelected : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: fixedWidth, alignment: .leading)
        }
        .frame(width: fixedWidth)
        .frame(maxHeight: .infinity)
        .background(IJ.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(IJ.border)
                .frame(width: 1)
        }
    }

    private func title(for kind: PanelKind) -> String {
        switch kind {
        case .editor: return projectSession.currentFile
        case .preview: return "Preview"
        case .terminal: return "Terminal"
        case .assistant: return "Assistant"
        case .docs: return "Docs"
        case .terry: return "Terry"
        case .fileTree: return "Files"
        }
    }

    private func resizeHandle(kind: PanelKind, panelManager pm: PanelManager, panelSize: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(cyan)
            .padding(8)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if resizeDraggingKind == nil {
                            resizeDraggingKind = kind
                            resizeStartScale = pm.panelScale(kind) ?? 1
                        }
                        guard resizeDraggingKind == kind else { return }
                        let delta = Float(v.translation.width + v.translation.height) / 160
                        let newScale = max(0.4, min(2.6, resizeStartScale * (1 + delta)))
                        pm.setPanelScale(kind, scale: newScale)
                    }
                    .onEnded { _ in
                        if resizeDraggingKind == kind {
                            resizeDraggingKind = nil
                            sessionManager.objectWillChange.send()
                        }
                    }
            )
    }

    @ViewBuilder
    private var deskBackground: some View {
        let scene = sessionManager.selectedSpatialScene
        ZStack {
            if scene != .realWorld, scene != .focusDark, let img = skyboxImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 18)
                    .overlay(Color.black.opacity(0.38))
            }
            switch scene {
            case .realWorld:
                LinearGradient(
                    colors: [Color.black, Color(red: 0.08, green: 0.09, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .focusDark:
                LinearGradient(
                    colors: [Color.black, scene.accentColor.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            default:
                if skyboxImage == nil {
                    LinearGradient(
                        colors: [scene.accentColor.opacity(0.45), Color.black.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }
}

// MARK: - Skybox (bundled EXR → UIImage)

private enum Desk2DSkyboxLoader {
    static func loadUIImage(for scene: SpatialScene) async -> UIImage? {
        guard let folder = scene.environmentSkyboxFolderName,
              let base = scene.environmentImageBaseName else { return nil }
        guard let url = Bundle.main.url(forResource: base, withExtension: "exr", subdirectory: folder) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let ci = CIImage(contentsOf: url) else { return nil }
            let maxW: CGFloat = 2200
            let extent = ci.extent
            guard extent.width > 1, extent.height > 1 else { return nil }
            let scale = min(1, maxW / extent.width)
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ext = scaled.extent
            guard ext.width > 0, ext.height > 0, ext.width.isFinite, ext.height.isFinite else { return nil }
            let rect = CGRect(
                x: ext.origin.x,
                y: ext.origin.y,
                width: min(ext.width, 8192),
                height: min(ext.height, 4096)
            )
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let cg = ctx.createCGImage(scaled, from: rect) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - Planar desk pan (1–2 touches, one recognizer) + tap to deselect

private struct Desk2DCameraGestureOverlay: UIViewRepresentable {
    var onPlanarPanDelta: (CGPoint) -> Void
    var onBackgroundTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlanarPanDelta: onPlanarPanDelta, onBackgroundTap: onBackgroundTap)
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true

        // One recognizer for 1 or 2 touches so spreading / pinching fingers doesn’t
        // combine two independent pans — translation stays in the screen plane.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        tap.require(toFail: pan)

        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(tap)

        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPlanarPanDelta = onPlanarPanDelta
        context.coordinator.onBackgroundTap = onBackgroundTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPlanarPanDelta: (CGPoint) -> Void
        var onBackgroundTap: () -> Void

        private var lastTranslation: CGPoint = .zero

        init(onPlanarPanDelta: @escaping (CGPoint) -> Void, onBackgroundTap: @escaping () -> Void) {
            self.onPlanarPanDelta = onPlanarPanDelta
            self.onBackgroundTap = onBackgroundTap
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began:
                lastTranslation = t
            case .changed:
                let d = CGPoint(x: t.x - lastTranslation.x, y: t.y - lastTranslation.y)
                lastTranslation = t
                DispatchQueue.main.async { self.onPlanarPanDelta(d) }
            default:
                lastTranslation = .zero
                g.setTranslation(.zero, in: g.view)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            DispatchQueue.main.async { self.onBackgroundTap() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

// MARK: - Preview HTML

private struct Desk2DPreviewWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.bounces = true
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        uiView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String = ""
    }
}

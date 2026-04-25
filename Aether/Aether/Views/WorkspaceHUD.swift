import SwiftUI

struct WorkspaceHUD: View {
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var voiceManager: VoiceManager
    /// Tap on the "Phone" pill returns to PhoneIDEView. Wired from ContentView.
    var onRequestPhoneMode: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // "Let's start" overlay — visible until the user wakes the workspace up.
            // Sits at the top of the ZStack so it captures taps even though the
            // ARWorkspaceView underneath also has a tap recognizer (see below
            // for the .allowsHitTesting placement).
            if !sessionManager.workspaceStarted {
                LetsStartOverlay {
                    sessionManager.beginWorkspace()
                }
                .transition(.opacity.combined(with: .scale(scale: 1.05)))
                .zIndex(100)
            }

            // Top status pill (decorative — let taps pass through to AR view)
            VStack {
                HStack(spacing: 10) {
                    Circle()
                        .fill(sessionManager.handDetected ? Color(red: 168/255, green: 173/255, blue: 179/255) : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(gestureLabel)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(0.6)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.top, 56)
                Spacer()
            }
            .allowsHitTesting(false)

            // Hand skeleton overlay (bottom-left, decorative)
            HandSkeletonOverlay(points: sessionManager.handLandmarksScreen,
                                isDetected: sessionManager.handDetected)
                .frame(width: 140, height: 200)
                .padding(.leading, 16)
                .padding(.bottom, 24)
                .allowsHitTesting(false)

            // Voice transcript (bottom-right, decorative — shows what the recognizer
            // is hearing while push-to-talk is active or the last fired utterance).
            VStack(alignment: .trailing) {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(voiceManager.isPushToTalkActive
                                  ? Color(red: 1.0, green: 0.30, blue: 0.45)
                                  : Color(red: 168/255, green: 173/255, blue: 179/255))
                            .frame(width: 6, height: 6)
                        Text(transcriptDisplay)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: 240, alignment: .trailing)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 96)  // leaves room for the mic button below
            }
            .allowsHitTesting(false)

            // Push-to-talk mic button (bottom-center). Hold to speak, release to fire.
            VStack {
                Spacer()
                MicButton(isActive: voiceManager.isPushToTalkActive)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !voiceManager.isPushToTalkActive {
                                    voiceManager.beginPushToTalk()
                                }
                            }
                            .onEnded { _ in
                                voiceManager.endPushToTalk()
                            }
                    )
                    .padding(.bottom, 32)
            }

            // (The overlay's transition handles its own fade — we still attach a
            // body-level animation modifier below so SwiftUI animates the
            // workspaceStarted boolean change, otherwise the overlay would just
            // pop out without easing.)

            // Top-right "Phone" pill — taps return to the phone IDE. Decorative
            // tinting matches the IntelliJ-Islands neutral palette.
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onRequestPhoneMode?() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "iphone")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Phone")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.5)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .padding(.top, 56)
                    .padding(.trailing, 18)
                }
                Spacer()
            }

            // Preview-scroll arrows (right edge, vertically centered). Only shown
            // when there's a live preview to scroll.
            if sessionManager.hasLivePreview && sessionManager.workspaceStarted {
                VStack(spacing: 12) {
                    Button(action: { sessionManager.scrollPreview(dy: -300) }) {
                        previewArrow(systemName: "chevron.up")
                    }
                    Button(action: { sessionManager.scrollPreview(dy: 300) }) {
                        previewArrow(systemName: "chevron.down")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
                .allowsHitTesting(true)
            }

            // Junie execution-plan overlay — a proper AR pop-out card. Pops
            // toward the user with a scale-in animation, corner brackets,
            // sweeping scan line. Voice commands ("yes" / "no") flow through
            // ARSessionManager.handleVoiceCommand, which mutates pendingPlan,
            // so the overlay reacts automatically.
            if let plan = sessionManager.session.pendingPlan {
                PlanHUDOverlay(
                    plan: plan,
                    onConfirm: { sessionManager.confirmPendingPlan() },
                    onCancel:  { sessionManager.cancelPendingPlan() },
                    style: .full
                )
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .zIndex(60)
            }

            // "Armed — say what to build" hint bar — only when the wake-word gate
            // is set and no plan is already pending. Tells the user JARVIS heard
            // them and is waiting for the actual prompt.
            if voiceManager.intentArmed && sessionManager.session.pendingPlan == nil {
                VStack(spacing: 0) {
                    armedHintBar
                        .padding(.top, 56)
                    Spacer()
                }
                .transition(.opacity)
                .zIndex(58)
                .allowsHitTesting(false)
            }

            // Corner-resize handles for the currently selected panel.
            ForEach(Array(sessionManager.selectedPanelCorners.enumerated()), id: \.offset) { idx, point in
                CornerHandle(corner: idx)
                    .position(point)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if sessionManager.scaleDragState == nil {
                                    sessionManager.beginScaleDrag(corner: idx, location: value.startLocation)
                                }
                                sessionManager.updateScaleDrag(location: value.location)
                            }
                            .onEnded { value in
                                // Throw-to-dismiss: if the predicted endpoint travels far past
                                // the release point (i.e., a fast flick), shrink and remove the panel.
                                let pdx = value.predictedEndLocation.x - value.location.x
                                let pdy = value.predictedEndLocation.y - value.location.y
                                let predictedDistance = sqrt(pdx * pdx + pdy * pdy)
                                if predictedDistance > 220 {
                                    sessionManager.throwDismissSelectedPanel()
                                }
                                sessionManager.endScaleDrag()
                            }
                    )
            }
        }
        .animation(.easeInOut(duration: 0.45), value: sessionManager.workspaceStarted)
    }

    /// Compact "ready for prompt" hint shown after the user says a wake phrase
    /// (e.g. "Hey Junie") with no body. Holds until the user speaks again or the
    /// arming times out in `VoiceManager`.
    private var armedHintBar: some View {
        HStack(spacing: 8) {
            Image("JunieIcon")
                .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text("LISTENING · TELL JUNIE WHAT TO BUILD")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color(red: 25/255, green: 27/255, blue: 30/255).opacity(0.86))
                .overlay(
                    Capsule().stroke(Color(red: 95/255, green: 184/255, blue: 101/255).opacity(0.55),
                                     lineWidth: 1)
                )
        )
    }

    private var gestureLabel: String {
        switch sessionManager.currentGesture {
        case .none: return "ready"
        case .point: return "point"
        case .pinch: return "pinch"
        case .openPalm: return "open"
        case .fist: return "fist"
        case .thumbsUp: return "thumbs up"
        }
    }

    private func previewArrow(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var transcriptDisplay: String {
        if voiceManager.isPushToTalkActive {
            return voiceManager.transcript.isEmpty ? "listening…" : voiceManager.transcript
        }
        if !voiceManager.lastUtterance.isEmpty { return "↳ \(voiceManager.lastUtterance)" }
        return "hold mic to speak"
    }
}

private struct MicButton: View {
    let isActive: Bool
    @State private var pulsePhase: Double = 0
    private let cyan = Color(red: 168/255, green: 173/255, blue: 179/255)
    private let red  = Color(red: 1.0, green: 0.30, blue: 0.45)

    var body: some View {
        ZStack {
            // Outer pulse ring while listening
            if isActive {
                Circle()
                    .stroke(red.opacity(0.65 - pulsePhase * 0.5), lineWidth: 3)
                    .frame(width: 92 + pulsePhase * 28, height: 92 + pulsePhase * 28)
                Circle()
                    .stroke(red.opacity(0.35 - pulsePhase * 0.25), lineWidth: 2)
                    .frame(width: 110 + pulsePhase * 36, height: 110 + pulsePhase * 36)
            }

            // Static halo
            Circle()
                .fill((isActive ? red : cyan).opacity(0.18))
                .frame(width: 84, height: 84)
            Circle()
                .stroke(isActive ? red : cyan, lineWidth: 2)
                .frame(width: 72, height: 72)

            // Mic glyph
            Image(systemName: isActive ? "waveform" : "mic.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(isActive ? red : cyan)

            // Hold-to-talk label below
            VStack {
                Spacer()
                Text(isActive ? "LISTENING" : "HOLD · OR RAISE PALM")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.6)
                    .foregroundColor((isActive ? red : cyan).opacity(0.85))
                    .padding(.top, 100)
            }
            .frame(width: 130, height: 130)
        }
        .frame(width: 140, height: 140)
        .contentShape(Circle().inset(by: -20))  // larger hit area
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsePhase = 1.0
            }
        }
    }
}

private struct CornerHandle: View {
    let corner: Int  // 0 TL, 1 TR, 2 BL, 3 BR
    private let cyan = Color(red: 168/255, green: 173/255, blue: 179/255)
    private let size: CGFloat = 36

    var body: some View {
        ZStack {
            // Hit-target backing (slightly larger, transparent)
            Color.white.opacity(0.001)
                .frame(width: size + 12, height: size + 12)
            // L-bracket matching the panel's holographic style
            CornerBracketShape(corner: corner)
                .stroke(cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
            // Inner dot
            Circle()
                .fill(cyan)
                .frame(width: 5, height: 5)
        }
        .shadow(color: cyan.opacity(0.6), radius: 4)
    }
}

private struct CornerBracketShape: Shape {
    let corner: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height)
        switch corner {
        case 0:  // top-left
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        case 1:  // top-right
            p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        case 2:  // bottom-left
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        default: // bottom-right
            p.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        }
        return p
    }
}

/// Center-screen "Let's start" prompt shown after the user places the workspace
/// but before the panels have been conjured. Tapping anywhere on the screen
/// (the prompt covers the full HUD area transparently) fires `onTap`.
private struct LetsStartOverlay: View {
    let onTap: () -> Void
    private let cyan = Color(red: 168/255, green: 173/255, blue: 179/255)
    @State private var pulse: CGFloat = 0

    var body: some View {
        // Wrap the whole overlay in a Button so taps on ANY visual element
        // (the rings, the wordmark, the "LET'S START" pill) actually fire
        // `onTap`. The previous .onTapGesture on a transparent backing layer
        // was getting absorbed by the visible Text views in front of it.
        Button(action: onTap) {
            VStack(spacing: 22) {
                // Aether glyph: concentric cyan rings with a hex center marker.
                ZStack {
                    Circle()
                        .stroke(cyan.opacity(0.18), lineWidth: 1)
                        .frame(width: 180 + pulse * 20, height: 180 + pulse * 20)
                    Circle()
                        .stroke(cyan.opacity(0.35 - pulse * 0.15), lineWidth: 1.5)
                        .frame(width: 130, height: 130)
                    Circle()
                        .stroke(cyan, lineWidth: 2)
                        .frame(width: 86, height: 86)
                    HexagonShape()
                        .stroke(cyan, lineWidth: 1.4)
                        .frame(width: 30, height: 30)
                }

                Text("ArcReact")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.95))

                Text("workspace ready")
                    .font(.system(size: 11, weight: .regular))
                    .tracking(2)
                    .foregroundColor(cyan.opacity(0.85))

                // Tap-here CTA button. Just visual — the whole overlay is tappable.
                Text("LET'S START")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(3)
                    .foregroundColor(.white)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 14)
                    .background(
                        ZStack {
                            Capsule().fill(Color.black.opacity(0.55))
                            Capsule().stroke(cyan, lineWidth: 1.4)
                        }
                    )
                    .padding(.top, 14)

                Text("or hold the mic and speak")
                    .font(.system(size: 10, weight: .regular))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}

private struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 6
            let x = cx + cos(angle) * r
            let y = cy + sin(angle) * r
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }
}

private struct HandSkeletonOverlay: View {
    let points: [CGPoint]
    let isDetected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.45))
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            if isDetected {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        // Map screen coords back into local space.
                        // points are full-screen view points; we just normalize via min/max for overlay.
                        if points.isEmpty { return }
                        let xs = points.map { $0.x }
                        let ys = points.map { $0.y }
                        guard let minX = xs.min(), let maxX = xs.max(),
                              let minY = ys.min(), let maxY = ys.max() else { return }
                        let rangeX = max(40, maxX - minX)
                        let rangeY = max(40, maxY - minY)
                        let pad: CGFloat = 12
                        let scaleX = (size.width - pad * 2) / rangeX
                        let scaleY = (size.height - pad * 2) / rangeY
                        let scale = min(scaleX, scaleY)
                        let offsetX = (size.width - rangeX * scale) / 2 - minX * scale
                        let offsetY = (size.height - rangeY * scale) / 2 - minY * scale
                        for p in points {
                            let pp = CGPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY)
                            let dotR: CGFloat = 2.5
                            ctx.fill(Path(ellipseIn: CGRect(x: pp.x - dotR, y: pp.y - dotR, width: dotR * 2, height: dotR * 2)),
                                     with: .color(Color(red: 168/255, green: 173/255, blue: 179/255)))
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Text("no hand")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

import SwiftUI

/// Iron-Man-style HUD overlay that surfaces a Junie execution plan over the
/// AR view (and reused inside the phone IDE chat). Frosted-glass dark base,
/// thin neutral-grey geometry, sequential reveal — but explicitly no blue per
/// the project's "no blue in AR experience" rule. Designed to read at a
/// glance: summary on top, step cards in the middle, confirm/cancel chips
/// at the bottom.
struct PlanHUDOverlay: View {
    let plan: BackendClient.PlanPayload
    let onConfirm: () -> Void
    let onCancel: () -> Void
    /// Compact = phone-IDE inline use (sized to its container).
    /// Full = AR overlay (full-screen scrim + centered card).
    var style: Style = .full

    enum Style { case full, compact }

    @State private var revealStep: Int = -1
    @State private var pulse: CGFloat = 0

    private let accent = Color(red: 168/255, green: 173/255, blue: 179/255) // #A8ADB3
    private let accentDim = Color(red: 168/255, green: 173/255, blue: 179/255).opacity(0.55)
    private let accentFaint = Color(red: 168/255, green: 173/255, blue: 179/255).opacity(0.18)
    private let bg = Color(red: 25/255, green: 27/255, blue: 30/255)

    var body: some View {
        ZStack {
            if style == .full {
                // Scrim — blocks AR taps from leaking through to panels behind.
                Color.black.opacity(0.55).ignoresSafeArea()
                    .transition(.opacity)
            }
            card
                .frame(maxWidth: style == .full ? 460 : .infinity)
                .padding(style == .full ? 24 : 12)
        }
        .onAppear { animateIn() }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            divider
            scanLine.padding(.top, 1)
            stepsList
            divider
            footer
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(bg.opacity(0.92))
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial.opacity(0.4))
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.35), lineWidth: 1)
                // HUD corner brackets — Tony-Stark trim.
                cornerBrackets
                // Faint ambient pulse around the whole card.
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accentFaint, lineWidth: 1)
                    .scaleEffect(1 + pulse * 0.012)
                    .opacity(0.85 - pulse * 0.4)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var cornerBrackets: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                let l: CGFloat = 16
                // top-left
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: l, y: 0))
                // top-right
                p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
                // bottom-right
                p.move(to: CGPoint(x: w, y: h - l)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - l, y: h))
                // bottom-left
                p.move(to: CGPoint(x: l, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - l))
            }
            .stroke(accent, lineWidth: 1.5)
        }
    }

    private var scanLine: some View {
        // A single thin scan line gliding under the header — adds the HUD vibe
        // without becoming a screen-effect.
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [accentFaint, accent.opacity(0.4), accentFaint],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.6, height: 1)
                .offset(x: -geo.size.width * 0.6 + (geo.size.width + geo.size.width * 0.6) * pulse)
        }
        .frame(height: 1)
    }

    private var divider: some View {
        Rectangle().fill(accent.opacity(0.18)).frame(height: 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                JunieSparkle(color: Color(red: 95/255, green: 184/255, blue: 101/255))
                    .frame(width: 14, height: 14)
                Text("JUNIE · EXECUTION PLAN")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(accent)
                Spacer()
                Text(String(format: "%02d STEP%@", plan.steps.count, plan.steps.count == 1 ? "" : "S"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(accentDim)
            }
            Text(plan.summary)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.steps) { step in
                let idx = plan.steps.firstIndex(where: { $0.id == step.id }) ?? 0
                stepCard(step: step)
                    .opacity(revealStep >= idx ? 1 : 0)
                    .offset(x: revealStep >= idx ? 0 : 12)
                    .animation(.easeOut(duration: 0.25).delay(Double(idx) * 0.08),
                               value: revealStep)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func stepCard(step: BackendClient.PlanStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 1)
                Text(String(format: "%02d", step.id))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
            }
            .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.action.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundColor(.white.opacity(0.95))
                Text(step.target)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(accentDim)
                if !step.why.isEmpty {
                    Text(step.why)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.025))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(accentFaint, lineWidth: 0.6))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("AWAITING VOICE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(accentDim)
            Spacer()
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().stroke(accent.opacity(0.6), lineWidth: 1))
            }
            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Confirm")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(red: 95/255, green: 184/255, blue: 101/255)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func animateIn() {
        revealStep = -1
        for i in 0..<plan.steps.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(i) * 0.08) {
                revealStep = i
            }
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            pulse = 1
        }
    }
}

/// Junie's official mark — green plus + curved "j" — loaded from the
/// `JunieIcon` asset shipped with the app. `color` is ignored; the asset
/// already carries Junie's brand green. The parameter is kept for call-site
/// compatibility with earlier code that requested a tinted sparkle.
struct JunieSparkle: View {
    let color: Color = .green   // unused, kept for call-site compat
    init(color: Color = .green) { _ = color }
    var body: some View {
        Image("JunieIcon")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
    }
}

import SwiftUI

struct PlacementView: View {
    @ObservedObject var sessionManager: ARSessionManager
    let onPlace: () -> Void
    /// Optional: skip plane placement and open the flat 2D workspace (AR camera paused).
    var onUseFlatWorkspace: (() -> Void)? = nil

    var body: some View {
        ZStack {
            VStack {
                Text(sessionManager.hasDetectedSurface
                     ? "Tap to place your workspace"
                     : "Point your camera at a flat surface")
                    .font(.system(size: 16, weight: .medium))
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Color.black.opacity(0.55))
                    )
                    .padding(.top, 60)
                Spacer()
            }
            VStack {
                Spacer()
                VStack(spacing: 14) {
                    if let onFlat = onUseFlatWorkspace {
                        Button(action: onFlat) {
                            Text("Use flat workspace (no AR)")
                                .font(.system(size: 15, weight: .medium))
                                .tracking(0.4)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 13)
                                .background(
                                    Capsule().fill(Color.black.opacity(0.55))
                                )
                                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        }
                    }
                    Button(action: {
                        if sessionManager.hasDetectedSurface { onPlace() }
                    }) {
                        Text("Place workspace")
                            .font(.system(size: 16, weight: .medium))
                            .tracking(1)
                            .foregroundColor(.white)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                            .background(
                                Capsule().fill(sessionManager.hasDetectedSurface
                                                ? Color.black.opacity(0.85)
                                                : Color.gray.opacity(0.55))
                            )
                    }
                    .disabled(!sessionManager.hasDetectedSurface)
                }
                .padding(.bottom, 48)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { _ in
            if sessionManager.hasDetectedSurface {
                onPlace()
            }
        }
    }
}

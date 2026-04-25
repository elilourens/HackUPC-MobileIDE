import SwiftUI

struct PlacementView: View {
    @ObservedObject var sessionManager: ARSessionManager
    let onPlace: () -> Void

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
                .padding(.bottom, 60)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            // Tap anywhere to place
            if sessionManager.hasDetectedSurface {
                onPlace()
            }
        }
    }
}

import SwiftUI

struct SpatialScenePicker: View {
    let selected: SpatialScene
    let onSelect: (SpatialScene) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spatial Scenes")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundColor(.white.opacity(0.8))
            ForEach(SpatialScene.allCases, id: \.self) { scene in
                Button(action: { onSelect(scene) }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(scene.accentColor)
                            .frame(width: 8, height: 8)
                        Text(scene.displayName)
                            .font(.system(size: 12, weight: scene == selected ? .semibold : .regular))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(scene == selected ? 0.15 : 0.08)))
                }
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

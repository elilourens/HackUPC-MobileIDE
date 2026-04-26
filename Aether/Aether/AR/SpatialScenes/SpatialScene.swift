import SwiftUI

enum SpatialScene: String, CaseIterable, Codable {
    case realWorld
    case cambridge
    case canaryWharf
    case pretoriaGardens
    case focusDark

    var displayName: String {
        switch self {
        case .realWorld: return "Real World"
        case .cambridge: return "Cambridge"
        case .canaryWharf: return "Canary Wharf"
        case .pretoriaGardens: return "Pretoria Gardens"
        case .focusDark: return "Focus Mode"
        }
    }

    var assetName: String? {
        switch self {
        case .realWorld, .focusDark:
            return nil
        case .cambridge:
            return "cambridge_4k.exr"
        case .canaryWharf:
            return "canary_wharf_4k.exr"
        case .pretoriaGardens:
            return "pretoria_gardens_4k.exr"
        }
    }

    /// Name passed to `EnvironmentResource.load(named:)` — the equirectangular file inside a `.skybox` folder, without extension.
    var environmentImageBaseName: String? {
        guard let name = assetName else { return nil }
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// Folder name in the app bundle (sibling to other Resources) containing the EXR for URL-based fallback loading.
    var environmentSkyboxFolderName: String? {
        switch self {
        case .cambridge: return "Cambridge.skybox"
        case .canaryWharf: return "CanaryWharf.skybox"
        case .pretoriaGardens: return "PretoriaGardens.skybox"
        case .realWorld, .focusDark: return nil
        }
    }

    /// HDR/spatial scenes: enable ARKit person segmentation so real hands occlude the synthetic environment (works without LiDAR via `.personSegmentation`).
    var usesPersonMaskedPassthrough: Bool {
        switch self {
        case .cambridge, .canaryWharf, .pretoriaGardens: return true
        case .realWorld, .focusDark: return false
        }
    }

    var accentColor: Color {
        switch self {
        case .realWorld: return .white
        case .cambridge: return Color(red: 0.80, green: 0.68, blue: 0.52)
        case .canaryWharf: return Color(red: 0.35, green: 0.56, blue: 0.90)
        case .pretoriaGardens: return Color(red: 0.34, green: 0.74, blue: 0.44)
        case .focusDark: return Color(red: 0.20, green: 0.22, blue: 0.28)
        }
    }

    var description: String {
        switch self {
        case .realWorld:
            return "Standard passthrough AR with no virtual environment."
        case .cambridge:
            return "Academic warm ambience with muted stone and greenery."
        case .canaryWharf:
            return "Dark city corporate ambience with cool blue tones."
        case .pretoriaGardens:
            return "Sunlit garden ambience with green tones and particles."
        case .focusDark:
            return "Translucent dark surround to reduce visual distractions."
        }
    }
}

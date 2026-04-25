import SwiftUI

/// IntelliJ Islands (Dark) palette + helpers. SwiftUI side — see `PanelManager.JB`
/// for the AR/Core-Graphics equivalents.
enum IJ {
    // Backgrounds
    static let bgMain     = Color(hex: 0x1E1F22)
    static let bgEditor   = Color(hex: 0x2B2D30)
    static let bgSidebar  = Color(hex: 0x1E1F22)
    static let bgTabs     = Color(hex: 0x1E1F22)
    static let bgInput    = Color(hex: 0x2B2D30)
    static let bgHover    = Color(hex: 0x2E3035)
    static let bgSelected = Color(hex: 0x26282E)
    // Borders
    static let border       = Color(hex: 0x393B40)
    static let borderSubtle = Color(hex: 0x2B2D30)
    // Text
    static let textPrimary   = Color(hex: 0xBCBEC4)
    static let textSecondary = Color(hex: 0x6F737A)
    static let textDisabled  = Color(hex: 0x55585E)
    // Accents
    static let accentBlue   = Color(hex: 0x3574F0)
    static let accentGreen  = Color(hex: 0x4DBB5F)
    static let accentOrange = Color(hex: 0xE6A855)
    static let accentRed    = Color(hex: 0xDB5860)
    // Scrollbar
    static let scrollbar      = Color(hex: 0x3E4045)
    static let scrollbarHover = Color(hex: 0x575A5F)
    // File-type icon dots (matches AR sidebar palette)
    static let iconHtml = Color(hex: 0xE8BF6A)
    static let iconCss  = Color(hex: 0x9876AA)
    static let iconJs   = Color(hex: 0xFFC66D)
    static let iconJson = Color(hex: 0x6A8759)
    static let iconAny  = Color(hex: 0xBCBEC4)

    /// Color a file-tree dot by extension — JetBrains ProjectView convention.
    static func iconColor(for filename: String) -> Color {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":                  return iconHtml
        case "css", "scss", "sass", "less":  return iconCss
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return iconJs
        case "json", "yaml", "yml", "toml":  return iconJson
        default:                              return iconAny
        }
    }

    /// Map a filename to a Monaco language id.
    static func monacoLanguage(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "html"
        case "css":         return "css"
        case "scss", "sass":return "scss"
        case "less":        return "less"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx":         return "javascript"
        case "ts":          return "typescript"
        case "tsx":         return "typescript"
        case "json":        return "json"
        case "md":          return "markdown"
        case "py":          return "python"
        case "swift":       return "swift"
        default:            return "plaintext"
        }
    }

    /// Status-bar friendly display name for a file type.
    static func languageLabel(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "TEXT" : ext
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

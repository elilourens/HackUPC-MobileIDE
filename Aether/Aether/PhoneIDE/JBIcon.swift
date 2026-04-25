import SwiftUI
import UIKit

/// Real JetBrains icon assets, rasterized at build time from the SVGs in
/// `Resources/JBIcons/` and shipped as Asset Catalog imagesets named
/// `JB-<group>-<name>` (e.g. `JB-filetype-js`, `JB-tool-branch`).
///
/// Use `JBIcon(.fileType(name))` to render a file-type shield, or
/// `JBIcon(.tool(name))` for a tool-window / action icon.
struct JBIcon: View {
    enum Token {
        case fileType(String)   // e.g. "html", "css", "js", "json"
        case tool(String)       // e.g. "branch", "run", "debug", "search"
        case raw(String)        // any imageset name (no "JB-" prefix needed)
    }

    let token: Token
    var size: CGFloat = 14
    var tint: Color? = nil   // nil = original colors (template-rendering-intent original)

    init(_ token: Token, size: CGFloat = 14, tint: Color? = nil) {
        self.token = token
        self.size = size
        self.tint = tint
    }

    var body: some View {
        let img = Image(JBIconLoader.assetName(for: token))
            .resizable()
            .renderingMode(tint == nil ? .original : .template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
        if let tint = tint {
            img.foregroundColor(tint)
        } else {
            img
        }
    }
}

/// Shared helpers — also used by the AR Core Graphics path so the
/// imageset names stay consistent across both renderers.
enum JBIconLoader {
    static func assetName(for token: JBIcon.Token) -> String {
        switch token {
        case .fileType(let n): return "JB-filetype-\(n)"
        case .tool(let n):     return "JB-tool-\(n)"
        case .raw(let n):      return n.hasPrefix("JB-") ? n : "JB-\(n)"
        }
    }

    /// Map a filename to the asset name of its JB file-type icon.
    static func fileTypeAsset(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":                 return assetName(for: .fileType("html"))
        case "css", "scss", "sass", "less": return assetName(for: .fileType("css"))
        case "js", "mjs", "cjs", "jsx":     return assetName(for: .fileType("js"))
        case "ts", "tsx":                   return assetName(for: .fileType("js"))   // ts SVG 404'd; reuse js shield
        case "json", "yaml", "yml", "toml": return assetName(for: .fileType("json"))
        case "xml":                         return assetName(for: .fileType("xml"))
        case "txt", "md", "markdown":       return assetName(for: .fileType("text"))
        case "zip", "tar", "gz":            return assetName(for: .fileType("archive"))
        default:                             return assetName(for: .fileType("unknown"))
        }
    }

    /// UIImage variant for AR Core Graphics drawing.
    static func uiImage(for token: JBIcon.Token) -> UIImage? {
        UIImage(named: assetName(for: token))
    }

    static func uiImageForFile(_ filename: String) -> UIImage? {
        UIImage(named: fileTypeAsset(for: filename))
    }
}
